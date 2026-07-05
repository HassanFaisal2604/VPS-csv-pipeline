# setup-vps.ps1 — one-time setup of a Windows VPS as a CSV courier.
# Run in an ADMIN PowerShell:
#   powershell -ExecutionPolicy Bypass -File setup-vps.ps1 -Server SV1
# The nightly task does `git pull` before every run, so a fix pushed to the
# courier repo reaches every VPS the next night with no RDP session.
# -Pat is only needed if the courier repo is made private (fine-grained PAT,
# read-only Contents, scoped to that repo alone).
# Idempotent: safe to re-run any time; re-running is also the repair tool.
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$Pat = "",
    [string]$Repo = "HassanFaisal2604/VPS-csv-pipeline"   # the dedicated courier repo
)

$ErrorActionPreference = "Stop"
$RepoUrl = if ($Pat) { "https://x-access-token:$Pat@github.com/$Repo.git" }
           else      { "https://github.com/$Repo.git" }
$Clone   = "C:\courier"

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

# 2. shallow clone of the courier repo (it contains nothing but these scripts)
if (-not (Test-Path "$Clone\.git")) {
    git clone --depth 1 $RepoUrl $Clone
} else {
    git -C $Clone remote set-url origin $RepoUrl   # refresh PAT on re-run
    git -C $Clone pull --quiet
}

# 3. SSH key, no passphrase (runs unattended from Task Scheduler)
$sshDir = "$env:USERPROFILE\.ssh"
$key = "$sshDir\id_ed25519"
if (-not (Test-Path $key)) {
    New-Item -ItemType Directory -Force $sshDir | Out-Null
    ssh-keygen -t ed25519 -f $key -N '""' -C "csv-courier-$Server"
}

# 4. per-box config as MACHINE env vars (visible to the SYSTEM task), so the
# repo stays generic and `git pull` can never clobber a box's identity
[Environment]::SetEnvironmentVariable("CSV_SERVER", $Server, "Machine")
[Environment]::SetEnvironmentVariable("CSV_SSH_KEY", ($key -replace '\\', '/'), "Machine")

# 5. nightly task at 23:55 VPS-local time: pull latest courier, then run it.
# StartWhenAvailable = catch up a missed start (e.g. the box was rebooting).
$cmd = "git -C $Clone pull --quiet; & $Clone\send-csvs.ps1"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger  = New-ScheduledTaskTrigger -Daily -At 23:55
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName "send-csvs" -Action $action -Trigger $trigger `
    -Settings $settings -User "SYSTEM" -Force | Out-Null

# 6. the one step this script cannot do: authorize the key on the server
$pub = Get-Content "$key.pub"
Write-Host ""
Write-Host "=== $Server set up. ONE manual step left ==="
Write-Host "Append this line to /home/app/.ssh/authorized_keys on the server:"
Write-Host ""
Write-Host "restrict,command=`"rrsync -wo /home/app/incoming`" $pub"
Write-Host ""
Write-Host "Then verify from this box:"
Write-Host "  powershell -Command `"$cmd`""
Write-Host "and check the log: C:/Results/send-csvs.log (expect 'rsync exit 0')"
