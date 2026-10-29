"""Validate a relocated team copy without changing its trading database."""
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.verify_demo_accounts_preservation import fingerprints

def main():
    database = ROOT / 'data/application_demo_2026-10-28.db'
    before = fingerprints(database)
    digest = hashlib.sha256(database.read_bytes()).hexdigest()
    with sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True) as connection:
        assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    result = subprocess.run([sys.executable, '-B', '-m', 'unittest',
        'backend.test_accounts', 'backend.test_api', 'backend.test_markdown_policy',
        'backend.test_weather_config', '-q'], cwd=ROOT)
    assert result.returncode == 0, 'Backend checks failed'
    assert fingerprints(database) == before
    assert hashlib.sha256(database.read_bytes()).hexdigest() == digest
    report = {'backend_tests': 'passed', 'included_demo_unchanged': True,
        'business_tables': before,
        'model_sha256': hashlib.sha256((ROOT/'artifacts/model/model.joblib').read_bytes()).hexdigest(),
        'limitation': 'Relocated copy on developer computer; teammate hardware and fresh dependency download remain untested.'}
    (ROOT/'TEAM_VALIDATION.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('Team smoke checks passed; Demo data unchanged.')

if __name__ == '__main__':
    main()
