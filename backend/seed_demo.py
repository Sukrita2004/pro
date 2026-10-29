"""Explicitly seed labeled synthetic history and mock inventory, without training."""
import csv
import json
import os
import sqlite3
from contextlib import closing
from pathlib import Path

from backend.storage import ROOT, connect, encode, initialize

CATEGORIES = {'Fresh Produce': 'Produce', 'Meat & Poultry': 'Meat',
              'Dairy & Eggs': 'Dairy', 'Bakery': 'Bakery'}
NUMERIC = ['base_price_usd', 'standard_shelf_life_days', 'is_weekend', 'is_holiday',
           'promotion_active', 'actual_sales_units', 'days_until_expiry',
           'expiration_risk_score', 'out_of_stock_flag', 'applied_discount_percent']


def seed(path):
    initialize(path)
    # Training DB is opened read-only. No change to original model/data.
    with closing(sqlite3.connect((ROOT / 'freshflow.db').as_uri() + '?mode=ro', uri=True)) as source:
        source.row_factory = sqlite3.Row
        products = [dict(row) for row in source.execute('SELECT * FROM products')]
    rows = []
    for name in ['history_through_2026-10-10.csv', 'actuals_2026-10-11.csv']:
        with (ROOT / 'data/cutoff_test' / name).open(encoding='utf-8-sig', newline='') as stream:
            for raw in csv.DictReader(stream):
                if raw['Category'] not in CATEGORIES:
                    continue
                value = {key.lower(): value for key, value in raw.items()}
                value['category'] = CATEGORIES[raw['Category']]
                value['days_until_expiry'] = value['days_to_expiry']
                for column in NUMERIC:
                    value[column] = float(value[column])
                # Persist only the fields needed for inference; no synthetic target required.
                record = {key: value[key] for key in NUMERIC + ['date','store_id','product_id','category']}
                rows.append((value['store_id'], value['product_id'], value['date'], encode(record), 'SYNTHETIC_EXTERNAL_HISTORY'))
    with (ROOT / 'data/inventory_mock_2026-10-12.csv').open(encoding='utf-8-sig', newline='') as stream:
        snapshots = [{k.lower(): v for k, v in row.items()} for row in csv.DictReader(stream)]
    with connect(path) as connection:
        # Refuse reseeding application data; never overwrite staff entries.
        if connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0]:
            return {'status': 'already_seeded', 'database': str(path)}
        for product in products:
            connection.execute('INSERT INTO products VALUES (?,?,?,?,?,?)', tuple(product[key] for key in
                ['product_id','product_name','category','base_price_usd','cost_price_usd','standard_shelf_life_days']))
        connection.executemany('INSERT INTO stores VALUES (?)', [(f'STORE_0{i}',) for i in range(1,5)])
        connection.executemany('INSERT INTO history VALUES (?,?,?,?,?)', rows)
        for row in snapshots:
            connection.execute('''INSERT INTO snapshots
                (store_id,product_id,snapshot_date,opening_inventory_units,days_to_expiry,
                 delivery_lead_time_days,pending_order_units,snapshot_source)
                VALUES (?,?,?,?,?,?,0,?)''',
                (row['store_id'],row['product_id'],row['date'],int(row['opening_inventory_units']),
                 float(row['days_to_expiry']),int(row['delivery_lead_time_days']), 'MOCK_INVENTORY_2026_10_12'))
    return {'status': 'seeded', 'history_rows': len(rows), 'snapshots': len(snapshots),
            'database': str(path), 'warning': 'Synthetic history and mock stock; no current-store data.'}


if __name__ == '__main__':
    print(json.dumps(seed(Path(os.environ.get('FRESHFLOW_DB', ROOT / 'data/application.db'))), indent=2))
