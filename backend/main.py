"""FastAPI boundary for local FreshFlow inference and inventory workflows.

Real accounts and branch authorization protect normal data. Demo is isolated.
"""
import hmac
import json
import os
import re
import asyncio
import logging
from contextlib import suppress
from backend.demo_calendar import DemoCalendar
from contextlib import asynccontextmanager
from datetime import date as Date, datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field, model_validator

from backend.storage import ROOT, connect, encode, initialize
from backend.inference import ModelService, WeatherError
from backend.history import available_months, monthly_records
from backend.deal_demo import prepare as prepare_deal_demo
from backend.branches import BRANCHES
from backend import lots as lot_stock
from backend.accounts import Accounts
from backend.backups import Backups

Units = Annotated[int, Field(strict=True, ge=0)]
Flag = Literal[0, 1]
Identifier = Annotated[str, Field(min_length=1, max_length=120)]


def now():
    return datetime.now(timezone.utc).isoformat()


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)


class Run(Input):
    request_id: Identifier
    snapshot_date: Date
    store_id: Identifier
    scenario_id: Literal['normal','rainy','hot','hot_rainy','clear-demo','rain-demo'] = 'normal'
    prediction_source: Literal['ML'] = 'ML'
    rule_version: Literal['generator-aligned-v2'] = 'generator-aligned-v2'
    holiday: Flag
    planned_promotion: Flag
    weather_mode: Literal['mock','live'] = 'mock'
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


class Receipt(Input):
    request_id: Identifier
    store_id: Identifier
    product_id: Identifier
    received_date: Date
    batch_id: Identifier
    expiry_date: Date
    quantity: Annotated[int, Field(strict=True, gt=0)]
    cost_price_usd: float = Field(ge=0)
    received_against_pending_units: Units = 0

    @model_validator(mode='after')
    def valid_dates(self):
        if self.expiry_date < self.received_date:
            raise ValueError('Receipt expiry cannot precede receipt date.')
        if self.received_against_pending_units > self.quantity:
            raise ValueError('Pending units received cannot exceed receipt quantity.')
        return self


class CloseDay(Input):
    request_id: Identifier
    store_id: Identifier
    product_id: Identifier
    date: Date
    actual_sales_units: Units
    units_wasted: Units
    closing_inventory_units: Units
    out_of_stock_flag: Flag
    promotion_active: Flag
    is_holiday: Flag
    applied_discount_percent: float = Field(ge=0, le=100)


class Approval(Input):
    status: Literal['APPROVED','REJECTED']
    acknowledge_below_cost: bool = False


class DemoDay(Input):
    store_id: Identifier
    date: Date


def require_key(x_api_key: str | None = Header(default=None)):
    expected = os.environ.get('FRESHFLOW_API_KEY')
    if expected and not hmac.compare_digest(expected, x_api_key or ''):
        raise HTTPException(401, 'Invalid API key')


def snapshots(connection, day, store):
    rows = [dict(row) for row in connection.execute('''SELECT s.*,p.product_name,p.category,
        p.base_price_usd,p.cost_price_usd,p.standard_shelf_life_days FROM snapshots s
        JOIN products p USING(product_id) WHERE snapshot_date=? AND store_id=? ORDER BY product_id''',
        (str(day), store))]
    for row in rows:
        row['lots']=lot_stock.ensure(connection,row)
        row['revision']=connection.execute('SELECT revision FROM snapshots WHERE snapshot_id=?',(row['snapshot_id'],)).fetchone()[0]
    return rows


def sale_window(snapshot, as_of):
    snapshot_day = Date.fromisoformat(snapshot['snapshot_date'])
    remaining = snapshot['days_to_expiry'] - (as_of - snapshot_day).days
    if 'lots' in snapshot:
        eligible=[lot for lot in snapshot['lots'] if lot['units']>0 and lot['expiry_date']>=str(as_of)]
        expiry=min((lot['expiry_date'] for lot in eligible),default=str(snapshot_day+timedelta(days=snapshot['days_to_expiry'])))
        return {'days_until_expiry_now':(Date.fromisoformat(expiry)-as_of).days,'expiry_date':expiry,
                'sale_eligible_now':snapshot_day<=as_of and bool(eligible),
                'sellable_units_now':sum(lot['units'] for lot in eligible)}
    return {'days_until_expiry_now':remaining,
            'expiry_date':(snapshot_day+timedelta(days=snapshot['days_to_expiry'])).isoformat(),
            'sale_eligible_now':snapshot_day <= as_of and remaining >= 0 and snapshot['opening_inventory_units'] > 0}


