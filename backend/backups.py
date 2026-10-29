"""Consistent SQLite backups and offline, verified restore (never live overwrite)."""
import argparse
from contextlib import closing
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import tempfile

from fastapi import HTTPException
from fastapi.responses import FileResponse
from backend.storage import ROOT


def snapshot(source, destination):
    with closing(sqlite3.connect(Path(source).resolve().as_uri()+'?mode=ro',uri=True)) as src:
        with closing(sqlite3.connect(destination)) as dest:
            src.backup(dest)
            if dest.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('Backup integrity check failed.')
            required = {'stores','products','snapshots','history'}
            tables = {r[0] for r in dest.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not required <= tables: raise ValueError('Not a FreshFlow application database.')
    return hashlib.sha256(Path(destination).read_bytes()).hexdigest()


class Backups:
    def __init__(self, database, demo_database, directory=None, demo_only=False):
        self.sources = {'demo':Path(database)} if demo_only else {'normal':Path(database),'demo':Path(demo_database)}
        self.directory = Path(directory or os.environ.get('FRESHFLOW_BACKUP_DIR') or ROOT/'backups')
        self.lock = threading.RLock()
        self.error = None

    def records(self):
        self.directory.mkdir(parents=True,exist_ok=True)
        rows=[]
        for path in sorted(self.directory.glob('*.json'),reverse=True):
            try:
                row=json.loads(path.read_text(encoding='utf-8'))
                if re.fullmatch(r'\d{8}T\d{12}Z-[a-f0-9]{8}',row['backup_id']): rows.append(row)
            except (ValueError,KeyError):
                continue
        return rows

    def create(self, reason='manual'):
        with self.lock:
            self.directory.mkdir(parents=True,exist_ok=True)
            stamp=datetime.now(timezone.utc)
            identifier=stamp.strftime('%Y%m%dT%H%M%S%fZ')+'-'+secrets.token_hex(4)
            created=[]
            try:
                for scope,source in self.sources.items():
                    if not source.exists(): continue
                    path=self.directory/(identifier+'-'+scope+'.sqlite3')
                    digest=snapshot(source,path)
                    created.append({'scope':scope,'filename':path.name,'sha256':digest,'bytes':path.stat().st_size})
                if not created: raise ValueError('No application databases to back up.')
                record={'backup_id':identifier,'created_at':stamp.isoformat(),
                    'bangkok_date':stamp.astimezone(timezone(timedelta(hours=7))).date().isoformat(),
                    'reason':reason,'files':created,'integrity':'ok',
                    'note':'Each database is consistent independently; normal and demo are isolated.'}
                manifest=self.directory/(identifier+'.json')
                temporary=manifest.with_suffix('.tmp')
                temporary.write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
                os.replace(temporary,manifest)
                self.error=None
                return record
            except Exception as error:
                self.error=str(error)
                raise

    def daily(self):
        day=datetime.now(timezone(timedelta(hours=7))).date().isoformat()
        with self.lock:
            if not any(r['bangkok_date']==day and r['reason']=='automatic' for r in self.records()):
                self.create('automatic')

    def verified_path(self, identifier, scope):
        if not re.fullmatch(r'\d{8}T\d{12}Z-[a-f0-9]{8}',identifier) or scope not in self.sources:
            raise ValueError('Invalid backup selection.')
        record=json.loads((self.directory/(identifier+'.json')).read_text(encoding='utf-8'))
        entry=next(f for f in record['files'] if f['scope']==scope)
        expected=identifier+'-'+scope+'.sqlite3'
        if entry['filename']!=expected: raise ValueError('Invalid manifest filename.')
        path=self.directory/expected
        if hashlib.sha256(path.read_bytes()).hexdigest()!=entry['sha256']:
            raise ValueError('Backup checksum does not match.')
        return path

    def install(self, app):
        @app.get('/api/v1/admin/backups')
        def list_backups():
            return {'backups':self.records(),'last_error':self.error,
                'schedule':'Once per Bangkok calendar day while the backend is running; catch up on startup.',
                'retention':'No automatic deletion. Administrator manages disk space.'}

        @app.post('/api/v1/admin/backups')
        def create_backup():
            try: return self.create()
            except Exception:
                raise HTTPException(503,'Backup failed. Check server storage and retry.') from None

        @app.get('/api/v1/admin/backups/{identifier}/{scope}')
        def download_backup(identifier: str, scope: str):
            try: path=self.verified_path(identifier,scope)
            except (ValueError,KeyError,StopIteration,FileNotFoundError):
                raise HTTPException(409,'Backup missing or checksum invalid.') from None
            return FileResponse(path,filename=path.name,media_type='application/octet-stream')

        @app.post('/api/v1/admin/backups/{identifier}/verify')
        def verify_restore(identifier: str):
            try:
                record=next(r for r in self.records() if r['backup_id']==identifier)
                scopes=[]
                with tempfile.TemporaryDirectory(prefix='restore-check-',dir=self.directory) as temporary:
                    for entry in record['files']:
                        restore(self.directory,identifier,entry['scope'],Path(temporary)/(entry['scope']+'.db'))
                        scopes.append(entry['scope'])
                return {'status':'restore_verified','scopes':scopes,'live_data_changed':False}
            except (ValueError,KeyError,StopIteration,FileNotFoundError,sqlite3.Error):
                raise HTTPException(409,'Restore verification failed. Do not use this backup.') from None


def restore(backup_directory, identifier, scope, destination):
    """Writes a NEW recovery file only. Caller stops server before switching DBs."""
    destination=Path(destination).resolve()
    if destination.exists() or Path(str(destination)+'-wal').exists():
        raise ValueError('Restore requires a new destination; existing databases are never overwritten.')
    manager=Backups(destination,destination,backup_directory)
    source=manager.verified_path(identifier,scope)
    destination.parent.mkdir(parents=True,exist_ok=True)
    # Exclusive creation also prevents concurrent restore from overwriting a new file.
    with destination.open('xb'): pass
    try:
        snapshot(source,destination)
        with closing(sqlite3.connect(destination)) as db:
            if db.execute("SELECT 1 FROM sqlite_master WHERE name='auth_sessions'").fetchone():
                db.execute('DELETE FROM auth_sessions')
            db.commit()
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    return destination


if __name__=='__main__':
    parser=argparse.ArgumentParser(description='Restore a verified backup to a new file. Stop the backend before switching database paths.')
    parser.add_argument('--backup-dir',type=Path,default=ROOT/'backups')
    parser.add_argument('--id',required=True)
    parser.add_argument('--scope',choices=['normal','demo'],required=True)
    parser.add_argument('--destination',type=Path,required=True)
    args=parser.parse_args()
    print(restore(args.backup_dir,args.id,args.scope,args.destination))
