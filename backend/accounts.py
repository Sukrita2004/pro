"""Server-side accounts, revocable sessions and branch authorization."""
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from backend.storage import connect, encode

ROUNDS = 600_000
SESSION_SECONDS = 8 * 60 * 60
SCHEMA = '''
CREATE TABLE IF NOT EXISTS users (
 user_id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
 password_hash TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('admin','manager','staff','customer')),
 stores TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, phone TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS auth_sessions (
 token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(user_id), expires_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS auth_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, started REAL NOT NULL);
CREATE TABLE IF NOT EXISTS security_audit (
 id INTEGER PRIMARY KEY, actor_id INTEGER, action TEXT NOT NULL, target TEXT NOT NULL,
 status INTEGER NOT NULL, created_at REAL NOT NULL);
'''


class Credentials(BaseModel):
    model_config = ConfigDict(extra='forbid')
    email: str = Field(min_length=3, max_length=254)
    password: SecretStr = Field(min_length=1, max_length=1024)


class NewAccount(Credentials):
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(default='',max_length=30)


class Profile(BaseModel):
    model_config = ConfigDict(extra='forbid')
    name: str = Field(min_length=1,max_length=120)
    phone: str = Field(default='',max_length=30)


class Setup(NewAccount):
    setup_token: SecretStr


class Employee(NewAccount):
    role: str = 'staff'
    stores: list[str] = Field(min_length=1, max_length=4)


class UpdateAccount(BaseModel):
    model_config = ConfigDict(extra='forbid')
    active: bool | None = None
    stores: list[str] | None = None
    password: SecretStr | None = None


class ChangePassword(BaseModel):
    model_config = ConfigDict(extra='forbid')
    current_password: SecretStr
    new_password: SecretStr


def password_hash(password):
    if not 12 <= len(password) <= 1024:
        raise HTTPException(422, 'Use a password of 12 to 1024 characters.')
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), ROUNDS).hex()
    return f'pbkdf2_sha256${ROUNDS}${salt}${digest}'


def verify_password(password, stored):
    algorithm, rounds, salt, expected = stored.split('$')
    return algorithm == 'pbkdf2_sha256' and hmac.compare_digest(expected,
        hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), int(rounds)).hex())


def public_user(row):
    return {key: row[key] for key in ['user_id','email','name','role','active','phone']} | {'stores': json.loads(row['stores'])}


