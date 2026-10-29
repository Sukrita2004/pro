"""Integration tests use real frozen model files and disposable SQLite databases."""
import json
import os
import shutil
import sqlite3
import tempfile
import unittest
from datetime import date
from pathlib import Path
from contextlib import closing
from unittest.mock import patch

from fastapi.testclient import TestClient
from backend.main import create_app
from backend.seed_demo import seed
from backend.storage import ROOT, connect


class BackendTests(unittest.TestCase):
    def test_operational_readiness_is_scoped_and_explanation_uses_saved_policy(self):
        response = self.client.post('/api/v1/recommendation-runs', json={
            'request_id':'operational-explanation', 'snapshot_date':'2026-10-12',
            'store_id':'STORE_01','holiday':0,'planned_promotion':0})
        response.raise_for_status()
        rows = self.client.get('/api/v1/recommendations', params=self.scope).json()
        for row in rows:
            result = row['result']
            detail = result['replenishment_explanation']
            self.assertEqual(detail['arrival_date'], '2026-10-13')
            self.assertAlmostEqual(result['order_up_to_units'],
                result['predicted_demand_units'] * (detail['lead_time_days'] + detail['review_period_days']) + detail['buffer_units'])
        tomorrow = self.client.get('/api/v1/dashboard/summary', params={**self.scope,'date':'2026-10-13'}).json()
        self.assertEqual(tomorrow['previous_unclosed_product_count'],32)
        self.assertEqual(tomorrow['previous_business_date'],'2026-10-12')
        apple = next(row for row in self.client.get('/api/v1/inventory',params=self.scope).json()
                     if row['product_id']=='PROD_001')
        self.client.post('/api/v1/daily-closures',json={
            'request_id':'operational-close','store_id':'STORE_01','product_id':'PROD_001',
            'date':'2026-10-12','actual_sales_units':0,'units_wasted':0,
            'closing_inventory_units':apple['opening_inventory_units'],
            'out_of_stock_flag':int(apple['opening_inventory_units']==0),
            'promotion_active':0,'is_holiday':0,'applied_discount_percent':0}).raise_for_status()
        tomorrow = self.client.get('/api/v1/dashboard/summary', params={**self.scope,'date':'2026-10-13'}).json()
        self.assertEqual(tomorrow['previous_unclosed_product_count'],31)
        other = self.client.get('/api/v1/dashboard/summary',params={**self.scope,'date':'2026-10-13','store_id':'STORE_02'}).json()
        self.assertEqual(other['previous_unclosed_product_count'],32)

    def test_automatic_thai_calendar_catches_up_all_stores_and_preserves_staff_records(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        manual={'request_id':'calendar-staff-close','store_id':'STORE_01','product_id':'PROD_001',
            'date':'2026-10-12','actual_sales_units':10,'units_wasted':2,'closing_inventory_units':28,
            'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':50}
        self.client.post('/demo/api/v1/daily-closures',json=manual).raise_for_status()
        self.business_date=date(2026,10,13)
        with TestClient(create_app(self.database,business_clock=lambda:self.business_date,automatic_demo=True,authentication=False)) as automatic:
            for number in range(1,5):
                store=f'STORE_0{number}'
                response=automatic.get('/demo/api/v1/demo/day',params={'store_id':store})
                self.assertEqual(response.status_code,200,response.text)
                self.assertEqual(response.json()['business_date'],'2026-10-13')
                self.assertEqual(response.json()['session_started_date'],'2026-10-12')
                self.assertTrue(response.json()['automatic_calendar'])
                stock=automatic.get('/demo/api/v1/inventory',params={'store_id':store,'date':'2026-10-13'}).json()
                self.assertEqual(len(stock),32)
                summary=automatic.get('/demo/api/v1/dashboard/summary',params={'store_id':store,'date':'2026-10-12'}).json()
                self.assertEqual(summary['closed_product_count'],32)
                predictions=automatic.get('/demo/api/v1/recommendations',params={'store_id':store,'date':'2026-10-13'}).json()
                self.assertEqual(len(predictions),32)
                self.assertTrue(all(r['approval_status']=='PROPOSED' for r in predictions))
            demo=self.database.with_name(self.database.stem+'_demo_2026-10-12.db')
            def counts():
                with connect(demo) as connection:
                    return tuple(connection.execute('SELECT COUNT(*) FROM '+name).fetchone()[0] for name in ['daily_closures','receipts','runs'])
            before=counts()
            automatic.get('/demo/api/v1/demo/day',params={'store_id':'STORE_02'}).raise_for_status()
            self.assertEqual(counts(),before)
            self.business_date=date(2026,10,14)
            automatic.get('/demo/api/v1/demo/day',params={'store_id':'STORE_01'}).raise_for_status()
            self.assertEqual(counts()[0],256)
            with connect(demo) as connection:
                saved=json.loads(connection.execute("SELECT payload FROM daily_closures WHERE request_id='calendar-staff-close'").fetchone()[0])
                self.assertEqual(saved,manual)
                generated=connection.execute("SELECT COUNT(*) FROM history WHERE source='DEMO_CALENDAR_SIMULATED_CLOSE'").fetchone()[0]
                self.assertEqual(generated,255)
            self.assertEqual(automatic.post('/demo/api/v1/demo/advance',json={'store_id':'STORE_01','date':'2026-10-14'}).status_code,409)
            self.assertEqual(self.client.get('/api/v1/dashboard/summary',params=self.scope).json()['closed_product_count'],0)

    def test_demo_reset_discount_approval_reopens_queue_and_withdraws_deal(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        self.client.post('/demo/api/v1/recommendation-runs',json={'request_id':'reset-demo',
            'snapshot_date':'2026-10-12','store_id':'STORE_01','holiday':0,'planned_promotion':0}).raise_for_status()
        rows=self.client.get('/demo/api/v1/recommendations',params=self.scope).json()
        apple=next(r for r in rows if r['product_id']=='PROD_001')
        self.client.patch(f"/demo/api/v1/recommendations/{apple['recommendation_id']}/status",json={
            'status':'APPROVED','acknowledge_below_cost':True}).raise_for_status()
        self.assertEqual(len(self.client.get('/demo/api/v1/deals',params=self.scope).json()),1)
        before=self.client.get('/demo/api/v1/inventory',params=self.scope).json()
        request={'store_id':'STORE_01','date':'2026-10-12'}
        self.assertEqual(self.client.post('/api/v1/demo/reset-discount-approvals',json=request).status_code,404)
        wrong=self.client.post('/demo/api/v1/demo/reset-discount-approvals',json={**request,'store_id':'STORE_02'})
        self.assertEqual(wrong.json()['reset_count'],0)
        response=self.client.post('/demo/api/v1/demo/reset-discount-approvals',json=request)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['reset_count'],1)
        self.assertEqual(self.client.get('/demo/api/v1/deals',params=self.scope).json(),[])
        rows=self.client.get('/demo/api/v1/recommendations',params=self.scope).json()
        self.assertEqual(next(r for r in rows if r['product_id']=='PROD_001')['approval_status'],'PROPOSED')
        self.assertEqual(self.client.get('/demo/api/v1/inventory',params=self.scope).json(),before)
        self.assertEqual(self.client.post('/demo/api/v1/demo/reset-discount-approvals',json=request).json()['reset_count'],0)

    def test_below_cost_clearance_requires_explicit_acknowledgement(self):
        self.run_model('clearance-consent').raise_for_status()
        rows=self.client.get('/api/v1/recommendations',params=self.scope).json()
        row=next(r for r in rows if r['result']['below_cost'])
        url=f"/api/v1/recommendations/{row['recommendation_id']}/status"
        response=self.client.patch(url,json={'status':'APPROVED'})
        self.assertEqual(response.status_code,422,response.text)
        self.assertEqual(self.client.patch(url,json={'status':'APPROVED','acknowledge_below_cost':True}).status_code,200)
        with connect(self.database) as connection:
            decision=connection.execute('SELECT payload FROM approval_decisions WHERE recommendation_id=?',(row['recommendation_id'],)).fetchone()
            self.assertTrue(json.loads(decision[0])['acknowledge_below_cost'])

    def test_restart_next_calendar_day_reopens_existing_demo_session(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        request={'request_id':'session-close','store_id':'STORE_01','product_id':'PROD_001','date':'2026-10-12',
            'actual_sales_units':10,'units_wasted':2,'closing_inventory_units':28,
            'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':0}
        self.client.post('/demo/api/v1/daily-closures',json=request).raise_for_status()
        # A different new-session file may already exist; preserve both and reopen the original.
        from backend.storage import initialize
        newer=self.database.with_name(self.database.stem+'_demo_2026-10-13.db')
        initialize(newer)
        with TestClient(create_app(self.database,business_clock=lambda:date(2026,10,13),automatic_demo=False,authentication=False)) as restarted:
            info=restarted.post('/api/v1/demo/setup').json()
            self.assertEqual(info['session_started_date'],'2026-10-12')
            stock=restarted.get('/demo/api/v1/inventory',params={'date':'2026-10-13','store_id':'STORE_01'}).json()
            apples=next(r for r in stock if r['product_id']=='PROD_001')
            self.assertEqual(apples['opening_inventory_units'],28)
            self.assertTrue(newer.exists())

    def test_new_demo_fixture_date_preserves_carried_stock(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        self.client.post('/demo/api/v1/daily-closures',json={'request_id':'seed-carry',
            'store_id':'STORE_01','product_id':'PROD_001','date':'2026-10-12',
            'actual_sales_units':10,'units_wasted':2,'closing_inventory_units':28,
            'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':0}).raise_for_status()
        demo=self.database.with_name(self.database.stem+'_demo_2026-10-12.db')
        from backend.deal_demo import prepare
        prepare(demo,'2026-10-13')
        row=self.client.get('/demo/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json()[0]
        self.assertEqual(row['opening_inventory_units'],28)
        self.assertEqual(sum(l['units'] for l in row['lots']),28)

    def test_fefo_receipt_close_and_arrival_quantity(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        receipt={'request_id':'lot-receipt','store_id':'STORE_01','product_id':'PROD_001',
                 'received_date':'2026-10-12','expiry_date':'2026-10-16','batch_id':'APPLE-NEW',
                 'quantity':5,'cost_price_usd':2.31}
        response=self.client.post('/demo/api/v1/receipts',json=receipt)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(self.client.post('/demo/api/v1/receipts',json=receipt).json()['status'],'already_received')
        self.assertEqual(self.client.post('/demo/api/v1/receipts',json={**receipt,'request_id':'conflict-lot','expiry_date':'2026-10-17'}).status_code,409)
        request={'request_id':'fefo-close','store_id':'STORE_01','product_id':'PROD_001','date':'2026-10-12',
                 'actual_sales_units':10,'units_wasted':2,'closing_inventory_units':33,
                 'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':50}
        self.assertEqual(self.client.post('/demo/api/v1/daily-closures',json=request).status_code,200)
        stock=self.client.get('/demo/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json()[0]
        self.assertEqual(sum(l['units'] for l in stock['lots']),33)
        self.assertEqual(next(l for l in stock['lots'] if l['batch_id']=='APPLE-NEW')['units'],5)
        from backend.inference import ModelService
        from weather import mock_weather
        result=ModelService.recommend(stock,7.49173906288747,mock_weather('2026-10-13'),0)
        self.assertEqual(result['usable_inventory_at_arrival_units'],5)
        self.assertEqual(result['restock_quantity_units'],12)
        self.assertEqual(result['discount_eligible_units'],28)
        self.assertNotIn('APPLE-NEW',result['discount_batch_ids'])

    def test_fefo_rejects_sales_of_expired_units_and_rolls_back(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        request={'request_id':'expired-sale','store_id':'STORE_01','product_id':'PROD_009',
                 'date':'2026-10-12','actual_sales_units':1,'units_wasted':0,'closing_inventory_units':9,
                 'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':0}
        response=self.client.post('/demo/api/v1/daily-closures',json=request)
        self.assertEqual(response.status_code,422,response.text)
        stock=self.client.get('/demo/api/v1/inventory',params=self.scope).json()
        self.assertEqual(next(r for r in stock if r['product_id']=='PROD_009')['opening_inventory_units'],10)
        self.assertEqual(self.client.get('/demo/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json(),[])

    def test_legacy_lots_reconstruct_receipts_and_closing_without_rewriting_history(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        receipt={'request_id':'legacy-receipt','store_id':'STORE_01','product_id':'PROD_001',
                 'received_date':'2026-10-12','expiry_date':'2026-10-14','batch_id':'LEGACY-RECORDED',
                 'quantity':5,'cost_price_usd':2.31}
        self.client.post('/demo/api/v1/receipts',json=receipt).raise_for_status()
        self.client.post('/demo/api/v1/daily-closures',json={'request_id':'legacy-close',
            'store_id':'STORE_01','product_id':'PROD_001','date':'2026-10-12','actual_sales_units':10,
            'units_wasted':2,'closing_inventory_units':33,'out_of_stock_flag':0,'promotion_active':0,
            'is_holiday':0,'applied_discount_percent':50}).raise_for_status()
        demo=self.database.with_name(self.database.stem+'_demo_2026-10-12.db')
        with connect(demo) as connection:
            before=connection.execute("SELECT payload FROM daily_closures WHERE request_id='legacy-close'").fetchone()[0]
            connection.execute('DELETE FROM inventory_lots')
            connection.execute('DELETE FROM lot_snapshots')
        row=self.client.get('/demo/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json()[0]
        self.assertEqual(next(l for l in row['lots'] if l['batch_id']=='LEGACY-RECORDED')['units'],5)
        self.assertEqual(sum(l['units'] for l in row['lots']),33)
        with connect(demo) as connection:
            self.assertEqual(before,connection.execute("SELECT payload FROM daily_closures WHERE request_id='legacy-close'").fetchone()[0])

    def test_demo_day_buttons_preserve_staff_close_and_forecast_tomorrow(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        request={'store_id':'STORE_01','date':'2026-10-12'}
        self.assertEqual(self.client.post('/demo/api/v1/demo/advance',json=request).status_code,409)
        manual={'request_id':'manual-demo-close','store_id':'STORE_01','product_id':'PROD_001',
                'date':'2026-10-12','actual_sales_units':10,'units_wasted':2,
                'closing_inventory_units':28,'out_of_stock_flag':0,'promotion_active':0,
                'is_holiday':0,'applied_discount_percent':50}
        self.assertEqual(self.client.post('/demo/api/v1/daily-closures',json=manual).status_code,200)
        response=self.client.post('/demo/api/v1/demo/close-remaining',json=request)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['simulated_products'],31)
        self.assertEqual(response.json()['preserved_products'],1)
        self.assertEqual(self.client.post('/demo/api/v1/demo/close-remaining',json=request).json()['simulated_products'],0)
        history=self.client.get('/demo/api/v1/history',params={'store_id':'STORE_01','month':'2026-10','record_type':'daily_closures'}).json()['items']
        apples=next(row for row in history if row['product_id']=='PROD_001')
        self.assertEqual(apples['actual_sales_units'],10)
        self.assertEqual(apples['closing_inventory_units'],28)
        response=self.client.post('/demo/api/v1/demo/advance',json=request)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['business_date'],'2026-10-13')
        self.assertEqual(self.client.post('/demo/api/v1/demo/advance',json=request).json()['status'],'already_advanced')
        self.client.post('/api/v1/demo/setup').raise_for_status()
        self.assertEqual(self.client.get('/demo/api/v1/demo/day',params={'store_id':'STORE_01'}).json()['business_date'],'2026-10-13')
        self.assertEqual(self.client.get('/demo/api/v1/demo/day',params={'store_id':'STORE_02'}).json()['business_date'],'2026-10-12')
        result=self.client.post('/demo/api/v1/recommendation-runs',json={'request_id':'next-demo-model',
            'snapshot_date':'2026-10-13','store_id':'STORE_01','holiday':0,'planned_promotion':0,'weather_mode':'mock'})
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(result.json()['count'],32)
        self.assertEqual(self.client.post('/api/v1/demo/advance',json=request).status_code,404)

    def test_complete_store_close_and_next_day_forecast(self):
        """Exercise a whole trading day in disposable stock, not the user's demo."""
        inventory=self.client.get('/api/v1/inventory',params=self.scope).json()
        totals={'sales':0,'waste':0,'closing':0}
        expected={}
        for row in inventory:
            opening=row['opening_inventory_units']
            sales=min(opening,2)
            waste=min(opening-sales,1)
            closing=opening-sales-waste
            request={'request_id':f"whole-day-{row['product_id']}",
                     'store_id':'STORE_01','product_id':row['product_id'],'date':'2026-10-12',
                     'actual_sales_units':sales,'units_wasted':waste,'closing_inventory_units':closing,
                     'out_of_stock_flag':int(closing==0),'promotion_active':0,'is_holiday':0,
                     'applied_discount_percent':0}
            response=self.client.post('/api/v1/daily-closures',json=request)
            self.assertEqual(response.status_code,200,response.text)
            self.assertEqual(response.json()['next_snapshot_date'],'2026-10-13')
            expected[row['product_id']]=closing
            totals['sales']+=sales
            totals['waste']+=waste
            totals['closing']+=closing
        summary=self.client.get('/api/v1/dashboard/summary',params=self.scope).json()
        self.assertTrue(summary['closure_complete'])
        self.assertEqual(summary['closed_product_count'],32)
        self.assertEqual(summary['open_product_count'],0)
        for metric,key in [('sales','recorded_sales_units'),('waste','recorded_waste_units'),('closing','recorded_closing_units')]:
            self.assertEqual(summary[key],totals[metric])
        tomorrow=self.client.get('/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json()
        self.assertEqual(len(tomorrow),32)
        self.assertEqual({row['product_id']:row['opening_inventory_units'] for row in tomorrow},expected)
        self.business_date=date(2026,10,13)
        response=self.run_model('whole-store-next-day',snapshot_date='2026-10-13')
        self.assertEqual(response.status_code,200,response.text)
        predictions=self.client.get('/api/v1/recommendations',params={**self.scope,'date':'2026-10-13'}).json()
        self.assertEqual(len(predictions),32)
        self.assertTrue(all(row['snapshot_date']=='2026-10-13' for row in predictions))
        other=self.client.get('/api/v1/dashboard/summary',params={**self.scope,'store_id':'STORE_02'}).json()
        self.assertEqual(other['closed_product_count'],0)

    def test_dashboard_partial_closure_and_forecast_coverage(self):
        empty=self.client.get('/api/v1/dashboard/summary',params=self.scope).json()
        self.assertIsNone(empty['recorded_sales_units'])
        with connect(self.database) as connection:
            connection.execute("UPDATE snapshots SET opening_inventory_units=45 WHERE store_id='STORE_01' AND product_id='PROD_001'")
            connection.execute("UPDATE inventory_lots SET units=45 WHERE snapshot_id IN (SELECT snapshot_id FROM snapshots WHERE store_id='STORE_01' AND product_id='PROD_001')")
        self.assertEqual(self.run_model('dashboard-before-close').status_code,200)
        request={'request_id':'dashboard-close','store_id':'STORE_01','product_id':'PROD_001',
                 'date':'2026-10-12','actual_sales_units':10,'units_wasted':2,
                 'closing_inventory_units':33,'out_of_stock_flag':0,'promotion_active':0,
                 'is_holiday':0,'applied_discount_percent':50}
        self.assertEqual(self.client.post('/api/v1/daily-closures',json=request).status_code,200)
        summary=self.client.get('/api/v1/dashboard/summary',params=self.scope).json()
        for key,value in {'recorded_sales_units':10,'recorded_waste_units':2,'recorded_closing_units':33,
                          'closed_product_count':1,'open_product_count':31,'valid_forecast_count':31,
                          'missing_open_forecast_count':0,'closure_complete':False}.items():
            self.assertEqual(summary[key],value,key)
        other=self.client.get('/api/v1/dashboard/summary',params={**self.scope,'store_id':'STORE_02'}).json()
        self.assertEqual(other['closed_product_count'],0)
        self.assertIsNone(other['recorded_waste_units'])
        # A new run must not reintroduce closed-product actions into the dashboard.
        self.assertEqual(self.run_model('dashboard-after-close').status_code,200)
        summary=self.client.get('/api/v1/dashboard/summary',params=self.scope).json()
        self.assertEqual(summary['valid_forecast_count'],31)

    def test_late_day_weather_fallback_never_changes_weather_date(self):
        from weather import OpenWeatherClient, WeatherData, WeatherHorizonError
        from datetime import datetime, timezone
        client = OpenWeatherClient(api_key='local-test-only')
        observation = WeatherData('2026-10-28',29,.0,'CLEAR','openweather_current',datetime.now(timezone.utc).isoformat())
        with patch.object(client,'_request',return_value={}), patch.object(client,'parse_forecast',side_effect=WeatherHorizonError('outside dates')), patch.object(client,'current',return_value=observation):
            self.assertEqual(client.forecast(13.7,100.5,'2026-10-28').source,'openweather_current')
            with self.assertRaises(WeatherHorizonError):
                client.forecast(13.7,100.5,'2026-10-29')

    def test_demo_live_weather_uses_api_result_not_mock_scenario(self):
        from weather import WeatherData
        from datetime import datetime, timezone
        self.client.post('/api/v1/demo/setup').raise_for_status()
        request = {'request_id':'live-demo','snapshot_date':self.business_date.isoformat(),
                   'store_id':'STORE_01','holiday':0,'planned_promotion':0,
                   'weather_mode':'live','lat':13.7563,'lon':100.5018,'scenario_id':'rainy'}
        sample = WeatherData(self.business_date.isoformat(),28,.1,'CLEAR','openweather_forecast',datetime.now(timezone.utc).isoformat(),4)
        with patch('backend.inference.OpenWeatherClient') as client:
            client.return_value.forecast.return_value=sample
            response=self.client.post('/demo/api/v1/recommendation-runs',json=request)
            self.assertEqual(response.status_code,200,response.text)
            client.return_value.forecast.assert_called_once_with(13.72383,100.52038,self.business_date.isoformat())
        value=self.client.get('/demo/api/v1/weather-merchandise',params={'store_id':'STORE_01'}).json()
        self.assertFalse(value['rainy'])
        self.assertEqual(value['items'],[])
        self.assertEqual(value['weather']['source'],'openweather_forecast')

    def test_four_demo_stores_and_weather_rules(self):
        self.client.post('/api/v1/demo/setup').raise_for_status()
        for number,scenario,names in [(1,'normal',[]),(2,'hot',['Umbrella']),
                                     (3,'rainy',['Umbrella','Raincoat']),(4,'hot_rainy',['Umbrella','Raincoat'])]:
            store = f'STORE_0{number}'
            response = self.client.post('/demo/api/v1/recommendation-runs',json={
                'request_id':f'four-stores-{store}','snapshot_date':self.business_date.isoformat(),
                'store_id':store,'holiday':0,'planned_promotion':0,'scenario_id':scenario})
            self.assertEqual(response.status_code,200,response.text)
            rows = self.client.get('/demo/api/v1/recommendations',params={'date':self.business_date.isoformat(),'store_id':store}).json()
            self.assertEqual(len(rows),32)
            self.assertTrue(all(row['store_id']==store for row in rows))
            items = self.client.get('/demo/api/v1/weather-merchandise',params={'store_id':store}).json()['items']
            self.assertEqual([item['name'] for item in items],names)
            self.assertTrue(all(item['price_increase_percent']==(30 if 'rainy' in scenario else 0) for item in items))

    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.TemporaryDirectory()
        cls.seed_path = Path(cls.base.name) / 'seed.db'
        seed(cls.seed_path)

    @classmethod
    def tearDownClass(cls):
        cls.base.cleanup()

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.database = Path(self.folder.name) / 'app.db'
        with closing(sqlite3.connect(self.seed_path)) as source, closing(sqlite3.connect(self.database)) as target:
            source.backup(target)
        self.env = patch.dict(os.environ, {'FRESHFLOW_API_KEY':''})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.business_date = date(2026,10,12)
        self.client = TestClient(create_app(self.database,business_clock=lambda:self.business_date,automatic_demo=False,authentication=False))
        self.client.__enter__()
        self.addCleanup(self.client.__exit__,None,None,None)
        self.scope = {'date':'2026-10-12','store_id':'STORE_01'}

    def run_model(self, request_id='test-run', **changes):
        request = {'request_id':request_id,'snapshot_date':'2026-10-12','store_id':'STORE_01',
                   'holiday':0,'planned_promotion':0,'prediction_source':'ML',
                   'rule_version':'generator-aligned-v2','weather_mode':'mock','scenario_id':'normal'}
        request.update(changes)
        return self.client.post('/api/v1/recommendation-runs',json=request)

    def receipt(self, **changes):
        request = {'request_id':'receipt-1','store_id':'STORE_01','product_id':'PROD_001',
            'received_date':'2026-10-12','expiry_date':'2026-10-18','batch_id':'LOT-TEST',
            'quantity':3,'cost_price_usd':2.31}
        request.update(changes)
        return self.client.post('/api/v1/receipts',json=request)

    def test_real_model_and_scopes(self):
        self.assertEqual(len(self.client.get('/api/v1/stores').json()),4)
        self.assertEqual(len(self.client.get('/api/v1/products').json()),32)
        inventory = self.client.get('/api/v1/inventory',params=self.scope).json()
        self.assertEqual(len(inventory),32)
        self.assertEqual({row['store_id'] for row in inventory},{'STORE_01'})
        result = self.run_model()
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(result.json()['prediction_source'],'ML')
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        self.assertEqual(len(rows),32)
        apples = next(row for row in rows if row['product_id']=='PROD_001')
        self.assertAlmostEqual(apples['prediction']['predicted_demand_units'],7.1143179078,places=6)
        self.assertEqual(apples['inventory_source'],'MOCK_INVENTORY_2026_10_12')
        self.assertEqual(apples['result']['weather']['source'],'mock')
        self.assertEqual(len(apples['model_version']),64)
        self.assertEqual(self.run_model().json()['status'],'already_completed')
        self.assertEqual(len(self.client.get('/api/v1/recommendations',params=self.scope).json()),32)
        self.assertEqual(self.run_model(planned_promotion=1).status_code,409)

    def test_receipts_are_idempotent_and_invalidate_stale_recommendations(self):
        self.assertEqual(self.run_model().status_code,200)
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        old = next(row for row in rows if row['product_id']=='PROD_001')
        before = old['input_payload']['snapshot']['opening_inventory_units']
        self.assertEqual(self.receipt().status_code,200)
        self.assertEqual(self.receipt().json()['status'],'already_received')
        self.assertEqual(self.receipt(quantity=4).status_code,409)
        stock = self.client.get('/api/v1/inventory',params=self.scope).json()
        self.assertEqual(next(row for row in stock if row['product_id']=='PROD_001')['opening_inventory_units'],before+3)
        stale = self.client.patch(f"/api/v1/recommendations/{old['recommendation_id']}/status",json={'status':'APPROVED','acknowledge_below_cost':True})
        self.assertEqual(stale.status_code,409)
        self.assertEqual(len(self.client.get('/api/v1/recommendations',params=self.scope).json()),31)

    def test_approval_controls_public_deals_and_latest_run(self):
        self.assertEqual(self.run_model().status_code,200)
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        discounted = next(row for row in rows if row['result']['discount_percent']>0)
        self.assertEqual(self.client.get('/api/v1/deals',params=self.scope).json(),[])
        response = self.client.patch(f"/api/v1/recommendations/{discounted['recommendation_id']}/status",json={'status':'APPROVED','acknowledge_below_cost':True})
        self.assertEqual(response.status_code,200)
        self.assertEqual(len(self.client.get('/api/v1/deals',params=self.scope).json()),1)
        self.assertEqual(self.run_model('second-run').status_code,200)
        self.assertEqual(len(self.client.get('/api/v1/recommendations',params=self.scope).json()),32)
        self.assertEqual(self.client.get('/api/v1/deals',params=self.scope).json(),[])

    def test_missing_history_and_invalid_data_fail_explicitly(self):
        self.assertEqual(self.run_model(snapshot_date='2026-10-13').status_code,422)
        self.assertEqual(self.run_model(prediction_source='MOCK').status_code,422)
        self.assertEqual(self.receipt(quantity=-1).status_code,422)
        self.assertEqual(self.receipt(quantity=1.5).status_code,422)
        self.assertEqual(self.receipt(expiry_date='2026-10-01').status_code,422)
        self.assertEqual(self.receipt(received_date='2026-10-11').status_code,409)

    def test_daily_close_balance_and_persistence(self):
        row = self.client.get('/api/v1/inventory',params=self.scope).json()[0]
        opening = row['opening_inventory_units']
        request = {'request_id':'close-1','store_id':'STORE_01','product_id':row['product_id'],
            'date':'2026-10-12','actual_sales_units':0,'units_wasted':0,
            'closing_inventory_units':opening,'out_of_stock_flag':0,'promotion_active':0,
            'is_holiday':0,'applied_discount_percent':0}
        self.assertEqual(self.client.post('/api/v1/daily-closures',json={**request,'closing_inventory_units':opening+1}).status_code,422)
        response = self.client.post('/api/v1/daily-closures',json=request)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(self.client.post('/api/v1/daily-closures',json=request).json()['status'],'already_closed')
        tomorrow = self.client.get('/api/v1/inventory',params={**self.scope,'date':'2026-10-13'}).json()
        self.assertEqual(tomorrow[0]['opening_inventory_units'],opening)
        with connect(self.database) as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM receipts').fetchone()[0],0)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM daily_closures').fetchone()[0],1)

    def test_cors_allows_only_configured_local_origin(self):
        headers = {'Origin':'http://127.0.0.1:8080','Access-Control-Request-Method':'POST',
                   'Access-Control-Request-Headers':'content-type,x-api-key'}
        response = self.client.options('/api/v1/recommendation-runs',headers=headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.headers['access-control-allow-origin'],headers['Origin'])
        self.assertNotIn('access-control-allow-origin',self.client.get('/health',headers={'Origin':'https://untrusted.example'}).headers)

    def test_pending_inventory_changes_orders_and_key_protects_writes(self):
        self.assertEqual(self.run_model('base').status_code,200)
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        initial = next(row for row in rows if row['product_id']=='PROD_001')['result']['restock_quantity_units']
        with connect(self.database) as connection:
            connection.execute("UPDATE snapshots SET pending_order_units=5, revision=revision+1 WHERE product_id='PROD_001' AND store_id='STORE_01'")
        self.assertEqual(self.run_model('pending').status_code,200)
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        current = next(row for row in rows if row['product_id']=='PROD_001')['result']['restock_quantity_units']
        self.assertEqual(current,max(0,initial-5))
        with patch.dict(os.environ,{'FRESHFLOW_API_KEY':'test-key-only'}):
            self.assertEqual(self.receipt().status_code,401)
            self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope,headers={'X-API-Key':'test-key-only'}).status_code,200)

    def test_expired_stock_never_publishes_even_if_approved_earlier(self):
        with connect(self.database) as connection:
            connection.execute("UPDATE snapshots SET days_to_expiry=1 WHERE product_id='PROD_001' AND store_id='STORE_01'")
        self.assertEqual(self.run_model().status_code,200)
        rows = self.client.get('/api/v1/recommendations',params=self.scope).json()
        row = next(row for row in rows if row['product_id']=='PROD_001')
        self.assertGreater(row['result']['discount_percent'],0)
        endpoint = f"/api/v1/recommendations/{row['recommendation_id']}/status"
        self.assertEqual(self.client.patch(endpoint,json={'status':'APPROVED','acknowledge_below_cost':True}).status_code,200)
        self.assertEqual(len(self.client.get('/api/v1/deals',params=self.scope).json()),1)
        self.business_date = date(2026,10,13)  # expiry day remains valid under daily policy
        self.assertEqual(len(self.client.get('/api/v1/deals',params=self.scope).json()),1)
        self.business_date = date(2026,10,14)
        self.assertEqual(self.client.get('/api/v1/deals',params=self.scope).json(),[])
        expired = next(row for row in self.client.get('/api/v1/recommendations',params=self.scope).json() if row['product_id']=='PROD_001')
        self.assertFalse(expired['sale_eligible_now'])
        self.assertFalse(any(action['action']=='DISCOUNT' for action in expired['actions']))
        self.assertEqual(self.client.patch(endpoint,json={'status':'APPROVED','acknowledge_below_cost':True}).status_code,409)

    def test_isolated_deal_demo_does_not_enable_expired_live_offers(self):
        self.business_date = date(2026,10,28)
        before = self.client.get('/api/v1/inventory',params=self.scope).json()
        self.assertEqual(self.client.post('/api/v1/demo/setup').status_code,200)
        demo_scope = {**self.scope,'date':'2026-10-12'}
        request = {'request_id':'demo-first','snapshot_date':'2026-10-12','store_id':'STORE_01',
                   'holiday':0,'planned_promotion':0,'weather_mode':'mock'}
        response = self.client.post('/demo/api/v1/recommendation-runs',json=request)
        self.assertEqual(response.status_code,200,response.text)
        rows = self.client.get('/demo/api/v1/recommendations',params=demo_scope).json()
        flash = next(row for row in rows if row['product_id']=='PROD_001')
        early = next(row for row in rows if row['product_id']=='PROD_033')
        expired = next(row for row in rows if row['product_id']=='PROD_009')
        self.assertEqual(flash['result']['discount_percent'],50)
        self.assertEqual(early['result']['discount_percent'],20)
        self.assertFalse(expired['sale_eligible_now'])
        self.assertFalse(any(action['action']=='DISCOUNT' for action in expired['actions']))
        self.assertEqual(self.client.patch(f"/demo/api/v1/recommendations/{flash['recommendation_id']}/status",json={'status':'APPROVED','acknowledge_below_cost':True}).status_code,200)
        self.assertEqual(len(self.client.get('/demo/api/v1/deals',params=demo_scope).json()),1)
        self.assertEqual(self.client.get('/api/v1/deals',params=self.scope).json(),[])
        self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope).json(),before)
        # Live weather is now enabled; provider failures remain explicit.
        from backend.inference import WeatherError
        with patch('backend.inference.OpenWeatherClient',side_effect=WeatherError('API unavailable')):
            self.assertEqual(self.client.post('/demo/api/v1/recommendation-runs',json={**request,'request_id':'live-unavailable','weather_mode':'live'}).status_code,502)
        # Reentering demo does not reset prior approvals or receipts.
        self.assertEqual(self.client.post('/api/v1/demo/setup').status_code,200)
        self.assertEqual(len(self.client.get('/demo/api/v1/deals',params=demo_scope).json()),1)
        rain = self.client.post('/demo/api/v1/recommendation-runs',json={**request,'request_id':'rain-merchandise','scenario_id':'rainy'})
        self.assertEqual(rain.status_code,200,rain.text)
        items = self.client.get('/demo/api/v1/weather-merchandise',params={'store_id':'STORE_01'}).json()['items']
        self.assertEqual([item['price_increase_percent'] for item in items],[30,30])
        self.assertEqual([item['adjusted_price_usd'] for item in items],[10.4,6.5])

    def test_monthly_history_sources_pagination_and_original_runs(self):
        app_months = self.client.get('/api/v1/history/months',params={'store_id':'STORE_01'}).json()
        self.assertEqual(app_months,['2026-10','2026-09','2026-08','2026-07'])
        page = self.client.get('/api/v1/history',params={'store_id':'STORE_01','month':'2026-10','limit':10}).json()
        self.assertEqual(page['total'],11*32)
        self.assertEqual(len(page['items']),10)
        self.assertTrue(all(row['store_id']=='STORE_01' for row in page['items']))
        training = self.client.get('/api/v1/history',params={'store_id':'STORE_01','month':'2025-09','source':'training'}).json()
        self.assertEqual(training['total'],7*32)
        self.assertEqual(training['items'][0]['source'],'SYNTHETIC_TRAINING_DATA_2025')
        self.assertEqual(self.client.get('/api/v1/history',params={'store_id':'STORE_01','month':'2026-99'}).status_code,422)
        first = self.run_model('old-run').json()['run_id']
        self.assertEqual(self.run_model('new-run').status_code,200)
        detail = self.client.get(f'/api/v1/history/runs/{first}',params={'store_id':'STORE_01'})
        self.assertEqual(detail.status_code,200)
        self.assertEqual(len(detail.json()['recommendations']),32)
        self.assertEqual(self.client.get(f'/api/v1/history/runs/{first}',params={'store_id':'STORE_02'}).status_code,404)


if __name__ == '__main__':
    unittest.main()
