"""Pure, explainable discount and replenishment policy; no network or database writes."""
import math
from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone

from weather import WeatherData


@dataclass(frozen=True)
class RecommendationInput:
    product_id: str
    store_id: str
    category: str
    decision_date: str
    predicted_demand_units: float
    current_inventory_units: int
    days_until_expiry: float
    new_batch_shelf_life_days: float
    delivery_lead_time_days: int = 1
    pending_order_units: int = 0
    usable_inventory_override_units: int | None = None


@dataclass(frozen=True)
class RulePolicy:
    flash_expiry_days: float = 1
    early_expiry_days: float = 3
    flash_discount_percent: int = 50
    early_discount_percent: int = 20
    hot_temperature_c: float = 33
    rain_probability_threshold: float = .6
    hot_produce_multiplier: float = 1.10
    rainy_multiplier: float = .85
    review_period_days: int = 1
    safety_stock_fraction: float = .2
    max_weather_age_hours: float = 3

    def __post_init__(self):
        values = asdict(self)
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in values.values()):
            raise ValueError("Policy values must be finite numeric values")
        if not 0 <= self.flash_expiry_days <= self.early_expiry_days:
            raise ValueError("Invalid expiry thresholds")
        if not 0 <= self.early_discount_percent <= self.flash_discount_percent <= 100:
            raise ValueError("Invalid discount tiers")
        if not 0 <= self.rain_probability_threshold <= 1:
            raise ValueError("Invalid rain threshold")
        if self.hot_produce_multiplier <= 0 or self.rainy_multiplier <= 0:
            raise ValueError("Weather multipliers must be positive")
        if self.review_period_days < 1 or int(self.review_period_days) != self.review_period_days:
            raise ValueError("Review period must be a positive integer")
        if self.safety_stock_fraction < 0 or self.max_weather_age_hours <= 0:
            raise ValueError("Invalid safety stock / weather freshness policy")


def recommend(item: RecommendationInput, weather: WeatherData,
              policy: RulePolicy = RulePolicy()) -> dict:
    """Discount existing stock; order fresh stock separately, capped by its shelf life.

    days_until_expiry < 0 means expired; 0 means expires during the decision day.
    Incoming orders must be usable and expected within the planning horizon.
    """
    if item.category not in {"Bakery", "Produce", "Dairy", "Meat"}:
        raise ValueError("Unsupported category")
    if not item.product_id or not item.store_id:
        raise ValueError("Product/store identifiers are required")
    day = date.fromisoformat(item.decision_date)
    if weather.target_date != day.isoformat():
        raise ValueError("Weather date must match decision/forecast date")
    numeric = (item.predicted_demand_units, item.days_until_expiry, item.new_batch_shelf_life_days)
    if not all(math.isfinite(value) for value in numeric):
        raise ValueError("Demand and shelf life must be finite")
    if item.predicted_demand_units < 0 or item.new_batch_shelf_life_days <= 0:
        raise ValueError("Invalid demand or new-batch shelf life")
    for name in ("current_inventory_units", "delivery_lead_time_days", "pending_order_units"):
        value = getattr(item, name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"{name} must be a nonnegative integer")
    reasons = []
    if weather.source != "mock":
        now = datetime.now(timezone.utc)
        age = (now - datetime.fromisoformat(weather.fetched_at)).total_seconds() / 3600
        if age < -.1 or age > policy.max_weather_age_hours:
            raise ValueError("Live weather is stale or fetched_at is in the future")
        if weather.source == "openweather_current" and item.delivery_lead_time_days > 0:
            reasons.append("CURRENT_WEATHER_ONLY_NOT_FUTURE_FORECAST")
    else:
        reasons.append("MOCK_WEATHER")
    if weather.source == "openweather_forecast" and weather.sample_count < 8:
        reasons.append("PARTIAL_DAY_FORECAST")
    multiplier = 1.0
    if item.category == "Produce" and weather.temperature_c >= policy.hot_temperature_c:
        multiplier *= policy.hot_produce_multiplier
        reasons.append("HOT_PRODUCE_ASSUMPTION")
    if weather.condition == "RAIN" or weather.rain_probability >= policy.rain_probability_threshold:
        multiplier *= policy.rainy_multiplier
        reasons.append("RAIN_REDUCED_DEMAND_ASSUMPTION")
    demand = item.predicted_demand_units * multiplier
    stock = item.current_inventory_units
    expired = stock > 0 and item.days_until_expiry < 0
    sellable = stock > 0 and not expired
    # Day zero is still saleable today, subject to store handling policy.
    sell_days = max(1.0, item.days_until_expiry)
    surplus = max(0.0, stock - demand * sell_days) if sellable else 0.0
    discount, percent = "PRICE_NORMAL", 0
    if expired:
        reasons.append("EXPIRED_STOCK_REMOVE_FROM_SALE")
    elif sellable and item.days_until_expiry <= policy.flash_expiry_days:
        discount, percent = "FLASH_SALE", policy.flash_discount_percent
        reasons.append("EXPIRY_WITHIN_FLASH_WINDOW")
    elif sellable and item.days_until_expiry <= policy.early_expiry_days and surplus > 0:
        discount, percent = "EARLY_DEAL", policy.early_discount_percent
        reasons.append("NEAR_EXPIRY_WITH_PROJECTED_SURPLUS")
    else:
        reasons.append("NO_DISCOUNT_TRIGGER")
    horizon = item.delivery_lead_time_days + policy.review_period_days
    # If current stock expires by arrival, conservatively exclude it from order position.
    usable = stock if sellable and item.days_until_expiry > item.delivery_lead_time_days else 0
    if item.usable_inventory_override_units is not None:
        if not isinstance(item.usable_inventory_override_units,int) or not 0<=item.usable_inventory_override_units<=stock:
            raise ValueError('Invalid lot-level usable inventory.')
        usable=item.usable_inventory_override_units
    if stock and usable == 0:
        reasons.append("CURRENT_STOCK_EXCLUDED_AT_ARRIVAL")
    target = demand * horizon + demand * policy.safety_stock_fraction
    gap = max(0.0, target - usable - item.pending_order_units)
    shelf_cap = math.floor(demand * item.new_batch_shelf_life_days)
    quantity = min(math.ceil(gap), shelf_cap)
    if quantity < math.ceil(gap):
        reasons.append("FRESH_BATCH_SHELF_LIFE_CAP")
    reasons.append("BELOW_ORDER_UP_TO_LEVEL" if quantity > 0 else "NO_ORDER_NEEDED_OR_CAP_ZERO")
    return {"product_id": item.product_id, "store_id": item.store_id,
            "decision_date": item.decision_date, "category": item.category,
            "predicted_demand_units": item.predicted_demand_units,
            "weather_adjusted_demand_units": demand, "weather_multiplier": multiplier,
            "discount_action": discount, "discount_percent": percent,
            "restock_action": "RESTOCK_REQUIRED" if quantity > 0 else "NO_RESTOCK",
            "restock_quantity_units": quantity, "sale_allowed": sellable,
            "remove_expired_units": stock if expired else 0,
            "projected_surplus_before_expiry_units": surplus,
            "usable_inventory_at_arrival_units": usable,
            "order_up_to_units": target, "new_batch_shelf_life_cap_units": shelf_cap,
            "reasons": reasons, "weather": weather.to_dict(),
            "policy_version": "freshflow-rules-v1"}
