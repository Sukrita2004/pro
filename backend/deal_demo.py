"""Persistent, isolated sandbox. Never rewrite operational/training stock."""
from backend.seed_demo import seed
from backend.storage import connect
from backend.storage import encode, ROOT
from datetime import date, timedelta
import json
import csv

DEMO_DATE = date.today().isoformat()


def prepare(path, business_date=None):
    target = date.fromisoformat(business_date or DEMO_DATE)
    seed(path)
    details = {}
    for filename in ['history_through_2026-10-10.csv','actuals_2026-10-11.csv']:
        with (ROOT/'data/cutoff_test'/filename).open(encoding='utf-8-sig',newline='') as stream:
            for raw in csv.DictReader(stream):
                details[(raw['Store_ID'],raw['Product_ID'],raw['Date'])] = {
                    key.lower():float(raw[key]) for key in ['Opening_Inventory_Units',
                    'Received_Inventory_Units','Closing_Inventory_Units','Units_Wasted',
                    'Sales_Revenue_USD','Waste_Financial_Loss_USD']}
    with connect(path) as connection:
        connection.execute('BEGIN IMMEDIATE')
        connection.execute('CREATE TABLE IF NOT EXISTS demo_settings (key TEXT PRIMARY KEY,value TEXT NOT NULL)')
        marker = 'current_fixture_' + target.isoformat()
        if not connection.execute('SELECT 1 FROM demo_settings WHERE key=?',(marker,)).fetchone():
            # Replay a fixed synthetic sequence on recent calendar dates. These
            # are UI fixtures, never new observations or an evaluation holdout.
            original = connection.execute("SELECT * FROM history WHERE date BETWEEN '2026-07-11' AND '2026-10-11' ORDER BY date").fetchall()
            connection.execute("DELETE FROM history WHERE source='SYNTHETIC_EXTERNAL_HISTORY'")
            delta = target - date(2026,10,12)
            for row in original:
                record = json.loads(row['payload'])
                record.update(details.get((row['store_id'],row['product_id'],row['date']),{}))
                day = date.fromisoformat(row['date']) + delta
                record.update(date=day.isoformat(), is_weekend=int(day.weekday()>=5),
                              is_holiday=0, original_fixture_date=row['date'])
                connection.execute('INSERT OR IGNORE INTO history VALUES (?,?,?,?,?)',
                    (row['store_id'],row['product_id'],day.isoformat(),encode(record),'SYNTHETIC_CALENDAR_REPLAY'))
            connection.execute('''INSERT OR IGNORE INTO snapshots
                (store_id,product_id,snapshot_date,opening_inventory_units,days_to_expiry,
                 delivery_lead_time_days,pending_order_units,snapshot_source)
                SELECT store_id,product_id,?,opening_inventory_units,days_to_expiry,
                 delivery_lead_time_days,0,'CURRENT_DATE_DEMO_FIXTURE'
                FROM snapshots WHERE snapshot_date='2026-10-12' ''',(target.isoformat(),))
            for product,units,days in [('PROD_001',40,1),('PROD_033',150,3),('PROD_009',10,-1)]:
                connection.execute("UPDATE snapshots SET opening_inventory_units=?,days_to_expiry=? WHERE product_id=? AND snapshot_date=? AND snapshot_source IN ('CURRENT_DATE_DEMO_FIXTURE','MOCK_INVENTORY_2026_10_12')",
                                   (units,days,product,target.isoformat()))
            connection.execute('INSERT INTO demo_settings VALUES (?,?)',(marker,'1'))
        if not connection.execute("SELECT 1 FROM demo_settings WHERE key='scenario_ready'").fetchone():
            # Daily-level test cases: flash sale, early markdown, expired, normal.
            for product, units, days in [('PROD_001',40,1),('PROD_033',150,3),('PROD_009',10,-1)]:
                connection.execute('''UPDATE snapshots SET opening_inventory_units=?,days_to_expiry=?,
                    revision=revision+1,snapshot_source='ISOLATED_DEAL_DEMO_MOCK'
                    WHERE product_id=? AND snapshot_date=?''',(units,days,product,DEMO_DATE))
            connection.execute("INSERT INTO demo_settings VALUES ('scenario_ready','1')")
    return {'mode':'DEMO','business_date':target.isoformat(),'inventory_source':'ISOLATED_DEAL_DEMO_MOCK',
            'message':'Isolated simulated offers. Run a forecast and approve a markdown before switching to Customer.'}
