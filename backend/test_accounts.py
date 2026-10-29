"""Authorization and recovery checks use disposable, seeded databases only."""
from contextlib import closing
from datetime import date
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from fastapi.testclient import TestClient
from backend.main import create_app
from backend.storage import connect
from backend.seed_demo import seed
from backend.backups import restore


class AccountTests(unittest.TestCase):
    def test_demo_accounts_preserve_sales_and_isolate_tokens_scopes_and_backups(self):
        from scripts.verify_demo_accounts_preservation import fingerprints
        self.client.post('/api/v1/demo/setup').raise_for_status()
        status=self.client.get('/demo/api/v1/auth/status').json()
        self.assertEqual(status['realm'],'demo')
        demo=self.database.with_name(self.database.stem+'_demo_2026-10-12.db')
        token=Path(str(demo)+'.setup-token').read_text()
        demo_password='Demo-specific-secret-123'
        response=self.client.post('/demo/api/v1/auth/setup',json={'name':'Demo Owner',
            'email':'owner@example.test','password':demo_password,'setup_token':token})
        self.assertEqual(response.status_code,200,response.text)
        demo_admin={'Authorization':'Bearer '+response.json()['access_token']}
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=demo_admin).status_code,401)
        self.assertEqual(self.client.get('/demo/api/v1/auth/me',headers=self.admin).status_code,401)
        self.assertEqual(self.client.get('/demo/api/v1/inventory',params=self.scope).status_code,401)
        self.client.post('/demo/api/v1/receipts',headers=demo_admin,json={
            'request_id':'keep-demo-receipt','store_id':'STORE_01','product_id':'PROD_001',
            'received_date':'2026-10-12','batch_id':'KEEP-DEMO','expiry_date':'2026-10-15',
            'quantity':5,'cost_price_usd':2.31}).raise_for_status()
        self.client.post('/demo/api/v1/daily-closures',headers=demo_admin,json={
            'request_id':'keep-demo-sales','store_id':'STORE_01','product_id':'PROD_001',
            'date':'2026-10-12','actual_sales_units':10,'units_wasted':2,'closing_inventory_units':33,
            'out_of_stock_flag':0,'promotion_active':0,'is_holiday':0,'applied_discount_percent':50}).raise_for_status()
        self.client.get('/demo/api/v1/inventory',params=self.scope,headers=demo_admin).raise_for_status()
        before=fingerprints(demo)
        normal_before=fingerprints(self.database)
        created=self.client.post('/demo/api/v1/auth/users',headers=demo_admin,json={
            'name':'Demo Manager','email':'demo-manager@example.test','password':self.password,
            'role':'manager','stores':['STORE_01']})
        self.assertEqual(created.status_code,200,created.text)
        signed=self.client.post('/demo/api/v1/auth/login',json={'email':'demo-manager@example.test','password':self.password})
        manager={'Authorization':'Bearer '+signed.json()['access_token']}
        self.assertEqual(self.client.get('/demo/api/v1/inventory',params=self.scope,headers=manager).status_code,200)
        self.assertEqual(self.client.get('/demo/api/v1/inventory',params={**self.scope,'store_id':'STORE_02'},headers=manager).status_code,403)
        self.assertEqual(self.client.get('/demo/api/v1/admin/backups',headers=manager).status_code,403)
        staff=self.client.post('/demo/api/v1/auth/users',headers=manager,json={
            'name':'Demo Staff','email':'demo-staff@example.test','password':self.password,
            'role':'staff','stores':['STORE_01']})
        self.assertEqual(staff.status_code,200,staff.text)
        signed=self.client.post('/demo/api/v1/auth/login',json={'email':'demo-staff@example.test','password':self.password})
        staff_headers={'Authorization':'Bearer '+signed.json()['access_token']}
        self.assertEqual(self.client.patch('/demo/api/v1/recommendations/1/status',headers=staff_headers,json={'status':'APPROVED'}).status_code,403)
        self.assertEqual(self.client.post('/demo/api/v1/demo/close-remaining',headers=staff_headers,json={}).status_code,403)
        shopper=self.client.post('/demo/api/v1/auth/register',json={'name':'Demo Customer',
            'email':'demo-shopper@example.test','phone':'0800000000','password':self.password})
        self.assertEqual(shopper.status_code,200,shopper.text)
        customer={'Authorization':'Bearer '+shopper.json()['access_token']}
        changed=self.client.patch('/demo/api/v1/auth/me',headers=customer,json={'name':'Updated Demo Customer','phone':'0811111111'})
        self.assertEqual(changed.json()['phone'],'0811111111')
        self.assertEqual(self.client.get('/demo/api/v1/auth/users',headers=customer).status_code,403)
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=customer).status_code,401)
        backup=self.client.post('/demo/api/v1/admin/backups',headers=demo_admin)
        self.assertEqual(backup.status_code,200,backup.text)
        self.assertEqual([f['scope'] for f in backup.json()['files']],['demo'])
        identifier=backup.json()['backup_id']
        self.assertEqual(self.client.get(f'/demo/api/v1/admin/backups/{identifier}/normal',headers=demo_admin).status_code,409)
        verified=self.client.post(f'/demo/api/v1/admin/backups/{identifier}/verify',headers=demo_admin)
        self.assertEqual(verified.status_code,200,verified.text)
        self.client.post('/api/v1/demo/setup').raise_for_status()
        with TestClient(create_app(self.database,business_clock=lambda:date(2026,10,12),
                automatic_demo=False,backup_directory=self.backup_dir)) as restarted:
            self.assertFalse(restarted.get('/demo/api/v1/auth/status').json()['setup_required'])
            signed=restarted.post('/demo/api/v1/auth/login',json={'email':'owner@example.test','password':demo_password})
            self.assertEqual(signed.status_code,200,signed.text)
        self.assertEqual(fingerprints(demo),before)
        self.assertEqual(fingerprints(self.database),normal_before)
        self.client.post('/demo/api/v1/auth/logout',headers=customer).raise_for_status()
        self.assertEqual(self.client.get('/demo/api/v1/auth/me',headers=customer).status_code,401)

    @classmethod
    def setUpClass(cls):
        cls.base=tempfile.TemporaryDirectory()
        cls.seed=Path(cls.base.name)/'seed.db'
        seed(cls.seed)

    @classmethod
    def tearDownClass(cls): cls.base.cleanup()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database=Path(self.temp.name)/'application.db'
        with closing(sqlite3.connect(self.seed)) as src, closing(sqlite3.connect(self.database)) as dest:
            src.backup(dest)
        self.backup_dir=Path(self.temp.name)/'backups'
        self.app=create_app(self.database,business_clock=lambda:date(2026,10,12),
            automatic_demo=False,backup_directory=self.backup_dir)
        self.client=TestClient(self.app)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__,None,None,None)
        self.scope={'store_id':'STORE_01','date':'2026-10-12'}
        self.password='Example-test-secret-123!'
        self.setup_token=Path(str(self.database)+'.setup-token').read_text()
        response=self.client.post('/api/v1/auth/setup',json={'name':'Owner',
            'email':'owner@example.test','password':self.password,'setup_token':self.setup_token})
        self.assertEqual(response.status_code,200,response.text)
        self.admin={'Authorization':'Bearer '+response.json()['access_token']}

    def employee(self, email, role, stores, actor=None):
        response=self.client.post('/api/v1/auth/users',headers=actor or self.admin,
            json={'name':role,'email':email,'password':self.password,'role':role,'stores':stores})
        self.assertEqual(response.status_code,200,response.text)
        return response.json()

    def login(self,email):
        response=self.client.post('/api/v1/auth/login',json={'email':email,'password':self.password})
        self.assertEqual(response.status_code,200,response.text)
        return {'Authorization':'Bearer '+response.json()['access_token']}

    def test_real_auth_not_bypassed_by_role_or_api_key_and_setup_is_single_use(self):
        self.assertFalse(Path(str(self.database)+'.setup-token').exists())
        self.assertFalse(self.client.get('/api/v1/auth/status').json()['setup_required'])
        for headers in [{},{'X-API-Key':'your_local_admin_key','X-Role':'admin'}, {'Authorization':'Bearer fake'}]:
            self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope,headers=headers).status_code,401)
        self.assertEqual(self.client.post('/api/v1/auth/setup',json={'name':'Intruder','email':'other@example.test',
            'password':self.password,'setup_token':self.setup_token}).status_code,409)
        self.assertEqual(self.client.post('/api/v1/auth/login',json={'email':'owner@example.test','password':'wrong'}).status_code,401)
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=self.admin).json()['role'],'admin')
        with connect(self.database) as db:
            stored=db.execute('SELECT password_hash FROM users').fetchone()[0]
            self.assertNotIn(self.password,stored)
            self.assertTrue(stored.startswith('pbkdf2_sha256$'))
            self.assertNotIn(self.admin['Authorization'][7:],str([tuple(r) for r in db.execute('SELECT * FROM auth_sessions')]))
        self.client.post('/api/v1/auth/logout',headers=self.admin).raise_for_status()
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=self.admin).status_code,401)

    def test_staff_and_manager_branch_scopes_cannot_be_forged(self):
        manager=self.employee('manager@example.test','manager',['STORE_01'])
        manager_headers=self.login(manager['email'])
        staff=self.employee('staff@example.test','staff',['STORE_01'],manager_headers)
        staff_headers=self.login(staff['email'])
        self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope,headers=staff_headers).status_code,200)
        receipt=self.client.post('/api/v1/receipts',headers=staff_headers,json={
            'request_id':'authorized-receipt','store_id':'STORE_01','product_id':'PROD_001',
            'received_date':'2026-10-12','batch_id':'AUTH-TEST','expiry_date':'2026-10-20',
            'quantity':5,'cost_price_usd':2.31})
        self.assertEqual(receipt.status_code,200,receipt.text)
        for headers in [manager_headers,staff_headers]:
            self.assertEqual(self.client.get('/api/v1/inventory',params={**self.scope,'store_id':'STORE_02'},headers=headers).status_code,403)
            self.assertEqual(self.client.post('/api/v1/receipts',headers=headers,json={
                'store_id':'STORE_02','request_id':'denied'}).status_code,403)
            self.assertEqual(self.client.get('/api/v1/admin/backups',headers=headers).status_code,403)
        self.assertEqual(self.client.post('/api/v1/auth/users',headers=manager_headers,json={
            'name':'bad','email':'bad@example.test','password':self.password,'role':'manager','stores':['STORE_01']}).status_code,403)
        self.assertEqual(self.client.post('/api/v1/auth/users',headers=manager_headers,json={
            'name':'bad','email':'bad@example.test','password':self.password,'role':'staff','stores':['STORE_02']}).status_code,403)
        self.assertEqual(self.client.patch('/api/v1/recommendations/1/status',headers=staff_headers,json={'status':'APPROVED'}).status_code,403)
        self.assertEqual(self.client.post('/api/v1/recommendation-runs',headers=staff_headers,json={}).status_code,403)
        run={'request_id':'auth-run','store_id':'STORE_02','snapshot_date':'2026-10-12','holiday':0,'planned_promotion':0}
        self.client.post('/api/v1/recommendation-runs',headers=self.admin,json=run).raise_for_status()
        row=self.client.get('/api/v1/recommendations',params={**self.scope,'store_id':'STORE_02'},headers=self.admin).json()[0]
        self.assertEqual(self.client.patch(f"/api/v1/recommendations/{row['recommendation_id']}/status",
            params={'store_id':'STORE_01'},headers=manager_headers,json={'status':'APPROVED'}).status_code,403)
        self.assertEqual(self.client.get('/api/v1/history/runs/'+str(row['run_id']),
            params={'store_id':'STORE_02'},headers=manager_headers).status_code,403)

    def test_customer_cannot_self_promote_and_public_deals_have_no_private_payload(self):
        request={'name':'Customer','email':'shopper@example.test','password':self.password}
        self.assertEqual(self.client.post('/api/v1/auth/register',json={**request,'role':'admin'}).status_code,422)
        response=self.client.post('/api/v1/auth/register',json=request)
        self.assertEqual(response.status_code,200,response.text)
        headers={'Authorization':'Bearer '+response.json()['access_token']}
        self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope,headers=headers).status_code,403)
        self.assertEqual(self.client.get('/api/v1/auth/users',headers=headers).status_code,403)
        run={'request_id':'public-run','store_id':'STORE_01','snapshot_date':'2026-10-12','holiday':0,'planned_promotion':0}
        self.client.post('/api/v1/recommendation-runs',headers=self.admin,json=run).raise_for_status()
        rows=self.client.get('/api/v1/recommendations',params=self.scope,headers=self.admin).json()
        row=next(r for r in rows if r['sale_eligible_now'] and r['result']['discount_percent'])
        self.client.patch(f"/api/v1/recommendations/{row['recommendation_id']}/status",headers=self.admin,
            json={'status':'APPROVED','acknowledge_below_cost':True}).raise_for_status()
        deals=self.client.get('/api/v1/deals',params=self.scope).json()
        self.assertEqual(len(deals),1)
        self.assertIn('selling_price_usd',deals[0])
        for private in ['input_payload','cost_price_usd','result','model_version','unit_margin']:
            self.assertNotIn(private,json.dumps(deals))

    def test_disabled_reassigned_reset_and_expired_sessions_are_rejected(self):
        employee=self.employee('staff@example.test','staff',['STORE_01'])
        headers=self.login(employee['email'])
        self.client.patch(f"/api/v1/auth/users/{employee['user_id']}",headers=self.admin,json={'stores':['STORE_02']}).raise_for_status()
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=headers).status_code,401)
        headers=self.login(employee['email'])
        self.assertEqual(self.client.get('/api/v1/inventory',params=self.scope,headers=headers).status_code,403)
        self.client.patch(f"/api/v1/auth/users/{employee['user_id']}",headers=self.admin,json={'password':'New-password-example-123'}).raise_for_status()
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=headers).status_code,401)
        self.client.patch(f"/api/v1/auth/users/{employee['user_id']}",headers=self.admin,json={'active':False}).raise_for_status()
        self.assertEqual(self.client.post('/api/v1/auth/login',json={'email':employee['email'],'password':'New-password-example-123'}).status_code,401)
        with connect(self.database) as db: db.execute('UPDATE auth_sessions SET expires_at=0')
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=self.admin).status_code,401)

    def test_password_change_revokes_sessions_and_cors_covers_denials(self):
        origin={'Origin':'http://127.0.0.1:8080'}
        denial=self.client.get('/api/v1/inventory',params=self.scope,headers=origin)
        self.assertEqual(denial.headers.get('access-control-allow-origin'),origin['Origin'])
        preflight=self.client.options('/api/v1/auth/me',headers={**origin,'Access-Control-Request-Method':'GET','Access-Control-Request-Headers':'authorization'})
        self.assertEqual(preflight.status_code,200)
        self.client.post('/api/v1/auth/password',headers=self.admin,json={
            'current_password':self.password,'new_password':'Updated-example-secret-123'}).raise_for_status()
        self.assertEqual(self.client.get('/api/v1/auth/me',headers=self.admin).status_code,401)
        self.assertEqual(self.client.post('/api/v1/auth/login',json={
            'email':'owner@example.test','password':'Updated-example-secret-123'}).status_code,200)

    def test_backup_restore_is_checked_never_overwrites_and_revokes_restored_sessions(self):
        self.assertTrue(self.app.state.backups.daily() is None)
        response=self.client.post('/api/v1/admin/backups',headers=self.admin)
        self.assertEqual(response.status_code,200,response.text)
        record=response.json()
        listing=self.client.get('/api/v1/admin/backups',headers=self.admin).json()
        self.assertTrue(any(row['backup_id']==record['backup_id'] for row in listing['backups']))
        verification=self.client.post('/api/v1/admin/backups/'+record['backup_id']+'/verify',headers=self.admin)
        self.assertEqual(verification.status_code,200,verification.text)
        self.assertFalse(verification.json()['live_data_changed'])
        recovered=Path(self.temp.name)/'recovered.db'
        restore(self.backup_dir,record['backup_id'],'normal',recovered)
        with closing(sqlite3.connect(recovered)) as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            self.assertEqual(db.execute('SELECT COUNT(*) FROM users').fetchone()[0],1)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM auth_sessions').fetchone()[0],0)
        with self.assertRaises(ValueError): restore(self.backup_dir,record['backup_id'],'normal',self.database)
        path=self.app.state.backups.verified_path(record['backup_id'],'normal')
        with path.open('ab') as file: file.write(b'tampered')
        self.assertEqual(self.client.post('/api/v1/admin/backups/'+record['backup_id']+'/verify',headers=self.admin).status_code,409)
        with self.assertRaises(ValueError): self.app.state.backups.verified_path('../outside','normal')

    def test_login_rate_limit_and_security_audit_do_not_store_passwords(self):
        statuses=[]
        for _ in range(11):
            statuses.append(self.client.post('/api/v1/auth/login',json={'email':'nobody@example.test','password':'wrong-password'}).status_code)
        self.assertEqual(statuses[-1],429)
        with connect(self.database) as db:
            audit=' '.join(str(tuple(row)) for row in db.execute('SELECT * FROM security_audit'))
        self.assertIn('LOGIN_FAILED',audit)
        self.assertNotIn(self.password,audit)
        self.assertNotIn('wrong-password',audit)


if __name__=='__main__': unittest.main()