def latest_records(connection, day, store, as_of=None):
    snapshots(connection,day,store)  # Materialize migration and invalidate scalar-only recommendations.
    rows = connection.execute('''SELECT r.*,n.model_version,n.metadata_version,n.created_at
        FROM recommendations r JOIN runs n USING(run_id)
        JOIN snapshots s USING(snapshot_id)
        WHERE n.run_id=(SELECT MAX(run_id) FROM runs WHERE snapshot_date=? AND store_id=?)
        AND r.snapshot_revision=s.revision ORDER BY r.snapshot_id''', (str(day), store))
    records = []
    for row in rows:
        value = json.loads(row['result'])
        value.update({key: row[key] for key in ['recommendation_id','run_id','snapshot_id',
                      'approval_status','model_version','metadata_version','created_at']})
        if as_of is not None:
            value.update(sale_window(value['input_payload']['snapshot'],as_of))
            value['sale_eligible_now'] = value['sale_eligible_now'] and value['result']['sale_allowed']
            lots=value['input_payload']['snapshot'].get('lots')
            if lots is not None and value['result']['discount_percent']:
                batches=value['result'].get('discount_batch_ids',[])
                offered=[l for l in lots if l['batch_id'] in batches and l['units']>0 and l['expiry_date']>=str(as_of)]
                value['discount_units_now']=sum(l['units'] for l in offered)
                if offered:
                    value['expiry_date']=min(l['expiry_date'] for l in offered)
                if not offered:
                    value['actions']=[a for a in value['actions'] if a['action']!='DISCOUNT']
            if not value['sale_eligible_now']:
                # Retain the original historical result for audit, but never expose
                # its markdown as a current actionable sale recommendation.
                value['actions'] = [action for action in value['actions'] if action['action']!='DISCOUNT']
        records.append(value)
    return records


