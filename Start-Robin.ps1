param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$appDir = $PSScriptRoot

# 1. Architecture Check
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error 'This Robin build requires 64-bit Windows 10 or later.'
    exit 1
}

# 2. Executable Verification
$exePath = Join-Path $appDir 'Robin.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    $exePath = Join-Path $appDir 'Release\Robin.exe'
}
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Write-Error 'Robin.exe was not found. Please extract the complete Robin release package or build Release|x64.'
    exit 1
}

$runDir = Split-Path -Parent $exePath

# 3. Core DLL Verification and Automated Fetch for WebView2Loader.dll
$dll1Path = Join-Path $runDir 'Dll1.dll'
if (-not (Test-Path -LiteralPath $dll1Path -PathType Leaf)) {
    Write-Error 'Dll1.dll is missing beside Robin.exe. Please extract the complete package and keep all DLLs beside Robin.exe.'
    exit 1
}

$loaderPath = Join-Path $runDir 'WebView2Loader.dll'
if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
    Write-Host '[Robin Launcher] WebView2Loader.dll is missing. Attempting automatic recovery...' -ForegroundColor Yellow
    try {
        $loaderUrl = 'https://raw.githubusercontent.com/SunnyCOdet/webdll/main/WebView2Loader.dll'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $loaderUrl -OutFile $loaderPath -UseBasicParsing -TimeoutSec 15
        Write-Host '[Robin Launcher] Successfully recovered WebView2Loader.dll.' -ForegroundColor Green
    }
    catch {
        Write-Error @"
WebView2Loader.dll is missing beside Robin.exe and could not be downloaded automatically.
Resolution:
1. Ensure your internet connection is active.
2. Or extract WebView2Loader.dll from the complete Robin release package into:
   $runDir
"@
        exit 1
    }
}

# 4. Supabase Configuration Check
$supabasePath = Join-Path $runDir 'supabase.json'
if (-not (Test-Path -LiteralPath $supabasePath -PathType Leaf)) {
    Write-Error @"
Configuration file 'supabase.json' is missing beside Robin.exe.
Resolution:
Create 'supabase.json' in $runDir containing:
{
  "project_url": "https://<project-ref>.supabase.co",
  "publishable_key": "sb_publishable_..."
}
"@
    exit 1
}

try {
    $supabase = Get-Content -LiteralPath $supabasePath -Raw | ConvertFrom-Json
    if ($supabase.project_url -notmatch '^https://[a-z0-9-]+\.supabase\.co/?$' -or
        $supabase.publishable_key -notmatch '^sb_publishable_[A-Za-z0-9_-]+$') {
        throw 'invalid Supabase configuration'
    }
}
catch {
    Write-Error "supabase.json needs a valid Supabase project URL and publishable key (format: https://<project>.supabase.co and sb_publishable_...)."
    exit 1
}

# 5. Visual C++ Redistributable Verification & Automatic Installer
$vcFiles = @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')
$missingVc = @()
foreach ($name in $vcFiles) {
    $localCopy = Join-Path $runDir $name
    $systemCopy = Join-Path $env:WINDIR "System32\$name"
    if (-not (Test-Path -LiteralPath $localCopy -PathType Leaf) -and
        -not (Test-Path -LiteralPath $systemCopy -PathType Leaf)) {
        $missingVc += $name
    }
}

