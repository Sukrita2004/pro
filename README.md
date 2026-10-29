# FreshFlow

FreshFlow is a Flutter retail inventory prototype with a FastAPI backend and a pre-trained demand forecasting model. It includes branch-based user permissions, batch inventory, replenishment recommendations, discount approval, customer deals, and database backups.

**Start with Demo accounts to explore the prepared example data.** The repository includes synthetic Demo trading records, but no developer accounts, passwords, sessions, or weather API keys.

## 1. Install the tools (Windows)

- Git and Google Chrome.
- Python **3.11** with the Windows `py` launcher.
- Flutter SDK with Dart compatible with `^3.11.1`. Add Flutter's `bin` directory to `PATH`, or set `FLUTTER_SDK` to your SDK folder.
- Windows Developer Mode if Flutter reports that plugins require symlink support: Settings → System → For developers → Developer Mode.

Check your installation:

```powershell
py -3.11 --version
flutter --version
flutter doctor
```

You do not need to train the model or install a mobile app to test in Chrome.

## 2. Clone and set up once

Open PowerShell:

```powershell
git clone https://github.com/Sukrita2004/pro.git
cd pro
powershell -ExecutionPolicy Bypass -File .\SETUP_TEAM.ps1
```

Setup needs an internet connection. It creates `.venv`, installs Python dependencies, and fetches Flutter packages. Run all following commands from the project root, the folder containing `RUN_BACKEND.ps1`.

## 3. Start the application

**Terminal 1 — backend:**

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_BACKEND.ps1
```

**Terminal 2 — Flutter web:**

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_FLUTTER.ps1
```

Keep both terminals open.

| Service | Address |
| --- | --- |
| Application in Chrome | http://127.0.0.1:8080 |
| Backend health check | http://127.0.0.1:8000/health |

The backend launcher installs the shared Demo sample **only if no local Demo database exists**. It then prepares the normal database without overwriting existing records.

For later sessions, repeat only the two start commands. Stop each process with `Ctrl+C`.

## 4. Create your Demo login

There is no shared default password.

1. Start the backend and open the app.
2. Select **Demo accounts → Create initial administrator**.
3. In another PowerShell terminal at the project root, copy the local Demo setup token:

   ```powershell
   Get-Content -LiteralPath .\data\application_demo_2026-10-28.db.setup-token | Set-Clipboard
   ```

4. Enter your name, email, and a password of at least **12 characters**. Paste the token into **Local setup token**, then create the administrator.
5. After this first setup, sign in with your email and password. The setup token is single-use.

If the login screen shows a different database/token filename, use that filename. Do not use the normal-mode token for Demo.

The administrator can create managers and staff with assigned branches through **Account settings**. The backend enforces these assignments. Customer registration creates customer accounts only.

**Normal accounts are separate:** their initial setup uses `data/application.db.setup-token`. Demo credentials do not grant normal-mode access. Normal mode includes synthetic seed inventory/history for the prototype; it is not a connection to an actual store.

## 5. What to try next

Use fictional names and customer details during testing.

1. **Accounts and branches:** create a manager assigned to one branch, sign out, and log in as that manager. Confirm other branches are inaccessible. Create a staff account for that branch.
2. **Inventory:** inspect product quantities and open **Which batch should staff sell first?** to review the batch selling order.
3. **AI Forecast:** select the branch and available date, use mock weather, and run **Run model & recommendations**. Review forecast quantities and the explanations for replenishment.
4. **Discounts:** approve a proposed discount in **Dynamic Pricing**. Check that it leaves the pending queue and appears in customer deals when eligible. Demo provides a reset option for repeating the approval demonstration.
5. **Staff entry:** use **Receive stock** to record an actual simulated delivery with its quantity, batch, expiry, and cost. Use **Close day** to enter simulated sales, waste, and closing stock. Check the result in History and the dashboard.
6. **Customer:** register a Demo customer, view approved offers, save an offer, edit the profile, and sign out.
7. **Backups:** as administrator, use **Back up now** and **Test restore**. Test restore checks a separate copy; it does not overwrite the running database.

Approving a replenishment recommendation does not add inventory. Record the delivery through Receive stock. Saving a customer offer does not reserve stock or process payment.

Demo follows the Thailand calendar while the backend is running and catches up when restarted. Therefore quantities and available offers can change after the sample date. Each computer has its own database; changes are **not synchronized between teammates**.

## 6. Verify your machine

After starting the backend at least once to install the Demo sample, run these checks from the project root:

```powershell
.\.venv\Scripts\python.exe -B scripts\team_smoke.py
```

For Flutter checks:

```powershell
cd app
flutter analyze
flutter test
```

The prepared copy passed 37 backend tests and 32 Flutter tests on the developer computer. This does not replace testing on your own machine. Complete [TEAM_ACCEPTANCE_CHECKLIST.md](TEAM_ACCEPTANCE_CHECKLIST.md), and report the step, expected result, actual result, and a screenshot if something fails. Do not include passwords or setup tokens.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| `py -3.11` cannot find Python | Install Python 3.11 with the launcher, then rerun setup. |
| `flutter` is not recognized | Add the Flutter SDK `bin` folder to PATH, reopen PowerShell, and rerun setup. |
| Plugins require symlink support | Enable Windows Developer Mode, then rerun setup. |
| App cannot connect to API | Keep the backend terminal running and check the health URL above. |
| Port 8000 or 8080 is already used | Stop the previous FreshFlow process in its terminal before starting another. |
| Chrome says `No client connected` or shows a debugger context error | Stop the Flutter command with `Ctrl+C`, rerun `RUN_FLUTTER.ps1`, and use the newly opened Chrome tab. |
| Demo setup token is missing | Start the backend first. If an administrator already exists, log in instead of creating another. |
| Existing Demo has different quantities | Existing records are deliberately preserved. Do not delete the database to reset it; back up first and ask the team before replacing data. |

## Data, weather, and project scope

- The shared sample is `data/demo_sample.sqlite3`. The working Demo database is created separately under `data/` and is ignored by Git.
- Keep `freshflow.db`, `artifacts/model/model.joblib`, and `model_features.joblib`; they are required runtime assets.
- Mock weather works without an API key. For optional live weather, follow [LIVE_WEATHER_DEMO_TH.txt](LIVE_WEATHER_DEMO_TH.txt) or run `SET_WEATHER_KEY.ps1` locally.
- Never commit `.env`, setup tokens, working account databases, or private backups. Backup files are local; keep an additional copy on a separate device for important work.
- This is a research prototype using synthetic data. Model evaluation uses MAE, RMSE, and WMAPE; it does not establish real-store profit gains or waste reduction. POS integration, payment processing, public server deployment, and iOS distribution are outside this local Chrome setup.

## Further instructions

- [Detailed team handover (Thai)](HANDOVER_TH.md)
- [Demo accounts and demonstration flow (Thai)](DEMO_ACCOUNTS_TH.md)
- [Accounts, permissions, and backups (Thai)](ACCOUNTS_BACKUP_TH.md)
- [Teammate acceptance checklist](TEAM_ACCEPTANCE_CHECKLIST.md)

Research reports and archived experiments are stored separately on the developer's Desktop and are not part of this repository.
