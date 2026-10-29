# One-time setup on a teammate's Windows machine. Requires internet access.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not (Test-Path -LiteralPath '.venv\Scripts\python.exe')) {
        & py -3.11 -m venv .venv
        if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.11 with the Windows py launcher first.' }
    }
    & .\.venv\Scripts\python.exe -m pip install -r requirements-backend.txt
    if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed.' }
    $flutterExecutable = Join-Path $PSScriptRoot '.tools\flutter\bin\flutter.bat'
    if (-not (Test-Path -LiteralPath $flutterExecutable)) {
        $flutterExecutable = if ($env:FLUTTER_SDK) { Join-Path $env:FLUTTER_SDK 'bin\flutter.bat' } else { '' }
        if (-not $flutterExecutable -or -not (Test-Path -LiteralPath $flutterExecutable)) {
            $command = Get-Command flutter -ErrorAction SilentlyContinue
            if (-not $command) { throw 'Install Flutter and add bin to PATH, or set FLUTTER_SDK, then run setup again.' }
            $flutterExecutable = $command.Source
        }
    }
    Push-Location app
    try {
        & $flutterExecutable pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency installation failed.' }
    } finally { Pop-Location }
    Write-Host 'Setup complete. Open separate terminals for RUN_BACKEND.ps1 and RUN_FLUTTER.ps1.'
} finally { Pop-Location }
