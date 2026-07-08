# setup-vps.ps1 - one-time setup of a Windows VPS as a CSV courier. No arguments:
#   1. git clone https://github.com/HassanFaisal2604/VPS-csv-pipeline.git C:\courier
#   2. copy .env.example to .env, set CSV_SERVER (SV1/SV2/...)
#   3. run this in an ADMIN PowerShell:
#        powershell -ExecutionPolicy Bypass -File C:\courier\setup-vps.ps1
# The nightly task does `git pull` before every run, so a fix pushed to the
# courier repo reaches every VPS the next night with no RDP session.
# Idempotent: safe to re-run any time; re-running is also the repair tool.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 0. config comes from .env next to this script - same file the courier reads
if (-not (Test-Path "$here\.env")) {
    Copy-Item "$here\.env.example" "$here\.env"
    Write-Host "Created $here\.env - edit it (set CSV_SERVER), then re-run this script."
    exit 1
}
$cfg = @{}
foreach ($line in (Get-Content "$here\.env")) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
$Server = $cfg['CSV_SERVER']
if (-not $Server) { Write-Error "CSV_SERVER is not set in $here\.env"; exit 1 }

# 1. rsync + git via Chocolatey (installs Chocolatey itself first if missing).
# choco is addressed by FULL PATH throughout - a stale PATH can't break this.
$chocoExe = "C:\ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    if (Test-Path "C:\ProgramData\chocolatey") {
        Write-Error ("Broken Chocolatey install: C:\ProgramData\chocolatey exists but choco.exe is missing. " +
                     "Delete that folder (backup first if unsure) and re-run this script.")
        exit 1
    }
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = 3072  # TLS 1.2
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
foreach ($pkg in "rsync", "git") {
    if (-not (Get-Command $pkg -ErrorAction SilentlyContinue)) { & $chocoExe install $pkg -y }
}
# fresh installs land in Machine PATH; make them visible to THIS session too
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
rsync --version | Select-Object -First 1

# 2. SSH key, no passphrase (runs unattended from Task Scheduler).
# The task runs as SYSTEM, so the key MUST live in a machine location SYSTEM
# owns - ssh rejects a key it doesn't own ("bad ownership or modes"), so a key
# in a user profile (the old default) silently fails only under the SYSTEM task.
# Default to C:\ProgramData\csv-courier, owned by SYSTEM, no other access.
$key = if ($cfg['CSV_SSH_KEY']) { $cfg['CSV_SSH_KEY'] } else { "C:\ProgramData\csv-courier\csv-courier_ed25519" }
if (-not (Test-Path $key)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $key) | Out-Null
    ssh-keygen -t ed25519 -f $key -N '""' -C "csv-courier-$Server"
    # Well-known SIDs, not names, so this holds on non-English Windows:
    # S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators.
    icacls $key /setowner "*S-1-5-18" | Out-Null
    icacls $key /inheritance:r /grant:r "*S-1-5-18:R" "*S-1-5-32-544:R" | Out-Null
}
# Pin the absolute key path into .env so the SYSTEM task reads it (its
# $env:USERPROFILE is systemprofile, not the admin's profile).
if (-not $cfg['CSV_SSH_KEY']) {
    Add-Content "$here\.env" ("CSV_SSH_KEY=" + (((Resolve-Path $key).Path) -replace '\\', '/'))
}

# 3. nightly task at 23:55 VPS-local time: pull latest courier (best-effort),
# then run it. StartWhenAvailable = catch up a missed start (box rebooting).
# git is resolved to its full path NOW (setup has it on PATH) and baked into the
# task, so the SYSTEM task never depends on git being on the machine PATH; the
# pull is wrapped in try/catch so a missing or failed self-update can NEVER block
# the nightly send. If git can't be found at all, the pull is simply skipped.
$git  = (Get-Command git -ErrorAction SilentlyContinue).Source
$pull = if ($git) { "try { & '$git' -C '$here' pull --quiet } catch {} ; " } else { "" }
$cmd  = "$pull& '$here\send-csvs.ps1'"
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
