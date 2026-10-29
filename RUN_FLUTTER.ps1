# Use the local SDK, FLUTTER_SDK, or the SDK installed on the teammate's PATH.
$ErrorActionPreference = 'Stop'
$flutterExecutable = Join-Path $PSScriptRoot '.tools\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterExecutable)) {
    $flutterExecutable = if ($env:FLUTTER_SDK) { Join-Path $env:FLUTTER_SDK 'bin\flutter.bat' } else { '' }
    if (-not $flutterExecutable -or -not (Test-Path -LiteralPath $flutterExecutable)) {
        $command = Get-Command flutter -ErrorAction SilentlyContinue
        if (-not $command) { throw 'Install Flutter and add its bin directory to PATH, or set FLUTTER_SDK. See HANDOVER_TH.md.' }
        $flutterExecutable = $command.Source
    }
}
Push-Location (Join-Path $PSScriptRoot 'app')
try {
    & $flutterExecutable run -d chrome --web-hostname 127.0.0.1 --web-port 8080
    if ($LASTEXITCODE -ne 0) { throw 'Flutter stopped with an error.' }
} finally { Pop-Location }
