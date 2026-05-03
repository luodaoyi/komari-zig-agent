# Windows PowerShell installation script for Komari Agent.

$ErrorActionPreference = "Stop"

function Log-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Log-Warning { param([string]$Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Log-Error { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Log-Step { param([string]$Message) Write-Host $Message -ForegroundColor Magenta }
function Log-Config { param([string]$Message) Write-Host "- $Message" -ForegroundColor White }

$Repo = "luodaoyi/komari-zig-agent"
$InstallDir = Join-Path $Env:ProgramFiles "Komari"
$ServiceName = "komari-agent"
$GitHubProxy = ""
$InstallVersion = ""
$KomariArgs = @()
$GitHubProxyList = if ($Env:KOMARI_GITHUB_PROXIES) {
    $Env:KOMARI_GITHUB_PROXIES -split "[,;`\s]+" | Where-Object { $_ }
} else {
    @("https://gh.llkk.cc", "https://gh-proxy.com", "https://ghproxy.net", "https://ghfast.top", "https://ghproxy.cc")
}

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--install-dir" {
            if ($i + 1 -ge $args.Count) { throw "--install-dir requires a value" }
            $InstallDir = $args[$i + 1]; $i++; continue
        }
        "--install-service-name" {
            if ($i + 1 -ge $args.Count) { throw "--install-service-name requires a value" }
            $ServiceName = $args[$i + 1]; $i++; continue
        }
        "--install-ghproxy" {
            if ($i + 1 -ge $args.Count) { throw "--install-ghproxy requires a value" }
            $GitHubProxy = $args[$i + 1].TrimEnd("/"); $i++; continue
        }
        "--install-version" {
            if ($i + 1 -ge $args.Count) { throw "--install-version requires a value" }
            $InstallVersion = $args[$i + 1]; $i++; continue
        }
        { $_ -like "--install*" } {
            Log-Warning "Unknown install parameter: $($args[$i])"
            continue
        }
        default {
            $KomariArgs += $args[$i]
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Log-Error "Please run this script as Administrator."
    exit 1
}

$ProcessorArch = if ($Env:PROCESSOR_ARCHITEW6432) { $Env:PROCESSOR_ARCHITEW6432 } else { $Env:PROCESSOR_ARCHITECTURE }
switch ($ProcessorArch) {
    "AMD64" { $Arch = "amd64" }
    "ARM64" { $Arch = "arm64" }
    "x86" { $Arch = "386" }
    default {
        Log-Error "Unsupported architecture: $ProcessorArch"
        exit 1
    }
}

$AgentPath = Join-Path $InstallDir "komari-agent.exe"
$NssmPath = Join-Path $InstallDir "nssm.exe"
$Asset = "komari-agent-windows-$Arch.exe"
$ReleasePath = if ($InstallVersion) { "download/$InstallVersion" } else { "latest/download" }
$DownloadUrl = "https://github.com/$Repo/releases/$ReleasePath/$Asset"
$ChecksumsUrl = "https://github.com/$Repo/releases/$ReleasePath/SHA256SUMS"

Log-Step "Installation configuration:"
Log-Config "Service name: $ServiceName"
Log-Config "Install directory: $InstallDir"
Log-Config "GitHub proxy: $(if ($GitHubProxy) { $GitHubProxy } else { '(auto fallback)' })"
Log-Config "Agent arguments: $($KomariArgs -join ' ')"
Log-Config "Version: $(if ($InstallVersion) { $InstallVersion } else { 'Latest' })"
Log-Config "Asset: $Asset"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

function Join-ProxyUrl {
    param([string]$Proxy, [string]$Url)
    return "$($Proxy.TrimEnd('/'))/$Url"
}

function Download-File {
    param([string]$Url, [string]$OutFile)
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Log-Warning "Download failed, retry $Attempt/3: $Url"
            if ($Attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Test-Url {
    param([string]$Url)
    try {
        $Started = Get-Date
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 12 | Out-Null
        return ((Get-Date) - $Started).TotalSeconds
    } catch {
        return $null
    }
}

function Select-FastestProxy {
    param([string]$Url)
    $BestProxy = ""
    $BestTime = [double]::MaxValue
    foreach ($Proxy in $GitHubProxyList) {
        $Candidate = Join-ProxyUrl $Proxy $Url
        $Elapsed = Test-Url $Candidate
        if ($null -eq $Elapsed) { continue }
        Log-Info ("Proxy probe: {0} {1:N3}s" -f $Proxy, $Elapsed)
        if ($Elapsed -lt $BestTime) {
            $BestTime = $Elapsed
            $BestProxy = $Proxy
        }
    }
    return $BestProxy
}

function Get-ExpectedSha256 {
    param([string]$SumsPath, [string]$Name)
    foreach ($Line in Get-Content -Path $SumsPath) {
        $Parts = $Line.Trim() -split "\s+"
        if ($Parts.Count -lt 2) { continue }
        $FileName = $Parts[1].TrimStart("*")
        if ($FileName -eq $Name) { return $Parts[0].ToLowerInvariant() }
    }
    return ""
}

function Verify-Sha256 {
    param([string]$FilePath, [string]$SumsPath, [string]$Name)
    $Expected = Get-ExpectedSha256 $SumsPath $Name
    if (-not $Expected) { throw "SHA256SUMS does not contain $Name" }
    $Actual = (Get-FileHash -Algorithm SHA256 -Path $FilePath).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA256 mismatch for $Name" }
}

function Test-AgentBinary {
    param([string]$Path)
    $Proc = Start-Process -FilePath $Path -ArgumentList "--show-warning" -Wait -NoNewWindow -PassThru
    if ($Proc.ExitCode -ne 0) { throw "Downloaded agent failed binary preflight" }
}

function Try-DownloadAgent {
    param([string]$BinaryUrl, [string]$SumsUrl, [string]$SumsFallbackUrl)
    $TempBinary = Join-Path $Env:TEMP "$Asset.$PID.exe"
    $TempSums = Join-Path $Env:TEMP "SHA256SUMS.$PID.tmp"
    Remove-Item $TempBinary, $TempSums -Force -ErrorAction SilentlyContinue
    try {
        Log-Info "Downloading: $BinaryUrl"
        Download-File $BinaryUrl $TempBinary
        try {
            Download-File $SumsUrl $TempSums
        } catch {
            if (-not $SumsFallbackUrl) { throw }
            Download-File $SumsFallbackUrl $TempSums
        }
        Verify-Sha256 $TempBinary $TempSums $Asset
        Test-AgentBinary $TempBinary
        Move-Item -Path $TempBinary -Destination $AgentPath -Force
        return $true
    } catch {
        Log-Warning $_.Exception.Message
        Remove-Item $TempBinary -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Remove-Item $TempSums -Force -ErrorAction SilentlyContinue
    }
}

function Download-AgentWithFallback {
    if ($GitHubProxy) {
        if (Try-DownloadAgent (Join-ProxyUrl $GitHubProxy $DownloadUrl) $ChecksumsUrl (Join-ProxyUrl $GitHubProxy $ChecksumsUrl)) { return }
        throw "Failed to download release asset via explicit GitHub proxy"
    }

    if (Try-DownloadAgent $DownloadUrl $ChecksumsUrl "") { return }
    Log-Warning "Direct GitHub download failed, probing GitHub proxy mirrors"

    $FastestProxy = Select-FastestProxy $DownloadUrl
    if ($FastestProxy) {
        if (Try-DownloadAgent (Join-ProxyUrl $FastestProxy $DownloadUrl) $ChecksumsUrl (Join-ProxyUrl $FastestProxy $ChecksumsUrl)) { return }
        Log-Warning "Fastest proxy failed, trying remaining proxy mirrors"
    }

    foreach ($Proxy in $GitHubProxyList) {
        if ($Proxy -eq $FastestProxy) { continue }
        if (Try-DownloadAgent (Join-ProxyUrl $Proxy $DownloadUrl) $ChecksumsUrl (Join-ProxyUrl $Proxy $ChecksumsUrl)) { return }
    }
    throw "Failed to download release asset"
}

function Install-Nssm {
    $Existing = Get-Command nssm -ErrorAction SilentlyContinue
    if ($Existing) {
        try {
            & $Existing.Source version | Out-Null
            return $Existing.Source
        } catch {
            Log-Warning "nssm in PATH is not usable: $_"
        }
    }

    if (Test-Path $NssmPath) {
        try {
            & $NssmPath version | Out-Null
            return $NssmPath
        } catch {
            Log-Warning "Local nssm is not usable: $_"
        }
    }

    $NssmVersion = "2.24"
    $NssmZipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $TempZip = Join-Path $Env:TEMP "nssm-$NssmVersion.zip"
    $TempDir = Join-Path $Env:TEMP "nssm_extract_$PID"
    try {
        Log-Info "Downloading nssm from $NssmZipUrl"
        Download-File $NssmZipUrl $TempZip
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        Expand-Archive -Path $TempZip -DestinationPath $TempDir -Force
        $SubDir = if ($Arch -eq "amd64") { "win64" } else { "win32" }
        $Source = Join-Path $TempDir "nssm-$NssmVersion\$SubDir\nssm.exe"
        if (-not (Test-Path $Source)) {
            $Source = (Get-ChildItem -Path $TempDir -Recurse -Filter "nssm.exe" | Select-Object -First 1).FullName
        }
        if (-not $Source) { throw "nssm.exe not found after extraction" }
        Copy-Item -Path $Source -Destination $NssmPath -Force
        & $NssmPath version | Out-Null
        return $NssmPath
    } finally {
        Remove-Item $TempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-Previous {
    param([string]$NssmExe)
    Log-Step "Checking for existing service..."
    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($Service) {
        if ($Service.Status -ne "Stopped") {
            try { & $NssmExe stop $ServiceName | Out-Null } catch { Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue }
        }
        try {
            & $NssmExe remove $ServiceName confirm | Out-Null
        } catch {
            sc.exe delete $ServiceName | Out-Null
        }
        Start-Sleep -Seconds 1
    }
    Remove-Item $AgentPath -Force -ErrorAction SilentlyContinue
}

try {
    $NssmExe = Install-Nssm
    Uninstall-Previous $NssmExe
    Download-AgentWithFallback
    Log-Success "Installed binary: $AgentPath"

    Log-Step "Configuring Windows service with nssm..."
    & $NssmExe install $ServiceName $AgentPath @KomariArgs | Out-Null
    & $NssmExe set $ServiceName DisplayName "Komari Agent Service" | Out-Null
    & $NssmExe set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $NssmExe set $ServiceName AppExit Default Restart | Out-Null
    & $NssmExe set $ServiceName AppRestartDelay 5000 | Out-Null
    & $NssmExe start $ServiceName | Out-Null

    Log-Success "Komari Agent installation completed"
    Log-Config "Service name: $ServiceName"
    Log-Config "Arguments: $($KomariArgs -join ' ')"
} catch {
    Log-Error $_.Exception.Message
    exit 1
}
