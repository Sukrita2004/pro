"""Train a one-day-ahead FreshFlow model with chronological evaluation.

All dynamic features use observations strictly before the forecast date.
Baseline demand is a provisional synthetic target, not an observed POS label.
"""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import sklearn
from sklearn.base import clone
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OrdinalEncoder

ROOT = Path(__file__).resolve().parents[1]
CAT = ["product_id", "store_id", "category"]
BASE_NUM = ["base_price_usd", "standard_shelf_life_days", "weekday", "month",
       "is_weekend", "is_holiday", "sales_lag_1", "sales_lag_7", "sales_lag_14",
       "sales_mean_7", "sales_mean_28", "expiry_lag_1", "risk_lag_1"]
WEEKLY_NUM = ["sales_same_weekday_mean_4", "sales_same_weekday_std_4"]
STOCKOUT_NUM = ["stockout_lag_1", "stockout_count_7", "stockout_rate_28"]
FEATURE_SETS = {"base": BASE_NUM, "weekly": BASE_NUM + WEEKLY_NUM,
                "stockout": BASE_NUM + STOCKOUT_NUM,
                "extended": BASE_NUM + WEEKLY_NUM + STOCKOUT_NUM}
NUM = FEATURE_SETS["extended"]
FEATURES = CAT + NUM


def load_data(database: Path) -> pd.DataFrame:
    """Open the database read-only; never create an empty DB on a mistyped path."""
    if not database.is_file():
        raise FileNotFoundError(database)
    with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as conn:
        frame = pd.read_sql_query(
            "SELECT l.*, p.category, p.base_price_usd, p.standard_shelf_life_days "
            "FROM inventory_sales_log l JOIN products p USING(product_id)", conn)
    frame["date"] = pd.to_datetime(frame["date"], errors="raise")
    if frame.duplicated(["store_id", "product_id", "date"]).any():
        raise ValueError("Duplicate daily keys")
    frame = frame.sort_values(["store_id", "product_id", "date"]).reset_index(drop=True)
    gaps = frame.groupby(["store_id", "product_id"])["date"].diff().dropna()
    if not gaps.eq(pd.Timedelta(days=1)).all():
        raise ValueError("Daily histories contain gaps; do not treat missing dates as zero sales")
    return frame


def make_features(frame: pd.DataFrame, feature_set: str = "extended") -> pd.DataFrame:
    """Shift before rolling; keep groups isolated. Requires 28 days of history."""
    frame = frame.sort_values(["store_id", "product_id", "date"]).copy()
    group = frame.groupby(["store_id", "product_id"], sort=False)
    for lag in (1, 7, 14):
        frame[f"sales_lag_{lag}"] = group["actual_sales_units"].shift(lag)
    for window in (7, 28):
        frame[f"sales_mean_{window}"] = group["actual_sales_units"].transform(
            lambda values: values.shift(1).rolling(window, min_periods=window).mean())
    frame["expiry_lag_1"] = group["days_until_expiry"].shift(1)
    frame["risk_lag_1"] = group["expiration_risk_score"].shift(1)
    frame["weekday"] = frame["date"].dt.dayofweek
    frame["month"] = frame["date"].dt.month
    if feature_set in ("weekly", "extended"):
        # Same weekday at t-7, t-14, t-21, t-28. Never use today's sales.
        weekly = pd.concat([group["actual_sales_units"].shift(lag)
                            for lag in (7, 14, 21, 28)], axis=1)
        complete = weekly.notna().all(axis=1)
        frame["sales_same_weekday_mean_4"] = weekly.mean(axis=1).where(complete)
        frame["sales_same_weekday_std_4"] = weekly.std(axis=1, ddof=0).where(complete)
    if feature_set in ("stockout", "extended"):
        frame["stockout_lag_1"] = group["out_of_stock_flag"].shift(1)
        frame["stockout_count_7"] = group["out_of_stock_flag"].transform(
            lambda values: values.shift(1).rolling(7, min_periods=7).sum())
        frame["stockout_rate_28"] = group["out_of_stock_flag"].transform(
            lambda values: values.shift(1).rolling(28, min_periods=28).mean())
    return frame.dropna(subset=FEATURE_SETS[feature_set]).reset_index(drop=True)


