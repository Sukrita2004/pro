"""Prepare an allowlisted handover; sanitize authentication only in its DB copy."""
from pathlib import Path
import hashlib
import json
import shutil
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.backups import snapshot
from scripts.verify_demo_accounts_preservation import fingerprints

RUNTIME = {'predict_next_day.py', 'train_demand_model.py', 'improve_features.py',
    'recommendation_engine.py', 'generator_aligned_engine.py', 'weather.py',
    'verify_demo_accounts_preservation.py', 'team_smoke.py', 'build_team_package.py'}

def main():
    target = ROOT/'.handover_stage/FreshFlow_Team_2026-10-30'
    if target.exists():
        raise SystemExit('Stage already exists; preserve it and inspect before rebuilding.')
    target.mkdir(parents=True)
    ignore = shutil.ignore_patterns('build', '.dart_tool', '__pycache__', '.git',
        '.gradle', '.idea', 'ephemeral', '*.iml', 'local.properties', '*.keystore', '*.jks',
        'key.properties', '.flutter-plugins*', 'legacy_web', '.env', '*.setup-token')
    for directory in ['app', 'backend']:
        shutil.copytree(ROOT/directory, target/directory, ignore=ignore)
    for filename in RUNTIME:
        (target/'scripts').mkdir(exist_ok=True)
        shutil.copy2(ROOT/'scripts'/filename, target/'scripts'/filename)
    for pattern in ['*.md', '*.ps1', '*_TH.txt', 'requirements-backend.txt', '.env.example', '.gitignore']:
        for path in ROOT.glob(pattern):
            if path.name != 'RUN_SCRIPTS_TH.txt':
                shutil.copy2(path, target/path.name)
    for relative in ['freshflow.db', 'data/inventory_mock_2026-10-12.csv',
                     'data/inventory_mock_2026-10-12.metadata.json',
                     'artifacts/model/model.joblib', 'artifacts/model/model_features.joblib',
                     'artifacts/model/model_results.json']:
        destination = target/relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/relative, destination)
    shutil.copytree(ROOT/'data/cutoff_test', target/'data/cutoff_test')
    demo = target/'data/application_demo_2026-10-28.db'
    snapshot(ROOT/'data/application_demo_2026-10-28.db', demo)
    before = fingerprints(demo)
    with sqlite3.connect(demo) as connection:
        for table in ['auth_sessions', 'auth_limits', 'security_audit', 'users']:
            connection.execute('DELETE FROM '+table)
        connection.commit()
        connection.execute('VACUUM')
    assert fingerprints(demo) == before, 'Trading data changed during sanitization'
    (target/'TEAM_DATA_PRESERVATION.json').write_text(json.dumps({
        'trading_data_preserved': True, 'authentication_removed_from_copy_only': True,
        'business_tables': before}, indent=2), encoding='utf-8')
    print(str(target))

if __name__ == '__main__':
    main()
