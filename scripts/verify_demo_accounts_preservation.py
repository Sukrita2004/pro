"""Capture/check business-table fingerprints without exposing records or credentials."""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from backend.backups import Backups

TABLES=['products','stores','history','snapshots','receipts','daily_closures',
        'runs','recommendations','approval_decisions','inventory_lots','closure_lot_allocations']

def fingerprints(database):
    result={}
    with closing(sqlite3.connect(database.resolve().as_uri()+'?mode=ro',uri=True)) as db:
        db.execute('BEGIN')
        existing={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        for table in TABLES:
            if table not in existing: continue
            rows=sorted(json.dumps(list(row),ensure_ascii=False,separators=(',',':'))
                        for row in db.execute('SELECT * FROM '+table))
            result[table]={'rows':len(rows),'sha256':hashlib.sha256('\n'.join(rows).encode()).hexdigest()}
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['capture','check'])
    parser.add_argument('--database',type=Path,required=True)
    args=parser.parse_args()
    report=ROOT/'reports/demo_accounts_data_preservation.json'
    if args.action=='capture':
        if report.exists(): raise SystemExit('Existing baseline is preserved; do not overwrite it.')
        backup=Backups(args.database,args.database,ROOT/'backups/pre_demo_accounts',demo_only=True).create('before_demo_accounts')
        record={'database':args.database.name,'backup_id':backup['backup_id'],
                'before':fingerprints(args.database),'verified':False}
    else:
        record=json.loads(report.read_text(encoding='utf-8'))
        if record['database']!=args.database.name: raise SystemExit('Wrong database selected.')
        record['after']=fingerprints(args.database)
        record['verified']=record['before']==record['after']
    report.write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'action':args.action,'database':record['database'],
        'verified':record['verified'],'table_counts':{k:v['rows'] for k,v in record.get('after',record['before']).items()}}))
    if args.action=='check' and not record['verified']: raise SystemExit(1)
