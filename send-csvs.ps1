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
$LogFile  = if ($cfg['CSV_LOG'])       { $cfg['CSV_LOG'] }       else { "C:/Results/send-csvs.log" }

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
# OpenSSH kills the rsync protocol at 0 bytes (cygwin/native pipe mismatch).
$BundledSsh = "C:\ProgramData\chocolatey\lib\rsync\tools\ssh.exe"
$SshCmd = if ($cfg['CSV_SSH_EXE']) { ConvertTo-CygPath $cfg['CSV_SSH_EXE'] }
          elseif (Test-Path $BundledSsh) { ConvertTo-CygPath $BundledSsh }
          else { "ssh" }

# only files older than 5 min: the bot may still be writing newer ones (plan guard)
$cutoff = (Get-Date).AddMinutes(-5)
$files = @(Get-ChildItem -Path $Results -Recurse -Filter *.csv |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object { $_.FullName.Substring($Results.Length + 1).Replace("\", "/") })

# the file list goes to rsync via STDIN (--files-from=-), never via a temp
# file: this cygwin rsync parses any Windows path argument (C:\...) as a
# remote host, so no Windows path may appear anywhere on its command line.
# accept-new: trust the server's host key on first contact (task runs unattended
# as SYSTEM, whose known_hosts is empty), refuse if it ever CHANGES afterwards
$out = $files | & rsync -az --remove-source-files --files-from=- -e "$SshCmd -i $SshKeyRsync -o StrictHostKeyChecking=accept-new" "$RsyncSrc" "$Dest" 2>&1
$code = $LASTEXITCODE
"$(Get-Date -Format o) rsync exit $code`n$out" | Add-Content $LogFile
exit $code
