"""No uncalibrated weather scaling of a weather-inclusive demand target."""
from dataclasses import replace
from recommendation_engine import RulePolicy, recommend


def recommend_generator_aligned(item, weather, policy=RulePolicy()):
    # Weather affects an explicit uncertainty buffer, not expected demand twice.
    rainy = weather.condition == "RAIN" or weather.rain_probability >= policy.rain_probability_threshold
    hot_produce = item.category == "Produce" and weather.temperature_c >= policy.hot_temperature_c
    fraction = max(policy.safety_stock_fraction, .3) if rainy or hot_produce else policy.safety_stock_fraction
    neutral = replace(policy, hot_produce_multiplier=1., rainy_multiplier=1., safety_stock_fraction=fraction)
    result = recommend(item, weather, neutral)
    result["reasons"] = [r for r in result["reasons"] if r not in
                         {"HOT_PRODUCE_ASSUMPTION", "RAIN_REDUCED_DEMAND_ASSUMPTION"}]
    result["reasons"].append("NO_UNCALIBRATED_WEATHER_DEMAND_SCALING")
    if fraction > policy.safety_stock_fraction:
        result["reasons"].append("WEATHER_UNCERTAINTY_BUFFER_ASSUMPTION")
    result["weather_role"] = "uncertainty_buffer_only_not_demand_multiplier"
    result["safety_stock_fraction"] = fraction
    result["policy_version"] = "generator-aligned-v2"
    return result
