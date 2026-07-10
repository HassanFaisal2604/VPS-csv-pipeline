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
# A half-installed choco (folder present, choco.exe gone) used to hard-stop and
# make the operator delete the folder by hand. Auto-repair instead: nothing on
# these boxes uses choco beyond the rsync/git we install, so nuking the broken
# stub and reinstalling is safe and is exactly what the manual fix was.
if (-not (Test-Path $chocoExe) -and (Test-Path "C:\ProgramData\chocolatey")) {
    Write-Host "Broken Chocolatey stub (no choco.exe) - removing and reinstalling."
    Remove-Item -Recurse -Force "C:\ProgramData\chocolatey"
}
if (-not (Test-Path $chocoExe)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = 3072  # TLS 1.2
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    if (-not (Test-Path $chocoExe)) { Write-Error "Chocolatey install failed - choco.exe still missing at $chocoExe"; exit 1 }
}
# Install by full choco path (PATH not yet refreshed this session), and let choco
# itself decide "already installed" - it no-ops cleanly, so re-runs are cheap.
foreach ($pkg in "rsync", "git") { & $chocoExe install $pkg -y }
# fresh installs land in Machine PATH; make them visible to THIS session too
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (Get-Command rsync -ErrorAction SilentlyContinue)) {
    Write-Error "rsync not on PATH after install - open a fresh admin PowerShell and re-run this script"; exit 1
}
rsync --version | Select-Object -First 1

