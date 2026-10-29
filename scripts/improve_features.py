"""Past-only features for the improve_model experiment."""
from train_demand_model import make_features

EXTRA = ["sales_std_28", "sales_ewm_14", "stockout_free_sales_mean_28",
         "regular_sales_mean_28", "regular_sales_count_28", "promotion_lag_1",
         "discount_lag_1", "promotion_rate_28", "discount_mean_28"]


def improve_features(history):
    history = history.sort_values(["store_id", "product_id", "date"]).copy()
    history["clean_sales"] = history.actual_sales_units.where(history.out_of_stock_flag.eq(0))
    regular = history.out_of_stock_flag.eq(0) & history.promotion_active.eq(0) & history.applied_discount_percent.eq(0)
    history["regular_sales"] = history.actual_sales_units.where(regular)
    groups = history.groupby(["store_id", "product_id"], sort=False)
    history["sales_std_28"] = groups.actual_sales_units.transform(lambda s: s.shift(1).rolling(28).std(ddof=0))
    history["sales_ewm_14"] = groups.actual_sales_units.transform(lambda s: s.shift(1).ewm(span=14, adjust=False).mean())
    for source, output in (("clean_sales", "stockout_free_sales_mean_28"),
                           ("regular_sales", "regular_sales_mean_28")):
        history[output] = groups[source].transform(lambda s: s.shift(1).rolling(28, min_periods=1).mean())
        # Empty eligible history: transparent fallback to observed trailing sales.
        fallback = groups.actual_sales_units.transform(lambda s: s.shift(1).rolling(28).mean())
        history[output] = history[output].fillna(fallback)
    history["regular_sales_count_28"] = groups.regular_sales.transform(lambda s: s.shift(1).rolling(28).count())
    history["promotion_lag_1"] = groups.promotion_active.shift(1)
    history["discount_lag_1"] = groups.applied_discount_percent.shift(1)
    history["promotion_rate_28"] = groups.promotion_active.transform(lambda s: s.shift(1).rolling(28).mean())
    history["discount_mean_28"] = groups.applied_discount_percent.transform(lambda s: s.shift(1).rolling(28).mean())
    history["product_store_weekday"] = (history.product_id.astype(str) + "|" + history.store_id.astype(str)
                                         + "|" + history.date.dt.dayofweek.astype(str))
    return make_features(history, "extended").dropna(subset=EXTRA).reset_index(drop=True)
