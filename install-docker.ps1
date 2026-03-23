$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "=== Step 1: Enable WSL2 ===" -ForegroundColor Cyan
Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart -ErrorAction SilentlyContinue
Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart -ErrorAction SilentlyContinue
Write-Host "WSL2 features enabled." -ForegroundColor Green

Write-Host "=== Step 2: Download Docker Desktop (~500MB) ===" -ForegroundColor Cyan
$installer = "$env:TEMP\DockerDesktopInstaller.exe"
if (-not (Test-Path $installer)) {
    $url = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    Write-Host "Downloading..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
}
Write-Host "Download complete." -ForegroundColor Green

Write-Host "=== Step 3: Install Docker Desktop ===" -ForegroundColor Cyan
Write-Host "Installing (2-5 minutes)..." -ForegroundColor Gray
Start-Process -FilePath $installer -ArgumentList "install --quiet --accept-license --backend=wsl-2" -Wait
Write-Host "Install complete." -ForegroundColor Green

Write-Host "=== Step 4: Add user to docker-users group ===" -ForegroundColor Cyan
$u = $env:USERNAME
net localgroup docker-users $u /add 2>$null
Write-Host "User $u added to docker-users." -ForegroundColor Green

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Green
Write-Host "Please RESTART your PC, then open Docker Desktop and wait for it to start." -ForegroundColor Yellow
Write-Host ""
$r = Read-Host "Restart now? (y/n)"
if ($r -eq "y") { Restart-Computer -Force }
