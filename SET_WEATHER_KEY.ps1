# Store the key locally without displaying it or changing other .env settings.
$ErrorActionPreference = 'Stop'
$secret = Read-Host 'Paste your OpenWeather API key, then press Enter' -AsSecureString
$plain = [System.Net.NetworkCredential]::new('', $secret).Password.Trim()
try {
    if ([string]::IsNullOrWhiteSpace($plain) -or $plain -match '[\r\n]') {
        throw 'No valid key entered. Nothing was saved.'
    }
    $path = Join-Path $PSScriptRoot '.env'
    $lines = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllLines($path) } else { @() }
    $retained = @($lines | Where-Object { $_ -notmatch '^\s*OPENWEATHER_API_KEY\s*=' })
    $retained += 'OPENWEATHER_API_KEY=' + $plain
    [System.IO.File]::WriteAllLines($path, $retained, [System.Text.UTF8Encoding]::new($false))
    Write-Output 'Key saved locally. Use OpenWeather live in the app. No key was printed.'
} finally {
    Remove-Variable secret, plain -ErrorAction SilentlyContinue
}
