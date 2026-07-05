# send-csvs.ps1 — VPS courier: ship bot CSVs to the Hetzner server via rsync/ssh.
# Runs from Task Scheduler (via git pull, see setup-vps.ps1) after the bot writes.
# Requires cwRsync installed and on PATH. See send-csvs.sh for the POSIX reference.
# This file is pulled from git — do NOT edit it on the box. Per-box values come
# from machine environment variables (set once by setup-vps.ps1), so `git pull`
# can never clobber them:
#   CSV_SERVER    per-VPS name = incoming subfolder (e.g. SV1)   [required]
#   CSV_SSH_KEY   path to the private key                        [required]
#   CSV_RESULTS   where the bot writes *.csv     (default C:/Results; use
#                 /cygdrive/c/Results if this rsync build can't see C:/)
#   CSV_DEST_HOST user@host of the ingest server (default app@188.245.122.19)
#   CSV_LOG       log file path                  (default C:/Results/send-csvs.log)

$Server   = $env:CSV_SERVER
$SshKey   = $env:CSV_SSH_KEY
if (-not $Server -or -not $SshKey) { Write-Error "CSV_SERVER / CSV_SSH_KEY env vars not set — run setup-vps.ps1"; exit 2 }
$Results  = if ($env:CSV_RESULTS)   { $env:CSV_RESULTS }   else { "C:/Results" }
$DestHost = if ($env:CSV_DEST_HOST) { $env:CSV_DEST_HOST } else { "app@188.245.122.19" }
$LogFile  = if ($env:CSV_LOG)       { $env:CSV_LOG }       else { "C:/Results/send-csvs.log" }

# NOTE: the key is locked server-side to rrsync rooted at /home/app/incoming,
# so the destination path is RELATIVE to that root — just /$Server/, not the full path.
$Dest    = "${DestHost}:/$Server/"

# only files older than 5 min: the bot may still be writing newer ones (plan guard)
$cutoff = (Get-Date).AddMinutes(-5)
$list = New-TemporaryFile
Get-ChildItem -Path $Results -Recurse -Filter *.csv |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object { $_.FullName.Substring($Results.Length + 1).Replace("\", "/") } |
    Set-Content -Encoding ascii $list

# accept-new: trust the server's host key on first contact (task runs unattended
# as SYSTEM, whose known_hosts is empty), refuse if it ever CHANGES afterwards
$out = & rsync -az --remove-source-files --files-from="$list" -e "ssh -i $SshKey -o StrictHostKeyChecking=accept-new" "$Results" "$Dest" 2>&1
$code = $LASTEXITCODE
Remove-Item $list
"$(Get-Date -Format o) rsync exit $code`n$out" | Add-Content $LogFile
exit $code
