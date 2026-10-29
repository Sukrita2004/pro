"""Install the shared synthetic sample once; never replace local Demo records."""
from pathlib import Path
from contextlib import closing
import sqlite3

ROOT = Path(__file__).resolve().parents[1]

def install(root=ROOT):
    root = Path(root)
    sample = root/'data/demo_sample.sqlite3'
    data = root/'data'
    if list(data.glob('application_demo*.db')):
        return 'existing_demo_preserved'
    if not sample.exists():
        return 'no_shared_sample'
    destination = data/'application_demo_2026-10-28.db'
    # Exclusive creation prevents overwriting a concurrently created database.
    with destination.open('xb') as output:
        output.write(sample.read_bytes())
    with closing(sqlite3.connect(destination)) as connection:
        assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    return 'shared_demo_installed'

if __name__ == '__main__':
    print(install())
