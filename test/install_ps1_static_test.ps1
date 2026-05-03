$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Script = Join-Path $Root "install.ps1"

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $errors | Format-List * | Out-String | Write-Error
    exit 1
}

$Text = Get-Content -Raw -Path $Script
$Required = @(
    'luodaoyi/komari-zig-agent',
    '--install-dir',
    '--install-service-name',
    '--install-ghproxy',
    '--install-version',
    'komari-agent-windows-$Arch.exe',
    'SHA256SUMS',
    'latest/download',
    'nssm.exe',
    '@KomariArgs'
)

foreach ($Needle in $Required) {
    if (-not $Text.Contains($Needle)) {
        Write-Error "install.ps1 missing required compatibility text: $Needle"
        exit 1
    }
}

Write-Host "install.ps1 static compatibility test passed"