if ($missingVc.Count -gt 0) {
    Write-Host "[Robin Launcher] Visual C++ Runtime files are missing ($($missingVc -join ', ')). Attempting automatic installation..." -ForegroundColor Yellow
    $vcInstalled = $false
    try {
        $vcUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        $vcInstaller = Join-Path $env:TEMP 'vc_redist.x64.exe'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host '[Robin Launcher] Downloading Visual C++ 2015-2022 Redistributable...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $vcUrl -OutFile $vcInstaller -UseBasicParsing -TimeoutSec 60
        Write-Host '[Robin Launcher] Installing Visual C++ Redistributable...' -ForegroundColor Cyan
        $proc = Start-Process -FilePath $vcInstaller -ArgumentList '/install', '/passive', '/norestart' -Wait -PassThru
        # Re-verify
        $stillMissing = @()
        foreach ($name in $vcFiles) {
            $localCopy = Join-Path $runDir $name
            $systemCopy = Join-Path $env:WINDIR "System32\$name"
            if (-not (Test-Path -LiteralPath $localCopy -PathType Leaf) -and
                -not (Test-Path -LiteralPath $systemCopy -PathType Leaf)) {
                $stillMissing += $name
            }
        }
        if ($stillMissing.Count -eq 0) {
            $vcInstalled = $true
            Write-Host '[Robin Launcher] Visual C++ Redistributable installed successfully.' -ForegroundColor Green
        }
    }
    catch { }

    if (-not $vcInstalled) {
        Write-Error @"
A required Visual C++ runtime component is missing ($($missingVc -join ', ')).
Automatic installation did not complete.
Resolution:
1. Download Microsoft Visual C++ 2015-2022 x64 Redistributable:
   https://aka.ms/vs/17/release/vc_redist.x64.exe
2. Run vc_redist.x64.exe and finish the setup.
3. Restart Robin.
"@
        exit 1
    }
}

# 6. Microsoft Edge WebView2 Runtime Verification & Automatic Installer
function Test-WebView2Ready {
    $webViewClient = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $webViewKeys = @(
        "Registry::HKEY_CURRENT_USER\Software\Microsoft\EdgeUpdate\Clients\$webViewClient",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$webViewClient",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\$webViewClient"
    )
    foreach ($key in $webViewKeys) {
        try {
            $version = (Get-ItemProperty -LiteralPath $key -Name pv -ErrorAction Stop).pv
            if ($version -and $version -ne '0.0.0.0') { return $true }
        }
        catch { }
    }
    return $false
}

if (-not (Test-WebView2Ready)) {
    Write-Host '[Robin Launcher] Microsoft Edge WebView2 Runtime is missing. Attempting automatic installation...' -ForegroundColor Yellow
    $wvInstalled = $false
    try {
        $wvUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
        $wvInstaller = Join-Path $env:TEMP 'MicrosoftEdgeWebview2Setup.exe'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host '[Robin Launcher] Downloading Microsoft Edge WebView2 Evergreen Bootstrapper...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $wvUrl -OutFile $wvInstaller -UseBasicParsing -TimeoutSec 60
        Write-Host '[Robin Launcher] Installing Microsoft Edge WebView2 Runtime silently...' -ForegroundColor Cyan
        $proc = Start-Process -FilePath $wvInstaller -ArgumentList '/silent', '/install' -Wait -PassThru
        if (Test-WebView2Ready) {
            $wvInstalled = $true
            Write-Host '[Robin Launcher] Microsoft Edge WebView2 Runtime installed successfully.' -ForegroundColor Green
        }
    }
    catch { }

    if (-not (Test-WebView2Ready)) {
        Write-Error @"
Microsoft Edge WebView2 Runtime is required for Robin, but automatic installation could not be completed.
Resolution:
1. Download the Microsoft Edge WebView2 Evergreen Bootstrapper from:
   https://developer.microsoft.com/microsoft-edge/webview2/
2. Run MicrosoftEdgeWebview2Setup.exe.
3. Rerun Start-Robin.cmd once the installation finishes.
"@
        exit 1
    }
}

if ($CheckOnly) {
    Write-Host '[Robin Launcher] All Robin dependencies and prerequisites are satisfied.' -ForegroundColor Green
    exit 0
}

# 7. Launch Robin
try {
    Write-Host '[Robin Launcher] Starting Robin...' -ForegroundColor Green
    Start-Process -FilePath $exePath -WorkingDirectory $runDir
}
catch {
    Write-Error "Robin could not start: $($_.Exception.Message)"
    exit 1
}
