# VPS CSV Pipeline — courier scripts

Ships nightly bot-result CSVs from each Windows VPS to the ingest server via
rsync over SSH. Pulled by every VPS before each run — push a fix here and all
VPSes have it the next night.

## One-time setup per VPS (admin PowerShell)

```powershell
git clone https://github.com/HassanFaisal2604/VPS-csv-pipeline.git C:\courier
powershell -ExecutionPolicy Bypass -File C:\courier\setup-vps.ps1 -Server SV1
```

`setup-vps.ps1` installs rsync + git (Chocolatey), generates an SSH key,
stores the per-box identity as machine env vars (`CSV_SERVER`, `CSV_SSH_KEY`),
and registers the 23:55 nightly task (git pull, then send). It ends by
printing the `authorized_keys` line to add on the server. Idempotent — re-run
it any time to repair a box.

## Per-box configuration (env vars, never in git)

| Var | Meaning | Default |
|---|---|---|
| `CSV_SERVER` | VPS name = server-side incoming subfolder | set by setup |
| `CSV_SSH_KEY` | private key path | set by setup |
| `CSV_RESULTS` | where the bot writes CSVs | `C:/Results` |
| `CSV_DEST_HOST` | user@host of the ingest server | `app@188.245.122.19` |
| `CSV_LOG` | log file | `C:/Results/send-csvs.log` |

Change any of them with `[Environment]::SetEnvironmentVariable("CSV_RESULTS", "D:/Results", "Machine")`.

## Manual run / check

```powershell
powershell -Command "git -C C:\courier pull --quiet; & C:\courier\send-csvs.ps1"
Get-Content C:/Results/send-csvs.log -Tail 5    # expect "rsync exit 0"
```

Files newer than 5 minutes are deliberately held back (the bot may still be
writing) — they ship the next night automatically.