def create_app(database=None, artifacts=None, business_clock=None, is_demo=False, automatic_demo=True, authentication=True, backup_directory=None):
    database = Path(database or os.environ.get('FRESHFLOW_DB', ROOT / 'data/application.db'))
    artifacts = Path(artifacts or os.environ.get('FRESHFLOW_MODEL_DIR', ROOT / 'artifacts/model'))
    business_clock = business_clock or (lambda: datetime.now(timezone(timedelta(hours=7))).date())
    # Reopen the established demo session across calendar-day restarts.
    # Never silently switch staff to a new day's seed database.
    established=sorted(database.parent.glob(database.stem+'_demo_????-??-??.db'))
    demo_database = Path(os.environ['FRESHFLOW_DEMO_DB']) if os.environ.get('FRESHFLOW_DEMO_DB') else (
        established[0] if established else database.with_name(database.stem+'_demo_'+business_clock().isoformat()+'.db'))
    match=re.search(r'_demo_(\d{4}-\d{2}-\d{2})\.db$',(database if is_demo else demo_database).name)
    demo_base_date=match.group(1) if match else business_clock().isoformat()
    demo_app = None
    accounts = Accounts(database,is_demo=is_demo) if authentication else None
    backup_root = Path(backup_directory or os.environ.get('FRESHFLOW_BACKUP_DIR') or ROOT/'backups')
    backups = Backups(database,demo_database,backup_root/'demo_accounts' if is_demo else backup_root,demo_only=is_demo) if accounts else None

    @asynccontextmanager
    async def lifespan(app):
        initialize(database)
        app.state.model = ModelService(artifacts)
        if demo_app is not None:
            initialize(demo_database)
            demo_app.state.model = app.state.model
            if demo_app.state.accounts:
                demo_app.state.accounts.initialize()
        if accounts:
            accounts.initialize()
        async def backup_loop():
            while True:
                for target in [backups]+([demo_app.state.backups] if demo_app is not None and demo_app.state.backups else []):
                    try:
                        await asyncio.to_thread(target.daily)
                    except Exception as error:
                        target.error=str(error)
                        logging.getLogger(__name__).exception('Automatic backup failed')
                await asyncio.sleep(60)
        async def calendar_loop():
            while True:
                try:
                    await asyncio.to_thread(demo_app.state.calendar.sync)
                    demo_app.state.calendar_error=None
                except Exception as error:
                    demo_app.state.calendar_error=str(error)
                    logging.getLogger(__name__).warning('Demo calendar update failed: %s',error)
                await asyncio.sleep(30)
        task=asyncio.create_task(calendar_loop()) if demo_app is not None and automatic_demo else None
        backup_task=asyncio.create_task(backup_loop()) if backups else None
        try:
            yield
        finally:
            if backup_task:
                backup_task.cancel()
                with suppress(asyncio.CancelledError): await backup_task
            if task:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    app = FastAPI(title='FreshFlow Retail API', version='1.0.0', lifespan=lifespan)
    protected = [] if authentication else [Depends(require_key)]
    if accounts:
        accounts.install(app)
        backups.install(app)
    app.add_middleware(CORSMiddleware,
        allow_origins=['http://127.0.0.1:8080','http://localhost:8080'],
        allow_methods=['GET','POST','PATCH','OPTIONS'],
        allow_headers=['Content-Type','X-API-Key','Authorization'])
    app.state.accounts=accounts
    app.state.backups=backups

    def store_day(store_id):
        if is_demo:
            with connect(database) as connection:
                connection.execute('CREATE TABLE IF NOT EXISTS demo_settings (key TEXT PRIMARY KEY,value TEXT NOT NULL)')
                row=connection.execute('SELECT value FROM demo_settings WHERE key=?',('active_day:'+store_id,)).fetchone()
                if not row:
                    row=connection.execute("SELECT substr(key,17) FROM demo_settings WHERE key LIKE 'current_fixture_%' ORDER BY key LIMIT 1").fetchone()
            if row:
                return Date.fromisoformat(row[0])
        return business_clock()

    def synchronize_demo():
        if is_demo and automatic_demo:
            try:
                return app.state.calendar.sync()
            except ValueError as error:
                raise HTTPException(409,str(error)) from None

    @app.get('/api/v1/demo/day', dependencies=protected)
    def demo_day(store_id: str):
        if not is_demo:
            raise HTTPException(404,'Demo only.')
        synchronize_demo()
        return {'business_date':store_day(store_id).isoformat(),'store_id':store_id,'session':database.name,
                'session_started_date':demo_base_date,'automatic_calendar':automatic_demo,
                'timezone':'Asia/Bangkok'}

    @app.get('/api/v1/weather/current', dependencies=protected)
    def current_weather(store_id: str):
        from backend.inference import OpenWeatherClient
        branch = BRANCHES.get(store_id)
        if branch is None:
            raise HTTPException(422,'Unknown store location.')
        try:
            return {'store_id':store_id,'branch':branch,
                    'weather':OpenWeatherClient().current(branch['lat'],branch['lon']).to_dict()}
        except WeatherError as error:
            raise HTTPException(502,str(error)) from None

    @app.get('/api/v1/weather-merchandise', dependencies=protected)
    def weather_merchandise(store_id: str):
        """Supplementary non-food fixtures; deliberately excluded from ML."""
        if not is_demo:
            return {'items':[],'rainy':False}
        with connect(database) as connection:
            run = connection.execute('SELECT request_payload,run_id FROM runs WHERE store_id=? AND snapshot_date=? ORDER BY run_id DESC LIMIT 1',
                                     (store_id,store_day(store_id).isoformat())).fetchone()
            saved = connection.execute('SELECT result FROM recommendations WHERE run_id=? LIMIT 1',
                                       (run['run_id'],)).fetchone() if run else None
        weather = json.loads(saved[0])['result']['weather'] if saved else None
        scenario = json.loads(run[0])['scenario_id'] if run else 'normal'
        # Use the weather actually used by the run, including live API output.
        rainy = bool(weather and (weather['condition']=='RAIN' or weather['rain_probability']>=.6))
        hot = bool(weather and weather['temperature_c']>=35)
        return {'run_id':run['run_id'] if run else None,'business_date':store_day(store_id).isoformat(),
                'rainy':rainy,'hot':hot,'scenario':scenario,'weather':weather,'source':'RULE_BASED_DEMO; not an ML forecast',
                'items':[{'name':name,'stock_units':stock,'price_usd':price,
                          'price_increase_percent':30 if rainy else 0,
                          'adjusted_price_usd':round(price * (1.3 if rainy else 1),2),
                          'suggested_restock_units':qty if rainy else 0}
                         for name,stock,price,qty in [('Umbrella',18,8.0,6),('Raincoat',24,5.0,8)]
                         if rainy or (hot and name=='Umbrella')]}

    @app.get('/health')
    def health():
        model = app.state.model
        return {'status':'ok','prediction_source':'ML','model_version':model.model_version,
                'metadata_version':model.metadata_version,'policy_version':'generator-aligned-v2',
                'authentication':'accounts' if accounts else ('demo_sandbox' if authentication else 'test_legacy_key')}

    @app.get('/api/v1/data-info', dependencies=protected)
    def data_info():
        return {'mode':'DEMO' if is_demo else 'NORMAL',
                'business_date':business_clock().isoformat(),
                'training_dataset':'inventory_management_ref.csv',
                'training_data_type':'synthetic',
                'initial_application_history':'external synthetic data, 2026-07-11 through 2026-10-11',
                'initial_inventory':'mock snapshot for 2026-10-12',
                'model':'existing frozen ML model; not retrained by demo mode'}

    @app.get('/api/v1/history/months', dependencies=protected)
    def history_months(store_id: str, source: Literal['application','training']='application',
                       record_type: Literal['sales','receipts','daily_closures','forecast_runs']='sales'):
        return available_months(database,store_id,source,record_type)

    @app.get('/api/v1/history', dependencies=protected)
    def history_records(store_id: str, month: str = Query(pattern=r'^\d{4}-(0[1-9]|1[0-2])$'),
                        source: Literal['application','training']='application',
                        record_type: Literal['sales','receipts','daily_closures','forecast_runs']='sales',
                        limit: int = Query(50,ge=1,le=200),offset: int = Query(0,ge=0)):
        return monthly_records(database,store_id,source,record_type,month,limit,offset)

    @app.get('/api/v1/history/runs/{run_id}', dependencies=protected)
    def historical_run(run_id: int, store_id: str):
        with connect(database) as connection:
            run_row = connection.execute('SELECT * FROM runs WHERE run_id=? AND store_id=?',(run_id,store_id)).fetchone()
            if not run_row:
                raise HTTPException(404,'Run not found in selected store.')
            records = [dict(row) for row in connection.execute('SELECT * FROM recommendations WHERE run_id=? ORDER BY snapshot_id',(run_id,))]
        for row in records:
            row['result'] = json.loads(row['result'])
        return {'run':dict(run_row),'recommendations':records,'historical_only':True,
                'note':'Original recorded results, including superseded runs. Not current customer offers.'}

    @app.get('/api/v1/stores', dependencies=protected)
    def stores():
        with connect(database) as connection:
            return [dict(row) for row in connection.execute('SELECT * FROM stores ORDER BY store_id')]

    @app.get('/api/v1/products', dependencies=protected)
    def products():
        with connect(database) as connection:
            return [dict(row) for row in connection.execute('SELECT * FROM products ORDER BY product_id')]

    @app.get('/api/v1/inventory', dependencies=protected)
    def inventory(date: Date, store_id: str, limit: int = Query(200, ge=1, le=1000),
                  max_days: float | None = None, in_stock_only: bool = False):
        with connect(database) as connection:
            rows = snapshots(connection, date, store_id)
        return [row for row in rows if (not in_stock_only or row['opening_inventory_units'] > 0)
                and (max_days is None or row['days_to_expiry'] <= max_days)][:limit]

    @app.get('/api/v1/recommendations', dependencies=protected)
    def recommendations(date: Date, store_id: str):
        with connect(database) as connection:
            return latest_records(connection, date, store_id,store_day(store_id))

    @app.get('/api/v1/dashboard/summary', dependencies=protected)
    def summary(date: Date, store_id: str):
        with connect(database) as connection:
            stock = snapshots(connection, date, store_id)
            recs = latest_records(connection, date, store_id,store_day(store_id))
            closures = [json.loads(row[0]) for row in connection.execute(
                'SELECT payload FROM daily_closures WHERE date=? AND store_id=?',(str(date),store_id))]
            closed_ids = {row['product_id'] for row in closures}
            open_ids = {row['product_id'] for row in stock} - closed_ids
            # A close invalidates that product's recommendation deliberately.
            # Closed products are not missing actionable forecasts for this day.
            recs = [row for row in recs if row['product_id'] in open_ids]
            valid_ids = {row['product_id'] for row in recs}
            previous_day = str(date - timedelta(days=1))
            previous_ids = {row[0] for row in connection.execute(
                'SELECT product_id FROM snapshots WHERE store_id=? AND snapshot_date=?',
                (store_id, previous_day))}
            previous_closed = {row[0] for row in connection.execute(
                'SELECT product_id FROM daily_closures WHERE store_id=? AND date=?',
                (store_id, previous_day))}
            history_day = connection.execute('SELECT MAX(date) FROM history WHERE store_id=? AND date<?',
                                             (store_id,str(date))).fetchone()[0]
        return {'date':str(date),'store_id':store_id,'snapshot_count':len(stock),
            'total_opening_units':sum(row['opening_inventory_units'] for row in stock),
            'near_expiry_in_stock_count':sum(row['opening_inventory_units'] > 0 and 0 <= row['days_to_expiry'] <= 2 for row in stock),
            'action_counts':{action:sum(any(a['action']==action for a in row['actions']) and (action!='DISCOUNT' or row['sale_eligible_now']) for row in recs)
                             for action in ['DISCOUNT','RESTOCK']},
            'predicted_demand_total':sum(row['prediction']['predicted_demand_units'] for row in recs) if recs else None,
            'valid_forecast_count':len(recs),
            'open_product_count':len(open_ids),
            'closed_product_count':len(closed_ids),
            'missing_open_forecast_count':len(open_ids-valid_ids),
            'previous_business_date':previous_day,
            'previous_unclosed_product_count':len(previous_ids-previous_closed),
            'latest_history_date':history_day,
            'closure_complete':bool(stock) and len(closed_ids)==len(stock),
            'recorded_sales_units':sum(row['actual_sales_units'] for row in closures) if closures else None,
            'recorded_closing_units':sum(row['closing_inventory_units'] for row in closures) if closures else None,
            'prediction_source':'ML' if recs else None,
            'inventory_sources':sorted(set(row['snapshot_source'] for row in stock)),
            'recorded_waste_units':sum(row['units_wasted'] for row in closures) if closures else None,
            'waste_reduction_percent':None,'profit_improvement':None,
            'model_version':app.state.model.model_version}

    @app.post('/api/v1/recommendation-runs', dependencies=protected)
    def run(request: Run):
        if is_demo and request.snapshot_date!=store_day(request.store_id):
            raise HTTPException(422,'Deal demo uses the current business date.')
        payload = encode(request.model_dump(mode='json'))
        with connect(database) as connection:
            prior = connection.execute('SELECT * FROM runs WHERE request_id=?',(request.request_id,)).fetchone()
            if prior:
                if prior['request_payload'] != payload:
                    raise HTTPException(409,'Request ID already used with different content.')
                return {'run_id':prior['run_id'],'status':'already_completed','prediction_source':'ML'}
            stock = snapshots(connection, request.snapshot_date, request.store_id)
            history = [json.loads(row[0]) for row in connection.execute(
                'SELECT payload FROM history WHERE store_id=? AND date<? ORDER BY product_id,date',
                (request.store_id,str(request.snapshot_date)))]
        if not stock:
            raise HTTPException(422,'No inventory snapshot for selected store/date.')
        try:
            model = app.state.model
            predictions = model.predict(history, request.snapshot_date, request.holiday, request.planned_promotion)
            if set(predictions) != {row['product_id'] for row in stock}:
                raise ValueError('All historical products require a target-day snapshot.')
            weather = model.weather(request)
            values = []
            for snapshot in stock:
                result = model.recommend(snapshot, predictions[snapshot['product_id']], weather, request.planned_promotion)
                actions = []
                if result['discount_percent'] and result['sale_allowed']:
                    actions.append({'action':'DISCOUNT','discount_percent':result['discount_percent'],
                        'discount_type':result['discount_type'],
                        'selling_price_usd':result['selling_price_usd'],
                        'potential_excess_units':result['projected_surplus_before_expiry_units'],
                        'reason_code':result['discount_action']})
                if result['restock_quantity_units']:
                    actions.append({'action':'RESTOCK','quantity_units':result['restock_quantity_units'],
                                    'reason_code':result['restock_action']})
                values.append({'product_id':snapshot['product_id'],'store_id':request.store_id,
                    'snapshot_date':str(request.snapshot_date),'prediction_source':'ML',
                    'inventory_source':snapshot['snapshot_source'],'policy_version':result['policy_version'],
                    'prediction':{'predicted_demand_units':result['predicted_demand_units']},
                    'input_payload':{'snapshot':snapshot},'actions':actions,'result':result})
        except WeatherError as error:
            raise HTTPException(502,str(error)) from None
        except ValueError as error:
            raise HTTPException(422,str(error)) from None
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            # Serialize idempotent writers and reject stale inventory after inference.
            prior = connection.execute('SELECT * FROM runs WHERE request_id=?',(request.request_id,)).fetchone()
            if prior:
                if prior['request_payload'] != payload:
                    raise HTTPException(409,'Request ID conflict.')
                return {'run_id':prior['run_id'],'status':'already_completed','prediction_source':'ML'}
            current = snapshots(connection, request.snapshot_date, request.store_id)
            if [(s['snapshot_id'],s['revision']) for s in current] != [(s['snapshot_id'],s['revision']) for s in stock]:
                raise HTTPException(409,'Inventory changed while forecasting; run again.')
            cursor = connection.execute('''INSERT INTO runs
                (request_id,request_payload,snapshot_date,store_id,created_at,model_version,metadata_version)
                VALUES (?,?,?,?,?,?,?)''',(request.request_id,payload,str(request.snapshot_date),request.store_id,
                                           now(),model.model_version,model.metadata_version))
            run_id = cursor.lastrowid
            for snapshot, value in zip(stock,values):
                connection.execute('''INSERT INTO recommendations
                    (run_id,snapshot_id,snapshot_revision,result) VALUES (?,?,?,?)''',
                    (run_id,snapshot['snapshot_id'],snapshot['revision'],encode(value)))
        return {'run_id':run_id,'count':len(values),'prediction_source':'ML',
                'model_version':model.model_version,'weather_source':weather.source}

    @app.patch('/api/v1/recommendations/{recommendation_id}/status', dependencies=protected)
    def approve(recommendation_id: int, request: Approval):
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            record = connection.execute('''SELECT r.*,s.revision,n.store_id,n.snapshot_date FROM recommendations r
                JOIN snapshots s USING(snapshot_id) JOIN runs n USING(run_id)
                WHERE recommendation_id=?''',(recommendation_id,)).fetchone()
            if not record:
                raise HTTPException(404,'Recommendation not found.')
            latest = connection.execute('SELECT MAX(run_id) FROM runs WHERE store_id=? AND snapshot_date=?',
                                        (record['store_id'],record['snapshot_date'])).fetchone()[0]
            if record['snapshot_revision'] != record['revision'] or record['run_id'] != latest:
                raise HTTPException(409,'Recommendation is stale; generate a new run.')
            saved = json.loads(record['result'])
            if request.status=='APPROVED' and saved['result']['discount_percent'] and not saved['result'].get('markdown_policy_version'):
                raise HTTPException(409,'Regenerate this recommendation to review the regular/clearance policy.')
            if request.status=='APPROVED' and saved['result'].get('below_cost') and not request.acknowledge_below_cost:
                raise HTTPException(422,'Below-cost clearance requires explicit acknowledgement.')
            if request.status == 'APPROVED' and any(a['action']=='DISCOUNT' for a in saved['actions']):
                if not sale_window(saved['input_payload']['snapshot'],store_day(record['store_id']))['sale_eligible_now']:
                    raise HTTPException(409,'Markdown cannot be approved: stock is expired, unavailable or not yet current.')
                saved_lots=saved['input_payload']['snapshot'].get('lots')
                if saved_lots is not None and not any(l['units']>0 and l['batch_id'] in saved['result'].get('discount_batch_ids',[])
                    and l['expiry_date']>=str(store_day(record['store_id'])) for l in saved_lots):
                    raise HTTPException(409,'The batches selected for this markdown are no longer sellable.')
            connection.execute('UPDATE recommendations SET approval_status=? WHERE recommendation_id=?',
                               (request.status,recommendation_id))
            connection.execute('INSERT INTO approval_decisions (recommendation_id,payload,created_at) VALUES (?,?,?)',
                               (recommendation_id,encode(request.model_dump()),now()))
        return {'recommendation_id':recommendation_id,'approval_status':request.status}

    @app.get('/api/v1/deals')
    def deals(date: Date, store_id: str):
        with connect(database) as connection:
            rows = [row for row in latest_records(connection,date,store_id,store_day(store_id))
                    if row['approval_status']=='APPROVED' and row['result']['sale_allowed']
                    and row['sale_eligible_now'] and row['result']['discount_percent']>0
                    and any(a['action']=='DISCOUNT' for a in row['actions'])]
        if accounts:
            return [{'recommendation_id':r['recommendation_id'],'product_id':r['product_id'],
                'product_name':r['input_payload']['snapshot']['product_name'],
                'store_id':store_id,'snapshot_date':str(date),'expiry_date':r['expiry_date'],
                'stock_units':r.get('discount_units_now',0),
                'original_price_usd':r['input_payload']['snapshot']['base_price_usd'],
                'selling_price_usd':r['result']['selling_price_usd'],
                'discount_percent':r['result']['discount_percent'],'sale_eligible_now':True}
                for r in rows]
        return rows

    @app.get('/api/v1/notifications', dependencies=protected)
    def notifications(date: Date, store_id: str):
        with connect(database) as connection:
            read = {row[0] for row in connection.execute('SELECT notification_id FROM notification_reads')}
            rows = latest_records(connection,date,store_id)
        return [{'id':f"rec-{row['recommendation_id']}",'type':'warning',
                 'title':f"{row['product_id']} — inventory recommendation",'detail':', '.join(row['result']['reasons']),
                 'time':row['created_at'],'unread':f"rec-{row['recommendation_id']}" not in read}
                for row in rows if row['actions'] or row['result']['remove_expired_units']]

    @app.patch('/api/v1/notifications/{notification_id}/read', dependencies=protected)
    def read_notification(notification_id: str):
        with connect(database) as connection:
            connection.execute('INSERT OR IGNORE INTO notification_reads VALUES (?)',(notification_id,))
        return {'id':notification_id,'unread':False}

    @app.post('/api/v1/receipts', dependencies=protected)
    def receive(request: Receipt):
        payload = encode(request.model_dump(mode='json'))
        day = str(request.received_date)
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            prior = connection.execute('SELECT payload FROM receipts WHERE request_id=?',(request.request_id,)).fetchone()
            if prior:
                if prior[0] != payload:
                    raise HTTPException(409,'Receipt request ID conflict.')
                return {'status':'already_received','request_id':request.request_id}
            product = connection.execute('SELECT * FROM products WHERE product_id=?',(request.product_id,)).fetchone()
            store = connection.execute('SELECT 1 FROM stores WHERE store_id=?',(request.store_id,)).fetchone()
            if not product or not store:
                raise HTTPException(422,'Unknown product or store.')
            if connection.execute('SELECT 1 FROM history WHERE store_id=? AND product_id=? AND date>=?',
                                  (request.store_id,request.product_id,day)).fetchone():
                raise HTTPException(409,'Cannot add receipts to a closed/historical day.')
            previous = connection.execute('SELECT * FROM snapshots WHERE store_id=? AND product_id=? AND snapshot_date=?',
                                          (request.store_id,request.product_id,day)).fetchone()
            existing=[]
            if previous:
                existing=lot_stock.ensure(connection,{**dict(previous),'cost_price_usd':product['cost_price_usd']})
                if any(l['batch_id']==request.batch_id and (l['expiry_date']!=str(request.expiry_date) or l['cost_price_usd']!=request.cost_price_usd) for l in existing):
                    raise HTTPException(409,'This batch already has a different expiry date or unit cost.')
            expiry = (request.expiry_date-request.received_date).days
            if previous:
                if request.received_against_pending_units > previous['pending_order_units']:
                    raise HTTPException(422,'Receipt exceeds outstanding pending quantity.')
                expiry = min(expiry,previous['days_to_expiry']) if previous['opening_inventory_units'] else expiry
                connection.execute('''UPDATE snapshots SET opening_inventory_units=opening_inventory_units+?,
                    days_to_expiry=?,pending_order_units=pending_order_units-?,revision=revision+1,
                    snapshot_source=? WHERE snapshot_id=?''',
                    (request.quantity,expiry,request.received_against_pending_units,
                     previous['snapshot_source']+'+STAFF_RECEIPT',previous['snapshot_id']))
            else:
                if request.received_against_pending_units:
                    raise HTTPException(422,'No pending inventory position for this receipt.')
                connection.execute('''INSERT INTO snapshots
                    (store_id,product_id,snapshot_date,opening_inventory_units,days_to_expiry,snapshot_source)
                    VALUES (?,?,?,?,?,?)''',(request.store_id,request.product_id,day,request.quantity,expiry,'STAFF_RECEIPT'))
            connection.execute('INSERT INTO receipts VALUES (?,?,?)',(request.request_id,payload,now()))
            sid=connection.execute('SELECT snapshot_id FROM snapshots WHERE store_id=? AND product_id=? AND snapshot_date=?',
                                   (request.store_id,request.product_id,day)).fetchone()[0]
            existing.append({'lot_key':'receipt:'+request.request_id,'batch_id':request.batch_id,
                'expiry_date':str(request.expiry_date),'units':request.quantity,
                'cost_price_usd':request.cost_price_usd,'source':'RECORDED_RECEIPT'})
            lot_stock.write(connection,sid,existing)
        return {'status':'received','request_id':request.request_id,'quantity':request.quantity,
                'note':'Receipt lot retained separately; sales and waste use FEFO.'}

    def close_day_impl(request: CloseDay, allow_demo_fixture=False):
        payload = encode(request.model_dump(mode='json'))
        day = request.date.isoformat()
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            prior = connection.execute('SELECT payload FROM daily_closures WHERE request_id=?',(request.request_id,)).fetchone()
            if prior:
                if prior[0] != payload:
                    raise HTTPException(409,'Daily close request ID conflict.')
                return {'status':'already_closed'}
            if connection.execute('SELECT 1 FROM history WHERE store_id=? AND product_id=? AND date>=?',
                                  (request.store_id,request.product_id,day)).fetchone():
                raise HTTPException(409,'A history entry already exists on or after this date.')
            rows = snapshots(connection,day,request.store_id)
            stock = next((row for row in rows if row['product_id']==request.product_id),None)
            if not stock:
                raise HTTPException(422,'Create a target-day inventory snapshot before closing.')
            if stock['opening_inventory_units'] != request.actual_sales_units+request.units_wasted+request.closing_inventory_units:
                raise HTTPException(422,'Inventory balance must equal opening minus sales minus waste.')
            try:
                remaining_lots,movements=lot_stock.allocate(stock['lots'],day,request.actual_sales_units,request.units_wasted)
            except ValueError as error:
                raise HTTPException(422,str(error)) from None
            previous = connection.execute('SELECT date,payload FROM history WHERE store_id=? AND product_id=? ORDER BY date DESC LIMIT 28',
                                          (request.store_id,request.product_id)).fetchall()
            if not previous or Date.fromisoformat(previous[0]['date'])+timedelta(days=1) != request.date:
                raise HTTPException(422,'Daily close must continue the existing daily history without gaps.')
            mean = sum(json.loads(row['payload'])['actual_sales_units'] for row in previous)/len(previous)
            near = sum(l['units'] for l in stock['lots'] if day<=l['expiry_date']<=str(request.date+timedelta(days=1)))
            # Generator-style surplus risk using trailing sales as an explicit proxy for latent smooth demand.
            risk = round(min(1.,near/max(stock['opening_inventory_units'],1)*max(0.,1-mean/max(near,1))),4)
            record = {key:stock[key] for key in ['store_id','product_id','category','base_price_usd','standard_shelf_life_days']}
            record.update({'date':day,'is_weekend':int(request.date.weekday()>=5),'is_holiday':request.is_holiday,
                'promotion_active':request.promotion_active,'actual_sales_units':request.actual_sales_units,
                'out_of_stock_flag':request.out_of_stock_flag,'applied_discount_percent':request.applied_discount_percent,
                'days_until_expiry':stock['days_to_expiry'],'expiration_risk_score':risk})
            received=connection.execute("SELECT COALESCE(SUM(json_extract(payload,'$.quantity')),0) FROM receipts "
                "WHERE json_extract(payload,'$.store_id')=? AND json_extract(payload,'$.product_id')=? "
                "AND json_extract(payload,'$.received_date')=?",(request.store_id,request.product_id,day)).fetchone()[0]
            costs={l['lot_key']:l['cost_price_usd'] for l in stock['lots']}
            record.update(opening_inventory_units=stock['opening_inventory_units']-received,
                received_inventory_units=received,units_wasted=request.units_wasted,
                closing_inventory_units=request.closing_inventory_units,
                sales_revenue_usd=round(request.actual_sales_units*round(stock['base_price_usd']*(1-request.applied_discount_percent/100),2),2),
                waste_financial_loss_usd=round(sum(m['units']*costs[m['lot_key']] for m in movements if m['kind']=='waste'),2))
            connection.execute('INSERT INTO history VALUES (?,?,?,?,?)',
                (request.store_id,request.product_id,day,encode(record),'STAFF_CLOSE_ESTIMATED_SCALAR_RISK'))
            connection.execute('INSERT INTO daily_closures VALUES (?,?,?,?,?,?)',
                (request.request_id,payload,now(),request.store_id,request.product_id,day))
            connection.execute('INSERT INTO closure_lot_allocations VALUES (?,?)',(request.request_id,encode(movements)))
            connection.execute('UPDATE snapshots SET revision=revision+1 WHERE snapshot_id=?',(stock['snapshot_id'],))
            tomorrow = (request.date+timedelta(days=1)).isoformat()
            # Carry forward only known closing stock. Future receipts remain a separate transaction.
            existing=connection.execute('SELECT * FROM snapshots WHERE store_id=? AND product_id=? AND snapshot_date=?',
                                  (request.store_id,request.product_id,tomorrow)).fetchone()
            if existing:
                safe=is_demo and allow_demo_fixture and existing['snapshot_source'] in {
                    'CURRENT_DATE_DEMO_FIXTURE','MOCK_INVENTORY_2026_10_12','ISOLATED_DEAL_DEMO_MOCK'}
                if not safe:
                    raise HTTPException(409,'Next-day snapshot exists; resolve it before closing to avoid double counting.')
                connection.execute('UPDATE snapshots SET opening_inventory_units=?,days_to_expiry=?,snapshot_source=?,revision=revision+1 WHERE snapshot_id=?',
                    (request.closing_inventory_units,stock['days_to_expiry']-1,stock['snapshot_source']+'+DAILY_CLOSE_CARRY_FORWARD',existing['snapshot_id']))
                next_id=existing['snapshot_id']
            else:
                connection.execute('''INSERT INTO snapshots
                (store_id,product_id,snapshot_date,opening_inventory_units,days_to_expiry,
                 delivery_lead_time_days,pending_order_units,snapshot_source) VALUES (?,?,?,?,?,?,?,?)''',
                (request.store_id,request.product_id,tomorrow,request.closing_inventory_units,
                 stock['days_to_expiry']-1,stock['delivery_lead_time_days'],stock['pending_order_units'],
                 stock['snapshot_source']+'+DAILY_CLOSE_CARRY_FORWARD'))
                next_id=connection.execute('SELECT last_insert_rowid()').fetchone()[0]
            lot_stock.write(connection,next_id,remaining_lots)
            remaining_expiries=[l['expiry_date'] for l in remaining_lots if l['units']>0]
            if remaining_expiries:
                connection.execute('UPDATE snapshots SET days_to_expiry=? WHERE snapshot_id=?',
                    ((Date.fromisoformat(min(remaining_expiries))-Date.fromisoformat(tomorrow)).days,next_id))
        return {'status':'closed','next_snapshot_date':tomorrow,'risk_source':'estimated_scalar_proxy'}

    @app.post('/api/v1/daily-closures', dependencies=protected)
    def close_day(request: CloseDay):
        return close_day_impl(request)

    @app.post('/api/v1/demo/close-remaining', dependencies=protected)
    def simulate_remaining(request: DemoDay):
        if not is_demo:
            raise HTTPException(404,'Demo only.')
        if request.date!=store_day(request.store_id):
            raise HTTPException(409,'Refresh the current demo date.')
        with connect(database) as connection:
            stock=snapshots(connection,request.date,request.store_id)
            closed={row[0] for row in connection.execute('SELECT product_id FROM daily_closures WHERE date=? AND store_id=?',
                                                       (str(request.date),request.store_id))}
        if len(stock)!=32:
            raise HTTPException(422,'A complete 32-product snapshot is required.')
        count=0
        for row in stock:
            if row['product_id'] in closed:
                continue
            units=row['opening_inventory_units']
            available=sum(l['units'] for l in row['lots'] if l['expiry_date']>=str(request.date))
            sales=min(available,2)
            after_sales,_=lot_stock.allocate(row['lots'],str(request.date),sales,0)
            due=sum(l['units'] for l in after_sales if l['expiry_date']<=str(request.date))
            waste=due if due else min(units-sales,1)
            identifier=f"demo-close:{request.store_id}:{request.date}:{row['product_id']}"
            close_day(CloseDay(request_id=identifier,store_id=request.store_id,product_id=row['product_id'],
                      date=request.date,actual_sales_units=sales,units_wasted=waste,
                      closing_inventory_units=units-sales-waste,out_of_stock_flag=int(units==0),
                      promotion_active=0,is_holiday=0,applied_discount_percent=0))
            with connect(database) as connection:
                connection.execute("UPDATE history SET source='DEMO_SIMULATED_CLOSE' WHERE store_id=? AND product_id=? AND date=?",
                                   (request.store_id,row['product_id'],str(request.date)))
            count+=1
        return {'simulated_products':count,'preserved_products':len(closed),'business_date':str(request.date)}

    @app.post('/api/v1/demo/reset-discount-approvals', dependencies=protected)
    def reset_discount_approvals(request: DemoDay):
        if not is_demo:
            raise HTTPException(404,'Demo only.')
        as_of=store_day(request.store_id)
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            rows=latest_records(connection,request.date,request.store_id,as_of)
            selected=[r for r in rows if r['approval_status']=='APPROVED'
                      and any(a['action']=='DISCOUNT' for a in r['actions'])]
            for row in selected:
                connection.execute("UPDATE recommendations SET approval_status='PROPOSED' WHERE recommendation_id=?",
                                   (row['recommendation_id'],))
                connection.execute('INSERT INTO approval_decisions (recommendation_id,payload,created_at) VALUES (?,?,?)',
                    (row['recommendation_id'],encode({'status':'PROPOSED','reason':'DEMO_DISCOUNT_APPROVAL_RESET'}),now()))
        return {'reset_count':len(selected),'note':'Current discount recommendations reopened; customer offers withdrawn. Other actions on each recommendation share its status.'}

    @app.post('/api/v1/demo/advance', dependencies=protected)
    def advance_demo(request: DemoDay):
        if not is_demo:
            raise HTTPException(404,'Demo only.')
        if automatic_demo:
            raise HTTPException(409,'Demo now follows the Thai calendar automatically; manual future-day advance is disabled.')
        tomorrow=request.date+timedelta(days=1)
        with connect(database) as connection:
            connection.execute('BEGIN IMMEDIATE')
            active=connection.execute('SELECT value FROM demo_settings WHERE key=?',('active_day:'+request.store_id,)).fetchone()
            base=connection.execute("SELECT substr(key,17) FROM demo_settings WHERE key LIKE 'current_fixture_%' ORDER BY key LIMIT 1").fetchone()
            current=Date.fromisoformat(active[0]) if active else (Date.fromisoformat(base[0]) if base else business_clock())
            if current==tomorrow:
                return {'business_date':str(tomorrow),'status':'already_advanced'}
            if current!=request.date:
                raise HTTPException(409,'Refresh the current demo date.')
            stock=snapshots(connection,request.date,request.store_id)
            closed={row[0] for row in connection.execute('SELECT product_id FROM daily_closures WHERE date=? AND store_id=?',
                                                       (str(request.date),request.store_id))}
            next_stock=snapshots(connection,tomorrow,request.store_id)
            if len(stock)!=32 or closed!={row['product_id'] for row in stock} or len(next_stock)!=32:
                raise HTTPException(409,'Close all 32 products before advancing the demo day.')
            connection.execute('INSERT OR REPLACE INTO demo_settings VALUES (?,?)',('active_day:'+request.store_id,str(tomorrow)))
        return {'business_date':str(tomorrow),'status':'advanced'}

    if not is_demo:
        demo_app = create_app(demo_database,artifacts,business_clock=business_clock,is_demo=True,automatic_demo=automatic_demo,authentication=authentication,backup_directory=backup_root)

        @app.post('/api/v1/demo/setup', dependencies=protected)
        def setup_demo():
            result=prepare_deal_demo(demo_database,demo_base_date)
            result['session']=demo_database.name
            result['session_started_date']=demo_base_date
            if automatic_demo:
                try:
                    result['calendar']=demo_app.state.calendar.sync()
                except ValueError as error:
                    raise HTTPException(409,str(error)) from None
                result['business_date']=business_clock().isoformat()
            return result

        app.mount('/demo',demo_app)

    app.state.calendar=DemoCalendar(database,business_clock,store_day,snapshots,
        lambda value:close_day_impl(CloseDay(**value),allow_demo_fixture=True),
        lambda value:receive(Receipt(**value)),lambda value:run(Run(**value)))

    return app


app = create_app()