def metrics(actual, predicted) -> dict:
    actual = np.asarray(actual, dtype=float)
    predicted = np.maximum(0, np.asarray(predicted, dtype=float))
    error = actual - predicted
    denominator = float(np.abs(actual).sum())
    return {"MAE": float(np.abs(error).mean()),
            "RMSE": float(np.sqrt(np.mean(error ** 2))),
            "WMAPE_percent": float(100 * np.abs(error).sum() / denominator)
            if denominator else None}


def pipeline(parameters: dict, numeric_features=None) -> Pipeline:
    preprocessing = ColumnTransformer([
        ("categories", OrdinalEncoder(handle_unknown="use_encoded_value",
                                      unknown_value=np.nan), CAT),
        ("numeric", "passthrough", NUM if numeric_features is None else numeric_features)])
    return Pipeline([("preprocessing", preprocessing),
                     ("regressor", HistGradientBoostingRegressor(
                         categorical_features=list(range(len(CAT))),
                         early_stopping=False, random_state=42, **parameters))])


def train(database: Path, output: Path, target: str, feature_set: str = "extended") -> dict:
    raw = load_data(database)
    numeric = FEATURE_SETS[feature_set]
    features = CAT + numeric
    frame = make_features(raw, feature_set)
    dates = sorted(frame["date"].unique())
    if len(dates) < 30:
        raise ValueError("Insufficient dates after the 28-day warm-up")
    # One shared date boundary for all products/stores. No shuffled split.
    first, second = int(len(dates) * .70), int(len(dates) * .85)
    parts = {"train": frame[frame.date < dates[first]],
             "validation": frame[(frame.date >= dates[first]) & (frame.date < dates[second])],
             "test": frame[frame.date >= dates[second]]}
    for name, subset in parts.items():
        if subset.empty or not np.isfinite(subset[target]).all() or (subset[target] < 0).any():
            raise ValueError(f"Empty split or invalid target: {name}")
    candidates = []
    for parameters in (
        {"max_iter": 150, "max_leaf_nodes": 15, "learning_rate": .05, "l2_regularization": 1.0},
        {"max_iter": 250, "max_leaf_nodes": 31, "learning_rate": .05, "l2_regularization": 5.0},
    ):
        estimator = pipeline(parameters, numeric)
        estimator.fit(parts["train"][features], parts["train"][target])
        scores = metrics(parts["validation"][target], estimator.predict(parts["validation"][features]))
        candidates.append((scores["MAE"], estimator, parameters, scores))
    _, selected, parameters, _ = min(candidates, key=lambda item: item[0])
    # Test remains untouched during model selection; refit only train + validation.
    development = pd.concat([parts["train"], parts["validation"]])
    final_model = clone(selected).fit(development[features], development[target])
    test = parts["test"]
    predictions = np.maximum(0, final_model.predict(test[features]))
    comparisons = {"HistGradientBoosting": metrics(test[target], predictions)}
    for name, column in (("previous_day_sales", "sales_lag_1"),
                         ("previous_week_sales", "sales_lag_7"),
                         ("trailing_7_day_sales", "sales_mean_7")):
        comparisons[name] = metrics(test[target], test[column])
    split_summary = {name: {"rows": len(subset), "start": str(subset.date.min().date()),
                            "end": str(subset.date.max().date())}
                     for name, subset in parts.items()}
    result = {"feature_set": feature_set, "feature_names": features,
              "target": target, "target_status": "provisional: confirm generator definition"
              if target == "baseline_demand_units" else "observed sales, stock-constrained",
              "evaluation": "daily rolling one-day-ahead using observed sales through t-1",
              "raw_rows": len(raw), "feature_rows": len(frame),
              "warmup_rows": len(raw) - len(frame), "splits": split_summary,
              "selected_parameters": parameters,
              "selection_metric": "validation MAE",
              "validation_candidates": [{"parameters": p, "metrics": s} for _, _, p, s in candidates],
              "test_metrics": comparisons,
              "category_test_metrics": {category: metrics(test.loc[mask, target], predictions[mask])
                  for category in sorted(test.category.unique())
                  for mask in [test.category.eq(category).to_numpy()]},
              "database_sha256": hashlib.sha256(database.read_bytes()).hexdigest(),
              "versions": {"pandas": pd.__version__, "numpy": np.__version__,
                           "scikit_learn": sklearn.__version__, "joblib": joblib.__version__}}
    output.mkdir(parents=True, exist_ok=True)
    joblib.dump(final_model, output / "demand_model.joblib")
    joblib.dump({"feature_names": features, "categorical_features": CAT,
                 "numeric_features": numeric, "feature_set": feature_set,
                 "target": target, "history_days": 28,
                 "forecast_horizon_days": 1, "prediction_postprocessing": "clip minimum to zero",
                 "feature_builder": "scripts/train_demand_model.py:make_features",
                 "versions": result["versions"]}, output / "model_features.joblib")
    # Verify persistence before reporting a completed export.
    restored = joblib.load(output / "demand_model.joblib")
    np.testing.assert_allclose(restored.predict(test[features].head(10)),
                               final_model.predict(test[features].head(10)))
    exported = test[["record_id", "date", "store_id", "product_id", "category", target]].copy()
    exported["predicted_demand_units"] = predictions
    exported.to_csv(output / "test_predictions.csv", index=False)
    (output / "training_results.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    lines = ["# FreshFlow — รายงาน Phase 2", "", f"Target: {target}",
             "", "ประเมินแบบพยากรณ์รายวันล่วงหน้า 1 วัน ใช้ยอดขายจริงที่ทราบถึงวันก่อน",
             "ข้อมูลใน test วันก่อนสามารถใช้เป็นประวัติใน test วันถัดไปได้; ไม่ใช่การพยากรณ์หลายวันพร้อมกัน",
             "", "## การแบ่งข้อมูล", ""]
    lines += [f"- {name}: {value}" for name, value in split_summary.items()]
    lines += ["", "## ผล test", "", "| Model | MAE | RMSE | WMAPE (%) |", "|---|---:|---:|---:|"]
    for name, scores in comparisons.items():
        values = ["undefined" if value is None else f"{value:.4f}" for value in scores.values()]
        lines.append(f"| {name} | " + " | ".join(values) + " |")
    lines += ["", "## วิธีและข้อจำกัด", "",
              "เลือก hyperparameters ด้วย validation MAE เท่านั้น ก่อน refit train+validation และประเมิน test",
              "WMAPE = 100 × sum(abs(actual-predicted)) / sum(abs(actual)); ไม่ใช่ accuracy",
              "features ใช้รหัสสินค้า/ร้านค้า/หมวด ราคา อายุสินค้า ปฏิทิน และประวัติยอดขาย/อายุ/ความเสี่ยง",
              "ไม่มี baseline/effective demand ของวันเป้าหมาย สต็อกปิดวัน รายได้ ของเสีย หรือส่วนลดวันเป้าหมายเป็น features",
              "holiday calendar ต้องมีข้อมูลสำหรับวันอนาคต; ราคาใน products คงที่เฉพาะชุดนี้",
              "Baseline demand เป็น target ที่เสนอและยังต้องยืนยันนิยามตัวสร้าง synthetic",
              "lag มาจากยอดขายจริง ซึ่งอาจถูกจำกัดด้วย stockout; โมเดลอาจไม่ชนะ baseline",
              "ผลบน synthetic ไม่ยืนยันผลกับร้านค้าจริง ไม่ใช้ 100-WMAPE เป็น accuracy",
              "test เก็บไว้ประเมิน ไม่ได้ใช้ฝึกไฟล์โมเดลที่ส่งออก",
              "", "อ้างอิง: https://scikit-learn.org/stable/auto_examples/ensemble/plot_gradient_boosting_categorical.html"]
    (output / "phase2_model_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=ROOT / "freshflow.db")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "phase2_extended")
    parser.add_argument("--feature-set", choices=list(FEATURE_SETS), default="extended")
    parser.add_argument("--target", choices=["baseline_demand_units", "actual_sales_units"],
                        default="baseline_demand_units")
    args = parser.parse_args()
    print(json.dumps(train(args.db, args.output_dir, args.target, args.feature_set), ensure_ascii=False, indent=2))
