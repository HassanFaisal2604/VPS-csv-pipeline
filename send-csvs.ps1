# send-csvs.ps1 - VPS courier: ship bot CSVs to the Hetzner server via rsync/ssh.
# Runs from Task Scheduler (via git pull, see setup-vps.ps1) after the bot writes.
# Requires cwRsync installed and on PATH. See send-csvs.sh for the POSIX reference.
# This file is pulled from git - do NOT edit it on the box. Per-box values live in
# .env next to this script (gitignored, so pull never clobbers it). See .env.example.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = @{}
foreach ($line in (Get-Content "$here\.env" -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
$Server   = $cfg['CSV_SERVER']
if (-not $Server) { Write-Error "CSV_SERVER not set - copy .env.example to .env in $here and edit it"; exit 2 }
$Results  = if ($cfg['CSV_RESULTS'])   { $cfg['CSV_RESULTS'] }   else { "C:/Results" }
$DestHost = if ($cfg['CSV_DEST_HOST']) { $cfg['CSV_DEST_HOST'] } else { "app@188.245.122.19" }
$SshKey   = if ($cfg['CSV_SSH_KEY'])   { $cfg['CSV_SSH_KEY'] }   else { "$env:USERPROFILE/.ssh/csv-courier_ed25519" }
# Log next to the script (C:\courier) - a known path that always exists and is
# decoupled from C:\Results, so a missing/empty data folder can't hide errors.
# Override with CSV_LOG to send it anywhere (e.g. the Desktop); the dir is created.
$LogFile  = if ($cfg['CSV_LOG'])       { $cfg['CSV_LOG'] }       else { "$here\send-csvs.log" }
# watermark of the last successful send: files stay put in $Results (we do NOT
# delete after shipping), so without this every run would re-send everything.
$StateFile = if ($cfg['CSV_STATE'])    { $cfg['CSV_STATE'] }     else { "$here\.last-sent" }

# Ensure the log dir and results dir exist. Add-Content can't create the log if
# its parent folder is missing, so a missing C:\Results used to produce NO log at
# all (silent failure). Now a missing/empty Results just logs "queued 0 files".
foreach ($d in @((Split-Path -Parent $LogFile), $Results)) {
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
}

# NOTE: the key is locked server-side to rrsync rooted at /home/app/incoming,
# so the destination path is RELATIVE to that root - just /$Server/, not the full path.
$Dest    = "${DestHost}:/$Server/"

# rsync on Windows reads "C:/..." as remote host "C". PowerShell needs the
# Windows form, rsync the cygwin form - so keep $Results Windows-style and
# derive the rsync source automatically. (CSV_RESULTS must be a Windows path.)
function ConvertTo-CygPath($p) {
    if ($p -match '^([A-Za-z]):(.*)$') { "/cygdrive/" + $Matches[1].ToLower() + ($Matches[2] -replace '\\', '/') }
    else { $p }
}
$RsyncSrc    = ConvertTo-CygPath $Results
$SshKeyRsync = ConvertTo-CygPath $SshKey

# cygwin rsync MUST use its own bundled cygwin ssh - spawning Windows-native
# OpenSSH kills the rsync protocol at 0 bytes (cygwin/native pipe mismatch),
# and can't parse the /cygdrive key path (-> silent publickey failure).
# The cwrsync choco package ships ssh under tools\bin\ - locate it rather than
# hardcode, since the exact path varies by package version.
$BundledSsh = Get-ChildItem "C:\ProgramData\chocolatey\lib\rsync" -Recurse -Filter ssh.exe -ErrorAction SilentlyContinue |
              Select-Object -First 1 -ExpandProperty FullName
$SshCmd = if ($cfg['CSV_SSH_EXE']) { ConvertTo-CygPath $cfg['CSV_SSH_EXE'] }
          elseif ($BundledSsh)      { ConvertTo-CygPath $BundledSsh }
          else                      { "ssh" }
# rsync.exe by full path too - not always on a hand-run shell's PATH.
$Rsync = Get-ChildItem "C:\ProgramData\chocolatey\lib\rsync" -Recurse -Filter rsync.exe -ErrorAction SilentlyContinue |
         Select-Object -First 1 -ExpandProperty FullName
if (-not $Rsync) { $Rsync = "rsync" }

# Window = (last successful send, now-5min]. Lower bound: the watermark, so an
# already-shipped file is never re-sent (files are kept in $Results, not deleted).
# Upper bound: skip files touched in the last 5 min - the bot may still be writing.
# First run (no watermark) sends everything up to the cutoff (initial backfill).
# Wrapped so ANY failure (e.g. rsync missing, key error) still writes a log line
# instead of dying silently with no log - the log must always tell you what happened.
try {
    $since  = if (Test-Path $StateFile) {
        [datetime]::Parse((Get-Content $StateFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    } else { [datetime]::MinValue }
    $cutoff = (Get-Date).AddMinutes(-5)
    $files = @(Get-ChildItem -Path $Results -Recurse -Filter *.csv |
        Where-Object { $_.LastWriteTime -ge $since -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { $_.FullName.Substring($Results.Length + 1).Replace("\", "/") })

    # the file list goes to rsync via STDIN (--files-from=-), never via a temp
    # file: this cygwin rsync parses any Windows path argument (C:\...) as a
    # remote host, so no Windows path may appear anywhere on its command line.
    # accept-new: trust the server's host key on first contact (task runs unattended
    # as SYSTEM, whose known_hosts is empty), refuse if it ever CHANGES afterwards.
    # NO --remove-source-files: files are retained on this box in $Results.
    # -v --stats: log each file sent + a transfer summary (count, bytes, speed).
    # ConnectTimeout/ServerAlive: a dead route must fail fast, not hang until
    # Task Scheduler's kill. Retry in-script (loop below), NOT via the task's
    # RestartCount: Task Scheduler restarts only on a launch/crash failure, never
    # on a nonzero EXIT code, so a transient rsync failure (a network blip, or a
    # brief collision with another courier holding the server's incoming dir)
    # would otherwise silently lose the whole night. 3 attempts, 60s apart.
    $out = ""; $code = 1; $attempts = 0
    for ($t = 1; $t -le 3; $t++) {
        $attempts = $t
        $out = $files | & $Rsync -avz --stats --files-from=- -e "$SshCmd -i $SshKeyRsync -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=4" "$RsyncSrc" "$Dest" 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) { break }
        if ($t -lt 3) { Start-Sleep -Seconds 60 }
    }
    # Advance the watermark only on success, so a failed night retries the same
    # window next run (catch-up) instead of skipping it.
    if ($code -eq 0) { $cutoff.ToString("o") | Set-Content $StateFile }
    "$(Get-Date -Format o) queued $($files.Count) files, rsync exit $code after $attempts attempt(s)`n$out" | Add-Content $LogFile
    # Ship this box's courier log to the server too, so every run is visible
    # server-side (per box) without RDP-ing in. Lands at /home/app/incoming/
    # $Server/send-csvs.log - inside the rrsync jail, and the loader skips
    # non-.csv files so it just sits there. Best-effort: a log-ship failure must
    # never change the send's exit code, so it's fully isolated and swallowed.
    try {
        & $Rsync -az -e "$SshCmd -i $SshKeyRsync -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30" (ConvertTo-CygPath $LogFile) "${DestHost}:/$Server/send-csvs.log" 2>&1 | Out-Null
    } catch {}
    exit $code
} catch {
    "$(Get-Date -Format o) ERROR: $($_.Exception.Message)" | Add-Content $LogFile
    exit 1
}