# 2. SSH key, no passphrase (runs unattended from Task Scheduler).
# The task runs as SYSTEM, so the key MUST live in a machine location SYSTEM
# owns - ssh rejects a key it doesn't own ("bad ownership or modes"), so a key
# in a user profile (the old default) silently fails only under the SYSTEM task.
# Default to C:\ProgramData\csv-courier, owned by SYSTEM, no other access.
$key = if ($cfg['CSV_SSH_KEY']) { $cfg['CSV_SSH_KEY'] } else { "C:\ProgramData\csv-courier\csv-courier_ed25519" }
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Error "ssh-keygen not found - install the Windows OpenSSH Client, then re-run:`n  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"; exit 1
}
if (-not (Test-Path $key)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $key) | Out-Null
    ssh-keygen -t ed25519 -f $key -N '""' -C "csv-courier-$Server"
    # ssh-keygen is a native exe: a non-zero exit does NOT trip EAP=Stop, so a
    # failed keygen would sail on and only crash later reading the missing .pub.
    # Check the outputs exist and bail with a clear message if not.
    if (-not ((Test-Path $key) -and (Test-Path "$key.pub"))) {
        Write-Error "ssh-keygen did not produce a key pair at $key - see its output above"; exit 1
    }
}
# Lock the private key to SYSTEM-ONLY. Runs EVERY setup (not just on create) so a
# re-run repairs a loose ACL - this script is the repair tool. ssh StrictModes
# refuses a key ANY other account can read, so we grant SYSTEM alone and must NOT
# grant Administrators: an Administrators:R ACE reads as group-readable (0470) and
# the key is rejected ("bad permissions" -> publickey denied -> rsync exit 12).
# What SSH actually enforces is the DACL: it rejects a key ANY other account can
# read - it does NOT require SYSTEM to be the owner (verified: an Administrators-
# owned key with a SYSTEM-only DACL authenticates fine). So the load-bearing part
# is the DACL; ownership is cosmetic. Order: take ownership FIRST (a fresh key is
# owned by the admin who ran keygen; a key from a prior run is SYSTEM-owned and
# otherwise un-editable by this admin), then rewrite the DACL. The original bug was
# doing /setowner-to-SYSTEM FIRST, which stripped our write-DACL right so the grant
# silently failed and left the default loose ACL - publickey denied only under the
# SYSTEM task. /setowner back to SYSTEM at the end is best-effort (needs SeRestore,
# which a normal admin lacks) and its failure is harmless, so it's suppressed.
# Well-known SIDs, not names, so this holds on non-English Windows:
# S-1-5-18 = SYSTEM, -32-544 = Administrators, -32-545 = Users, -5-11 = Authenticated Users.
takeown /F $key /A | Out-Null
icacls $key /inheritance:r | Out-Null
icacls $key /remove:g "*S-1-5-32-544" "*S-1-5-32-545" "*S-1-5-11" "*S-1-1-0" "$env:USERDOMAIN\$env:USERNAME" | Out-Null
icacls $key /grant:r "*S-1-5-18:F" | Out-Null
icacls $key /setowner "*S-1-5-18" 2>$null | Out-Null   # best-effort, harmless if denied
# icacls is a native exe (no throw on failure), so ASSERT the end state instead of
# trusting exit codes: only SYSTEM may remain, or the key is still SSH-rejectable.
$acl = (icacls $key 2>$null) -join "`n"
if ($acl -match ('BUILTIN\\|Everyone|Authenticated Users|' + [regex]::Escape("$env:USERDOMAIN\$env:USERNAME"))) {
    Write-Error "key ACL still grants a non-SYSTEM account - lockdown failed:`n$acl"; exit 1
}
# Re-run on an already-set-up box whose .pub was cleaned up (only the private key
# and the server-side authorized_keys line are needed to send): derive the .pub
# from the private key instead of crashing at the "print the line" step.
if (-not (Test-Path "$key.pub")) {
    ssh-keygen -y -f $key | Out-File -Encoding ascii -NoNewline "$key.pub"
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
# The clone was made by the admin user but the task runs as SYSTEM - modern git
# refuses cross-user repos ("dubious ownership"), which would kill self-update
# silently forever. Mark the courier dir safe machine-wide (--system needs the
# admin shell we're already in).
if ($git) {
    $herePosix = $here -replace '\\', '/'
    # try/catch: under EAP=Stop, PS 5.1 can throw on redirected native stderr
    try { $safe = @(& $git config --system --get-all safe.directory 2>$null) } catch { $safe = @() }
    if ($safe -notcontains $herePosix) { & $git config --system --add safe.directory $herePosix }
}
# A failed pull must leave a trace in the log (not vanish in catch{}) - a dead
# self-update means fixes pushed upstream never reach this box.
$logNote = "Add-Content '$here\send-csvs.log' ((Get-Date -Format o) + ' git pull FAILED"
$pull = if ($git) {
    "try { & '$git' -C '$here' pull --quiet 2>&1 | Out-Null; if (`$LASTEXITCODE -ne 0) { $logNote exit ' + `$LASTEXITCODE + ' - self-update dead, re-run setup-vps.ps1') } } catch { $logNote : ' + `$_.Exception.Message) }; "
} else { "" }
$cmd  = "$pull& '$here\send-csvs.ps1'"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger  = New-ScheduledTaskTrigger -Daily -At 23:55
# RestartCount covers a LAUNCH failure only (box mid-reboot at 23:55) - Task
# Scheduler does NOT restart on a nonzero exit code, so a failed SEND is retried
# inside send-csvs.ps1 itself. 2h hard limit so a hung transfer can't block the
# next night.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName "send-csvs" -Action $action -Trigger $trigger `
    -Settings $settings -User "SYSTEM" -Force | Out-Null

# 4. the one step this script cannot do: authorize the key on the server
$pub = Get-Content "$key.pub"
Write-Host ""
Write-Host "=== $Server set up. ONE manual step left ==="
Write-Host "Append this line to /home/app/.ssh/authorized_keys on the server:"
Write-Host ""
Write-Host "restrict,command=`"rrsync -no-lock -wo /home/app/incoming`" $pub"
Write-Host ""
Write-Host "Then verify from this box:"
Write-Host "  powershell -Command `"$cmd`""
Write-Host "and check the log (expect 'rsync exit 0')"
