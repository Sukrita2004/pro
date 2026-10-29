"""Bangkok-calendar demo catch-up. Generated records are explicitly synthetic."""
import hashlib
import json
import math
import threading
import sqlite3
from pathlib import Path
from datetime import date, timedelta
from backend.storage import connect
from backend import lots


class DemoCalendar:
    def __init__(self, database, clock, get_day, snapshots, close, receive, forecast):
        self.database, self.clock, self.get_day = database, clock, get_day
        self.snapshots, self.close, self.receive, self.forecast = snapshots, close, receive, forecast
        self.lock = threading.RLock()

    def sync(self):
        with self.lock:
            with connect(self.database) as connection:
                ready=connection.execute("SELECT 1 FROM sqlite_master WHERE name='demo_settings'").fetchone()
                if not ready or not connection.execute('SELECT 1 FROM snapshots LIMIT 1').fetchone():
                    return {'status':'not_prepared'}
                stores=[row[0] for row in connection.execute('SELECT store_id FROM stores ORDER BY store_id')]
            target=self.clock()
            days={store:self.get_day(store) for store in stores}
            if any(day>target for day in days.values()):
                raise ValueError('A demo branch is ahead of the Thai calendar. Existing future records were preserved; automatic rollover cannot rewind them.')
            backup=Path(str(self.database)+'.pre_calendar.sqlite')
            if not backup.exists():
                source=sqlite3.connect(Path(self.database).resolve().as_uri()+'?mode=ro',uri=True)
                destination=sqlite3.connect(backup)
                try:
                    source.backup(destination)
                finally:
                    source.close(); destination.close()
            # Old date-replay fixtures sometimes contain synthetic rows on an
            # unfinished day. Archive them before replacing with balanced closes.
            with connect(self.database) as connection:
                connection.execute('CREATE TABLE IF NOT EXISTS demo_calendar_archived_history '
                    '(store_id TEXT,product_id TEXT,date TEXT,payload TEXT,source TEXT,PRIMARY KEY(store_id,product_id,date))')
                for store,day in days.items():
                    where="store_id=? AND date>=? AND source='SYNTHETIC_CALENDAR_REPLAY' AND NOT EXISTS " \
                        '(SELECT 1 FROM daily_closures d WHERE d.store_id=history.store_id AND d.product_id=history.product_id AND d.date=history.date)'
                    connection.execute('INSERT OR IGNORE INTO demo_calendar_archived_history SELECT store_id,product_id,date,payload,source FROM history WHERE '+where,(store,str(day)))
                    connection.execute('DELETE FROM history WHERE '+where,(store,str(day)))
            closed_count=received_count=0
            for store,day in days.items():
                while day<target:
                    with connect(self.database) as connection:
                        stock=self.snapshots(connection,day,store)
                        closed={r[0] for r in connection.execute('SELECT product_id FROM daily_closures WHERE store_id=? AND date=?',(store,str(day)))}
                    if len(stock)!=32:
                        raise ValueError(f'Incomplete demo snapshot for {store} on {day}.')
                    for row in stock:
                        if row['product_id'] in closed:
                            continue
                        with connect(self.database) as connection:
                            history=connection.execute('SELECT payload FROM history WHERE store_id=? AND product_id=? AND date<? ORDER BY date DESC LIMIT 14',
                                (store,row['product_id'],str(day))).fetchall()
                        mean=sum(json.loads(r[0])['actual_sales_units'] for r in history)/max(len(history),1)
                        salt=int(hashlib.sha256(f'{store}/{row["product_id"]}/{day}'.encode()).hexdigest()[:8],16)
                        factor=(.85+(salt%31)/100)*(1.1 if day.weekday()>=5 else 1)
                        available=sum(l['units'] for l in row['lots'] if l['expiry_date']>=str(day))
                        sales=min(available,max(0,round(mean*factor)))
                        after,_=lots.allocate(row['lots'],str(day),sales,0)
                        waste=sum(l['units'] for l in after if l['expiry_date']<=str(day))
                        identifier=f'calendar-close:{store}:{day}:{row["product_id"]}'
                        self.close(dict(request_id=identifier,store_id=store,product_id=row['product_id'],date=day,
                            actual_sales_units=sales,units_wasted=waste,closing_inventory_units=row['opening_inventory_units']-sales-waste,
                            out_of_stock_flag=int(sales==available),promotion_active=0,is_holiday=0,applied_discount_percent=0))
                        with connect(self.database) as connection:
                            connection.execute("UPDATE history SET source='DEMO_CALENDAR_SIMULATED_CLOSE' WHERE store_id=? AND product_id=? AND date=?",
                                               (store,row['product_id'],str(day)))
                        closed_count+=1
                    day+=timedelta(days=1)
                    received_count+=self._receive(store,day)
                    with connect(self.database) as connection:
                        connection.execute('INSERT OR REPLACE INTO demo_settings VALUES (?,?)',('active_day:'+store,str(day)))
            # Existing current-day balances (including staff receipts) are preserved.
            # Only missing calendar-replenishment records for newly carried days are created.
            with connect(self.database) as connection:
                connection.execute("INSERT OR REPLACE INTO demo_settings VALUES ('calendar_day',?)",(str(target),))
                connection.execute("INSERT OR REPLACE INTO demo_settings VALUES ('calendar_auto','1')")
            for store in stores:
                with connect(self.database) as connection:
                    existing=connection.execute('SELECT 1 FROM runs WHERE store_id=? AND snapshot_date=? LIMIT 1',(store,str(target))).fetchone()
                if not existing:
                    self.forecast(dict(request_id=f'calendar-forecast:{store}:{target}',store_id=store,
                        snapshot_date=target,holiday=0,planned_promotion=0,weather_mode='mock',scenario_id='normal'))
            return {'status':'synchronized','business_date':str(target),'stores':len(stores),
                    'simulated_closures':closed_count,'calendar_mode':'Asia/Bangkok','received_units':received_count}

    def _receive(self, store, day):
        received=0
        with connect(self.database) as connection:
            stock=self.snapshots(connection,day,store)
        for row in stock:
            identifier=f'calendar-receipt:{store}:{day}:{row["product_id"]}'
            with connect(self.database) as connection:
                if connection.execute('SELECT 1 FROM receipts WHERE request_id=?',(identifier,)).fetchone():
                    continue
                history=connection.execute('SELECT payload FROM history WHERE store_id=? AND product_id=? AND date<? ORDER BY date DESC LIMIT 14',
                    (store,row['product_id'],str(day))).fetchall()
                closed=connection.execute('SELECT 1 FROM daily_closures WHERE store_id=? AND product_id=? AND date=?',
                    (store,row['product_id'],str(day))).fetchone()
            if closed:
                continue
            mean=sum(json.loads(r[0])['actual_sales_units'] for r in history)/max(len(history),1)
            usable=sum(l['units'] for l in row['lots'] if l['expiry_date']>=str(day+timedelta(days=1)))
            desired=math.ceil(mean*min(2,max(1,row['standard_shelf_life_days']-1)))
            quantity=max(0,desired-usable)
            if quantity:
                self.receive(dict(request_id=identifier,store_id=store,product_id=row['product_id'],
                    received_date=day,expiry_date=day+timedelta(days=max(1,int(row['standard_shelf_life_days']))),
                    batch_id=f'AUTO-{store}-{row["product_id"]}-{day}',quantity=quantity,cost_price_usd=row['cost_price_usd']))
                with connect(self.database) as connection:
                    connection.execute("UPDATE inventory_lots SET source='DEMO_CALENDAR_RECEIPT' WHERE lot_key=?",('receipt:'+identifier,))
                    connection.execute("UPDATE snapshots SET snapshot_source=snapshot_source||'+DEMO_CALENDAR_RECEIPT' WHERE store_id=? AND product_id=? AND snapshot_date=? AND snapshot_source NOT LIKE '%DEMO_CALENDAR_RECEIPT%'",
                                       (store,row['product_id'],str(day)))
                received+=quantity
        return received
