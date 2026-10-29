"""Application data is isolated from the original training database."""
import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS products (
 product_id TEXT PRIMARY KEY, product_name TEXT NOT NULL, category TEXT NOT NULL,
 base_price_usd REAL NOT NULL, cost_price_usd REAL NOT NULL,
 standard_shelf_life_days REAL NOT NULL);
CREATE TABLE IF NOT EXISTS stores (store_id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS history (
 store_id TEXT NOT NULL REFERENCES stores, product_id TEXT NOT NULL REFERENCES products,
 date TEXT NOT NULL, payload TEXT NOT NULL, source TEXT NOT NULL,
 PRIMARY KEY(store_id,product_id,date));
CREATE TABLE IF NOT EXISTS snapshots (
 snapshot_id INTEGER PRIMARY KEY, store_id TEXT NOT NULL REFERENCES stores,
 product_id TEXT NOT NULL REFERENCES products, snapshot_date TEXT NOT NULL,
 opening_inventory_units INTEGER NOT NULL CHECK(opening_inventory_units>=0),
 days_to_expiry REAL NOT NULL, delivery_lead_time_days INTEGER NOT NULL DEFAULT 1,
 pending_order_units INTEGER NOT NULL DEFAULT 0 CHECK(pending_order_units>=0),
 snapshot_source TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
 UNIQUE(store_id,product_id,snapshot_date));
CREATE TABLE IF NOT EXISTS receipts (
 request_id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS daily_closures (
 request_id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at TEXT NOT NULL,
 store_id TEXT NOT NULL, product_id TEXT NOT NULL, date TEXT NOT NULL,
 UNIQUE(store_id,product_id,date));
CREATE TABLE IF NOT EXISTS runs (
 run_id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT UNIQUE NOT NULL,
 request_payload TEXT NOT NULL, snapshot_date TEXT NOT NULL, store_id TEXT NOT NULL,
 created_at TEXT NOT NULL, model_version TEXT NOT NULL, metadata_version TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS recommendations (
 recommendation_id INTEGER PRIMARY KEY AUTOINCREMENT,
 run_id INTEGER NOT NULL REFERENCES runs, snapshot_id INTEGER NOT NULL REFERENCES snapshots,
 snapshot_revision INTEGER NOT NULL, approval_status TEXT NOT NULL DEFAULT 'PROPOSED',
 result TEXT NOT NULL, UNIQUE(run_id,snapshot_id));
CREATE TABLE IF NOT EXISTS notification_reads (notification_id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS approval_decisions (
 decision_id INTEGER PRIMARY KEY AUTOINCREMENT,
 recommendation_id INTEGER NOT NULL REFERENCES recommendations,
 payload TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS lot_snapshots (
 snapshot_id INTEGER PRIMARY KEY REFERENCES snapshots);
CREATE TABLE IF NOT EXISTS inventory_lots (
 snapshot_id INTEGER NOT NULL REFERENCES snapshots, lot_key TEXT NOT NULL,
 batch_id TEXT NOT NULL, expiry_date TEXT NOT NULL, units INTEGER NOT NULL CHECK(units>=0),
 cost_price_usd REAL NOT NULL, source TEXT NOT NULL,
 PRIMARY KEY(snapshot_id,lot_key));
CREATE TABLE IF NOT EXISTS closure_lot_allocations (
 request_id TEXT PRIMARY KEY REFERENCES daily_closures, payload TEXT NOT NULL);
"""


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True)


@contextmanager
def connect(path):
    connection = sqlite3.connect(path, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA foreign_keys=ON')
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def initialize(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    # Preserve a one-time pre-FEFO copy before any legacy balances are inferred.
    backup=Path(str(path)+'.pre_fefo.sqlite')
    if Path(path).exists() and not backup.exists():
        with connect(path) as source:
            exists=source.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='snapshots'").fetchone()
            if exists and source.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0]:
                target=sqlite3.connect(backup)
                try:
                    source.backup(target)
                finally:
                    target.close()
    with connect(path) as connection:
        connection.executescript(SCHEMA)
