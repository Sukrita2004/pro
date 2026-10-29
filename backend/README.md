# FreshFlow Backend

Current setup and account workflow: [HANDOVER_TH.md](../HANDOVER_TH.md).

Python 3.11; install `requirements-backend.txt`, then run `RUN_BACKEND.ps1`.
The frozen model is loaded for inference, never trained by an API call.

Normal and Demo have separate account/session stores. Both enforce roles and
assigned branches in the backend. Only valid approved, unexpired deals are public.
The frontend uses loopback port 8080 and the API uses port 8000.

Keep `freshflow.db`, `data/cutoff_test/`, the mock inventory fixture, the runtime
scripts and `artifacts/model/` together. `freshflow.db` is synthetic reference
data, not the operational account database. Never overwrite operational databases
with training data. The included Demo is a sanitized copy with trading data kept.

Backups use SQLite backup, integrity checks and checksums. Demo administrators
can manage only Demo backup files. Test restore writes temporary copies; offline
restore writes a new file. See [ACCOUNTS_BACKUP_TH.md](../ACCOUNTS_BACKUP_TH.md).

Tests:

```powershell
.\.venv\Scripts\python.exe -B -m unittest backend.test_accounts backend.test_api backend.test_markdown_policy backend.test_weather_config -q
```

Research metrics describe synthetic-data evaluation, not measured supermarket
waste reduction, financial improvement or real-store accuracy.
