# setup-vps.ps1 — one-time setup of a Windows VPS as a CSV courier. No arguments:
#   1. git clone https://github.com/HassanFaisal2604/VPS-csv-pipeline.git C:\courier
#   2. copy .env.example to .env, set CSV_SERVER (SV1/SV2/...)
#   3. run this in an ADMIN PowerShell:
#        powershell -ExecutionPolicy Bypass -File C:\courier\setup-vps.ps1
# The nightly task does `git pull` before every run, so a fix pushed to the
# courier repo reaches every VPS the next night with no RDP session.
# Idempotent: safe to re-run any time; re-running is also the repair tool.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 0. config comes from .env next to this script — same file the courier reads
if (-not (Test-Path "$here\.env")) {
    Copy-Item "$here\.env.example" "$here\.env"
    Write-Host "Created $here\.env — edit it (set CSV_SERVER), then re-run this script."
    exit 1
}
$cfg = @{}
foreach ($line in (Get-Content "$here\.env")) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
$Server = $cfg['CSV_SERVER']
if (-not $Server) { Write-Error "CSV_SERVER is not set in $here\.env"; exit 1 }

# 1. rsync + git via Chocolatey (installs Chocolatey itself first if missing)
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = 3072  # TLS 1.2
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine")
}
foreach ($pkg in "rsync", "git") {
    if (-not (Get-Command $pkg -ErrorAction SilentlyContinue)) { choco install $pkg -y }
}
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine")
rsync --version | Select-Object -First 1

# 2. SSH key, no passphrase (runs unattended from Task Scheduler)
$key = if ($cfg['CSV_SSH_KEY']) { $cfg['CSV_SSH_KEY'] } else { "$env:USERPROFILE\.ssh\id_ed25519" }
if (-not (Test-Path $key)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $key) | Out-Null
    ssh-keygen -t ed25519 -f $key -N '""' -C "csv-courier-$Server"
}

# 3. nightly task at 23:55 VPS-local time: pull latest courier, then run it.
# StartWhenAvailable = catch up a missed start (e.g. the box was rebooting).
$cmd = "git -C $here pull --quiet; & $here\send-csvs.ps1"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger  = New-ScheduledTaskTrigger -Daily -At 23:55
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName "send-csvs" -Action $action -Trigger $trigger `
    -Settings $settings -User "SYSTEM" -Force | Out-Null

# 4. the one step this script cannot do: authorize the key on the server
$pub = Get-Content "$key.pub"
Write-Host ""
Write-Host "=== $Server set up. ONE manual step left ==="
Write-Host "Append this line to /home/app/.ssh/authorized_keys on the server:"
Write-Host ""
Write-Host "restrict,command=`"rrsync -wo /home/app/incoming`" $pub"
Write-Host ""
Write-Host "Then verify from this box:"
Write-Host "  powershell -Command `"$cmd`""
Write-Host "and check the log (expect 'rsync exit 0')"
