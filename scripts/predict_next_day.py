"""Example backend handover: predict the day after the latest stored sales."""
import argparse
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

from train_demand_model import ROOT, load_data, make_features


def predict_next_day(database: Path, artifacts: Path, is_holiday: int, planned_promotion=None) -> pd.DataFrame:
    history = load_data(database)
    return predict_from_history(history, artifacts, is_holiday, planned_promotion)


def predict_from_history(history: pd.DataFrame, artifacts: Path, is_holiday: int,
                         planned_promotion=None) -> pd.DataFrame:
    """Forecast from an explicitly supplied, cutoff-filtered history."""
    if history.empty or is_holiday not in (0, 1):
        raise ValueError("History is empty or holiday flag is invalid")
    metadata = joblib.load(artifacts / "model_features.joblib")
    if metadata.get("requires_planned_promotion") and planned_promotion not in (0, 1):
        raise ValueError("This model requires an explicit planned_promotion of 0 or 1")
    model = joblib.load(artifacts / metadata.get("model_filename", "demand_model.joblib"))
    last = history.groupby(["store_id", "product_id"], sort=False).tail(1).copy()
    if last.date.nunique() != 1:
        raise ValueError("Series have different latest dates; update the sales history first")
    next_date = last.date.iloc[0] + pd.Timedelta(days=1)
    last["date"] = next_date
    last["is_weekend"] = int(next_date.weekday() >= 5)
    last["is_holiday"] = is_holiday
    if metadata.get("requires_planned_promotion"):
        last["promotion_active"] = planned_promotion
        last["planned_promotion_active"] = planned_promotion
    # Future sales/expiry values are unknown. They do not enter next-day features.
    for column in ("actual_sales_units", "baseline_demand_units", "days_until_expiry",
                   "expiration_risk_score", "out_of_stock_flag"):
        last[column] = np.nan
    combined = pd.concat([history, last], ignore_index=True)
    # Older artifacts have the original base feature set without this metadata key.
    if metadata.get("feature_builder") == "improve_features":
        from improve_features import improve_features
        prepared = improve_features(combined)
    else:
        prepared = make_features(combined, metadata.get("feature_set", "base"))
    inputs = prepared.loc[prepared.date == next_date].copy()
    if len(inputs) != len(last):
        raise ValueError("Each series requires 28 consecutive historical days")
    predictions = np.maximum(0, model.predict(inputs[metadata["feature_names"]]))
    result = inputs[["date", "store_id", "product_id", "category"]].copy()
    result["predicted_demand_units"] = predictions
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=ROOT / "freshflow.db")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "artifacts" / "phase2")
    parser.add_argument("--holiday", type=int, choices=[0, 1], required=True,
                        help="Known holiday flag for the forecast date")
    parser.add_argument("--planned-promotion", type=int, choices=[0, 1])
    args = parser.parse_args()
    result = predict_next_day(args.db, args.artifacts, args.holiday, args.planned_promotion)
    result.to_csv(args.artifacts / "next_day_predictions.csv", index=False)
    print(result.head(10).to_string(index=False))
