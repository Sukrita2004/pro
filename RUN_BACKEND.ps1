# Start from any directory. Existing application/demo data is never reset.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $pythonExecutable = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    $pythonArguments = @()
    if (-not (Test-Path -LiteralPath $pythonExecutable)) {
        $launcher = Get-Command py -ErrorAction SilentlyContinue
        if (-not $launcher) { throw 'Install Python 3.11 and run SETUP_TEAM.ps1 first.' }
        $pythonExecutable = $launcher.Source
        $pythonArguments = @('-3.11')
    }
    & $pythonExecutable @pythonArguments -B -m backend.seed_demo
    if ($LASTEXITCODE -ne 0) { throw 'Database preparation failed. See HANDOVER_TH.md.' }
    & $pythonExecutable @pythonArguments -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
    if ($LASTEXITCODE -ne 0) { throw 'Backend stopped with an error.' }
} finally { Pop-Location }
