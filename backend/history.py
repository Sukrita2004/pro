"""Read-only monthly records, with an explicit training/application source."""
import json
import sqlite3
from contextlib import closing

from fastapi import HTTPException
from backend.storage import ROOT, connect

TYPES = {
    'sales':('history','date'),
    'receipts':('receipts',"json_extract(payload,'$.received_date')"),
    'daily_closures':('daily_closures','date'),
    'forecast_runs':('runs','snapshot_date'),
}


def available_months(database, store, source, kind):
    if source == 'training':
        if kind != 'sales':
            return []
        with closing(sqlite3.connect((ROOT/'freshflow.db').as_uri()+'?mode=ro',uri=True)) as connection:
            return [row[0] for row in connection.execute('SELECT DISTINCT substr(date,1,7) AS month FROM inventory_sales_log WHERE store_id=? ORDER BY month DESC',(store,))]
    table, day = TYPES[kind]
    column = "json_extract(payload,'$.store_id')" if kind == 'receipts' else 'store_id'
    with connect(database) as connection:
        return [row[0] for row in connection.execute(f'SELECT DISTINCT substr({day},1,7) AS month FROM {table} WHERE {column}=? ORDER BY month DESC',(store,))]


def monthly_records(database, store, source, kind, month, limit, offset):
    if source == 'training':
        if kind != 'sales':
            raise HTTPException(422,'Training archive contains sales records only.')
        with closing(sqlite3.connect((ROOT/'freshflow.db').as_uri()+'?mode=ro',uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            where = 'l.store_id=? AND substr(l.date,1,7)=?'
            total = connection.execute(f'SELECT COUNT(*) FROM inventory_sales_log l WHERE {where}',(store,month)).fetchone()[0]
            records = [dict(row) for row in connection.execute(f'''SELECT l.date,l.store_id,l.product_id,p.product_name,p.category,
                l.actual_sales_units,l.units_wasted,l.opening_inventory_units,l.closing_inventory_units,
                l.out_of_stock_flag,l.promotion_active,l.baseline_demand_units
                FROM inventory_sales_log l JOIN products p USING(product_id) WHERE {where}
                ORDER BY l.date DESC,l.product_id LIMIT ? OFFSET ?''',(store,month,limit,offset))]
            for row in records:
                row['source'] = 'SYNTHETIC_TRAINING_DATA_2025'
    else:
        table, day = TYPES[kind]
        column = "json_extract(payload,'$.store_id')" if kind == 'receipts' else 'store_id'
        where = f'{column}=? AND substr({day},1,7)=?'
        with connect(database) as connection:
            total = connection.execute(f'SELECT COUNT(*) FROM {table} WHERE {where}',(store,month)).fetchone()[0]
            secondary = 'run_id DESC' if kind=='forecast_runs' else ('product_id' if kind=='sales' else 'created_at DESC,request_id')
            raw = connection.execute(f'SELECT * FROM {table} WHERE {where} ORDER BY {day} DESC,{secondary} LIMIT ? OFFSET ?',
                                     (store,month,limit,offset)).fetchall()
            names = {row['product_id']:row['product_name'] for row in connection.execute('SELECT product_id,product_name FROM products')}
            records = []
            for row in raw:
                item = dict(row)
                if kind != 'forecast_runs':
                    payload = json.loads(item.pop('payload'))
                    item.update(payload)
                    item['product_name'] = names.get(item.get('product_id'),item.get('product_id'))
                else:
                    item['request'] = json.loads(item.pop('request_payload'))
                    item['product_count'] = connection.execute('SELECT COUNT(*) FROM recommendations WHERE run_id=?',(item['run_id'],)).fetchone()[0]
                records.append(item)
    return {'source':source,'record_type':kind,'month':month,'store_id':store,
            'total':total,'limit':limit,'offset':offset,'items':records}