class Accounts:
    def __init__(self, database, is_demo=False):
        self.database = Path(database)
        self.is_demo = is_demo
        self.setup_file = Path(str(database) + '.setup-token')
        self.dummy = None

    def initialize(self):
        with connect(self.database) as db:
            db.executescript(SCHEMA)
            if 'phone' not in {r[1] for r in db.execute('PRAGMA table_info(users)')}:
                db.execute("ALTER TABLE users ADD COLUMN phone TEXT NOT NULL DEFAULT ''")
            first = not db.execute("SELECT 1 FROM users WHERE role='admin'").fetchone()
        if first:
            try:
                descriptor=os.open(self.setup_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                with os.fdopen(descriptor,'w',encoding='utf-8') as stream:
                    stream.write(secrets.token_urlsafe(32))
            except FileExistsError:
                pass
        self.dummy = password_hash(secrets.token_urlsafe(24))

    def audit(self, actor, action, target, status):
        with connect(self.database) as db:
            db.execute('INSERT INTO security_audit(actor_id,action,target,status,created_at) VALUES (?,?,?,?,?)',
                       (actor, action, target, status, time.time()))

    def limit(self, key, maximum=30):
        key = hashlib.sha256(key.encode()).hexdigest()
        current = time.time()
        with connect(self.database) as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM auth_limits WHERE started<?', (current-900,))
            db.execute('INSERT INTO auth_limits VALUES (?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1', (key,current))
            count = db.execute('SELECT count FROM auth_limits WHERE key=?',(key,)).fetchone()[0]
        if count > maximum:
            raise HTTPException(429, 'Too many attempts. Try again in 15 minutes.')

    def user_for(self, request):
        token = request.headers.get('authorization','')
        if not token.startswith('Bearer ') or len(token) > 256:
            raise HTTPException(401, 'Sign in to your account.')
        digest = hashlib.sha256(token[7:].encode()).hexdigest()
        with connect(self.database) as db:
            row = db.execute('SELECT u.* FROM auth_sessions s JOIN users u USING(user_id) '
                'WHERE token_hash=? AND expires_at>? AND active=1',(digest,time.time())).fetchone()
        if not row:
            raise HTTPException(401, 'Session expired or revoked. Sign in again.')
        return public_user(row)

    def check_store(self, user, store):
        if user['role'] != 'admin' and store not in user['stores']:
            raise HTTPException(403, 'This branch is not assigned to your account.')

    def validate_stores(self, stores):
        with connect(self.database) as db:
            valid = {r[0] for r in db.execute('SELECT store_id FROM stores')}
        if not stores or len(stores) > 4 or len(set(stores)) != len(stores) or not set(stores) <= valid:
            raise HTTPException(422, 'Choose valid, distinct assigned branches.')

    def create(self, request, role, stores):
        email = request.email.strip().lower()
        name = request.name.strip()
        if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email) or not name:
            raise HTTPException(422, 'Enter a name and valid email address.')
        digest = password_hash(request.password.get_secret_value())
        try:
            with connect(self.database) as db:
                db.execute('BEGIN IMMEDIATE')
                if role == 'admin':
                    if db.execute("SELECT 1 FROM users WHERE role='admin'").fetchone():
                        raise HTTPException(409, 'Initial setup has already been completed.')
                    supplied = request.setup_token.get_secret_value()
                    if not self.setup_file.exists() or not hmac.compare_digest(supplied,self.setup_file.read_text().strip()):
                        raise HTTPException(403, 'Invalid local setup token.')
                cursor = db.execute('INSERT INTO users(email,name,password_hash,role,stores,created_at,phone) VALUES (?,?,?,?,?,?,?)',
                    (email,name,digest,role,encode(stores),time.time(),request.phone.strip()))
                row = db.execute('SELECT * FROM users WHERE user_id=?',(cursor.lastrowid,)).fetchone()
        except sqlite3.IntegrityError:
            raise HTTPException(409,'This email is already registered.') from None
        return public_user(row)

    def session(self, user):
        token = secrets.token_urlsafe(32)
        expires = time.time()+SESSION_SECONDS
        with connect(self.database) as db:
            db.execute('DELETE FROM auth_sessions WHERE expires_at<=?',(time.time(),))
            db.execute('INSERT INTO auth_sessions VALUES (?,?,?)',
                (hashlib.sha256(token.encode()).hexdigest(),user['user_id'],expires))
        return {'access_token':token,'token_type':'bearer','expires_at':expires,'user':user}

    def install(self, app):
        @app.middleware('http')
        async def permission_boundary(request: Request, call_next):
            path = request.url.path.rstrip('/')
            root = request.scope.get('root_path','')
            if root and path.startswith(root+'/'):
                path = path[len(root):]
            if request.method == 'OPTIONS' or path.startswith('/demo/') or path == '/demo':
                return await call_next(request)
            public = {'/health','/api/v1/auth/status','/api/v1/auth/setup','/api/v1/auth/login',
                '/api/v1/auth/register','/api/v1/stores','/api/v1/deals','/api/v1/weather-merchandise',
                '/api/v1/demo/setup'}
            if self.is_demo:
                public.add('/api/v1/demo/day')
            user = None
            try:
                if path not in public:
                    user = self.user_for(request)
                    request.state.user = user
                    role = user['role']
                    if path.startswith('/api/v1/auth/'):
                        pass  # Account routes below enforce their own actor/target rules.
                    elif path.startswith('/api/v1/admin/'):
                        if role != 'admin':
                            raise HTTPException(403,'Only the administrator can manage backups and audit records.')
                    elif path in {'/docs','/openapi.json','/redoc'}:
                        if role != 'admin':
                            raise HTTPException(403,'Administrator access required.')
                    else:
                        reads = {'/api/v1/inventory','/api/v1/recommendations','/api/v1/dashboard/summary',
                            '/api/v1/history','/api/v1/history/months','/api/v1/notifications',
                            '/api/v1/data-info','/api/v1/products','/api/v1/weather/current'}
                        if role not in {'admin','manager','staff'}:
                            raise HTTPException(403,'Employee access required.')
                        store = request.query_params.get('store_id')
                        if len(request.query_params.getlist('store_id')) > 1:
                            raise HTTPException(400,'Provide one branch only.')
                        if request.method == 'GET':
                            if path.startswith('/api/v1/history/runs/'):
                                if not store: raise HTTPException(422,'Select a branch.')
                            elif path not in reads:
                                raise HTTPException(403,'Operation not permitted.')
                            if path not in {'/api/v1/data-info','/api/v1/products'} and not store:
                                raise HTTPException(422,'Select a branch.')
                        elif (path in {'/api/v1/receipts','/api/v1/daily-closures','/api/v1/recommendation-runs'} or
                              self.is_demo and path in {'/api/v1/demo/close-remaining','/api/v1/demo/advance','/api/v1/demo/reset-discount-approvals'}) and request.method == 'POST':
                            if (path.endswith('recommendation-runs') or '/demo/' in path) and role == 'staff':
                                raise HTTPException(403,'A manager must run forecasts.')
                            try: store = (await request.json()).get('store_id')
                            except (ValueError,AttributeError): raise HTTPException(422,'Invalid request body.')
                            if not isinstance(store,str): raise HTTPException(422,'Select a branch.')
                        elif request.method == 'PATCH' and re.fullmatch(r'/api/v1/recommendations/\d+/status',path):
                            if role == 'staff': raise HTTPException(403,'Only a manager can approve or reject recommendations.')
                            with connect(self.database) as db:
                                row = db.execute('SELECT store_id FROM recommendations JOIN runs USING(run_id) WHERE recommendation_id=?',
                                                 (int(path.split('/')[-2]),)).fetchone()
                            if not row: raise HTTPException(404,'Recommendation not found.')
                            store = row[0]
                        elif request.method == 'PATCH' and re.fullmatch(r'/api/v1/notifications/rec-\d+/read',path):
                            with connect(self.database) as db:
                                row = db.execute('SELECT store_id FROM recommendations JOIN runs USING(run_id) WHERE recommendation_id=?',
                                    (int(path.split('/')[-2][4:]),)).fetchone()
                            if not row: raise HTTPException(404,'Notification not found.')
                            store = row[0]
                        else:
                            raise HTTPException(403,'Operation not permitted.')
                        if store: self.check_store(user,store)
                response = await call_next(request)
            except HTTPException as error:
                response = JSONResponse({'detail':error.detail},status_code=error.status_code)
            if user and (request.method in {'POST','PATCH','DELETE'} or path.startswith('/api/v1/admin/')):
                self.audit(user['user_id'],request.method,path,response.status_code)
            response.headers['Cache-Control'] = 'no-store'
            response.headers['X-Content-Type-Options'] = 'nosniff'
            return response

        def limited(request, action):
            self.limit(action+'|'+(request.client.host if request.client else 'unknown'))

        @app.get('/api/v1/auth/status')
        def status():
            with connect(self.database) as db:
                needed = not db.execute("SELECT 1 FROM users WHERE role='admin'").fetchone()
            return {'setup_required':needed,'session_hours':8,'realm':'demo' if self.is_demo else 'normal',
                    'setup_token_file':self.setup_file.name if needed else None}

        @app.post('/api/v1/auth/setup')
        def setup(data: Setup, request: Request):
            limited(request,'setup')
            user = self.create(data,'admin',[])
            self.setup_file.unlink(missing_ok=True)
            self.audit(user['user_id'],'INITIAL_SETUP','admin',200)
            return self.session(user)

        @app.post('/api/v1/auth/register')
        def register(data: NewAccount, request: Request):
            limited(request,'register')
            return self.session(self.create(data,'customer',[]))

        @app.post('/api/v1/auth/login')
        def login(data: Credentials, request: Request):
            limited(request,'login')
            email = data.email.strip().lower()
            self.limit('account-login|'+email,10)
            with connect(self.database) as db:
                row = db.execute('SELECT * FROM users WHERE email=?',(email,)).fetchone()
            matched = verify_password(data.password.get_secret_value(),row['password_hash'] if row else self.dummy)
            if not row or not matched or not row['active']:
                self.audit(None,'LOGIN_FAILED','account',401)
                raise HTTPException(401,'Email or password is incorrect, or the account is disabled.')
            self.audit(row['user_id'],'LOGIN','account',200)
            return self.session(public_user(row))

        @app.get('/api/v1/auth/me')
        def me(request: Request):
            return request.state.user

        @app.patch('/api/v1/auth/me')
        def update_profile(data: Profile, request: Request):
            if not data.name.strip(): raise HTTPException(422,'Enter your name.')
            with connect(self.database) as db:
                db.execute('UPDATE users SET name=?,phone=? WHERE user_id=?',
                    (data.name.strip(),data.phone.strip(),request.state.user['user_id']))
                return public_user(db.execute('SELECT * FROM users WHERE user_id=?',
                    (request.state.user['user_id'],)).fetchone())

        @app.post('/api/v1/auth/logout')
        def logout(request: Request):
            digest = hashlib.sha256(request.headers['authorization'][7:].encode()).hexdigest()
            with connect(self.database) as db:
                db.execute('DELETE FROM auth_sessions WHERE token_hash=?',(digest,))
            return {'status':'signed_out'}

        @app.post('/api/v1/auth/password')
        def change_password(data: ChangePassword, request: Request):
            user = request.state.user
            limited(request,'change-password')
            digest = password_hash(data.new_password.get_secret_value())
            with connect(self.database) as db:
                row = db.execute('SELECT password_hash FROM users WHERE user_id=?',(user['user_id'],)).fetchone()
                if not verify_password(data.current_password.get_secret_value(),row[0]):
                    raise HTTPException(401,'Current password is incorrect.')
                db.execute('UPDATE users SET password_hash=? WHERE user_id=?',(digest,user['user_id']))
                db.execute('DELETE FROM auth_sessions WHERE user_id=?',(user['user_id'],))
            return {'status':'password_changed_sign_in_again'}

        @app.get('/api/v1/auth/users')
        def users(request: Request):
            actor = request.state.user
            if actor['role'] not in {'admin','manager'}: raise HTTPException(403,'Manager access required.')
            with connect(self.database) as db:
                records = [public_user(row) for row in db.execute('SELECT * FROM users ORDER BY user_id')]
            return records if actor['role']=='admin' else [u for u in records if u['role']=='staff' and set(u['stores']) <= set(actor['stores'])]

        @app.post('/api/v1/auth/users')
        def create_user(data: Employee, request: Request):
            actor = request.state.user
            if actor['role'] not in {'admin','manager'} or data.role not in {'manager','staff'}:
                raise HTTPException(403,'Only employee accounts can be created here.')
            if actor['role']=='manager' and data.role!='staff': raise HTTPException(403,'Only the administrator can create managers.')
            self.validate_stores(data.stores)
            for store in data.stores: self.check_store(actor,store)
            return self.create(data,data.role,data.stores)

        @app.patch('/api/v1/auth/users/{user_id}')
        def update_user(user_id: int, data: UpdateAccount, request: Request):
            actor = request.state.user
            digest = password_hash(data.password.get_secret_value()) if data.password else None
            with connect(self.database) as db:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT * FROM users WHERE user_id=?',(user_id,)).fetchone()
                if not row: raise HTTPException(404,'Account not found.')
                target = public_user(row)
                if actor['role']!='admin':
                    if actor['role']!='manager' or target['role']!='staff' or not set(target['stores']) <= set(actor['stores']):
                        raise HTTPException(403,'Account is outside your management scope.')
                if target['role']=='admin' and data.active is False:
                    raise HTTPException(409,'The initial administrator cannot be disabled.')
                if data.stores is not None:
                    if target['role'] not in {'manager','staff'}: raise HTTPException(422,'Only employees have branch assignments.')
                    self.validate_stores(data.stores)
                    for store in data.stores: self.check_store(actor,store)
                    db.execute('UPDATE users SET stores=? WHERE user_id=?',(encode(data.stores),user_id))
                if data.active is not None: db.execute('UPDATE users SET active=? WHERE user_id=?',(int(data.active),user_id))
                if digest: db.execute('UPDATE users SET password_hash=? WHERE user_id=?',(digest,user_id))
                db.execute('DELETE FROM auth_sessions WHERE user_id=?',(user_id,))
                return public_user(db.execute('SELECT * FROM users WHERE user_id=?',(user_id,)).fetchone())
