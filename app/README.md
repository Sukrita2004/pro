# FreshFlow Flutter prototype

Start with [HANDOVER_TH.md](../HANDOVER_TH.md). Run `SETUP_TEAM.ps1` once, then
`RUN_BACKEND.ps1` and `RUN_FLUTTER.ps1` in separate terminals at the project root.

The launcher accepts an installed Flutter SDK on PATH or via FLUTTER_SDK; the
developer's .tools directory is not included in the handover. Dependencies are
recorded in pubspec.yaml and pubspec.lock. Do not upgrade them during initial setup.

Normal and Demo both use account sign-in. A staff member cannot self-select a
manager role or use another branch. Create the first administrator with the local
one-time setup token; see the root guide. Experimental Demo trading data is retained.

Flutter web: http://127.0.0.1:8080 | API: http://127.0.0.1:8000.

```powershell
flutter analyze
flutter test
```
