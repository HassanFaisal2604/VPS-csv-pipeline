# VPS Onboarding Guide (agent-executable)

Turn a Windows VPS into a CSV courier that ships bot results to the ingest
server nightly. Written so an agent (or a human following mechanically) can
run it end to end. Every step has a VERIFY with the expected result - do not
proceed past a failed VERIFY; see "Known failures" at the bottom first.

Conventions:
- `PS>` = command in an **elevated (admin) PowerShell** on the VPS.
- `server$` = command as user `app` on the ingest server (`ssh app@188.245.122.19`).
- `<SV_NAME>` = this box's unique name: SV1, SV2, ... (test machines: TEST).

## Prerequisites

- Admin PowerShell access on the VPS.
- Ability to run one command on the ingest server (step 0 and step 5).
- The bot writes CSVs under `C:\Results\<Account>\<Tool>\*.csv` (if elsewhere,
  note the path for step 3).

## Step 0 - server prep (once ever, skip if another VPS is already live)

```
server$ mkdir -p /home/app/incoming /home/app/processed /home/app/failed
server$ command -v rrsync || sudo sh -c 'gunzip -c /usr/share/doc/rsync/scripts/rrsync.gz > /usr/local/bin/rrsync && chmod +x /usr/local/bin/rrsync'
```

VERIFY: `command -v rrsync` prints a path.
If the gunzip source is missing: `find /usr/share -name "rrsync*"` and copy
what it finds to `/usr/local/bin/rrsync`, `chmod +x` it.

## Step 1 - get git, clone the courier repo

```
PS> git --version
```

If "not recognized": `PS> winget install Git.Git`, then CLOSE and REOPEN the
admin PowerShell (PATH refresh), and re-check.

```
PS> git clone https://github.com/HassanFaisal2604/VPS-csv-pipeline.git C:\courier
```

VERIFY: `PS> Test-Path C:\courier\.git` prints `True`.
NEVER use a GitHub ZIP download instead - the nightly self-update needs a
real clone.

## Step 2 - configure this box

```
PS> Copy-Item C:\courier\.env.example C:\courier\.env
PS> notepad C:\courier\.env
```

Set `CSV_SERVER=<SV_NAME>`. Leave everything else commented unless this box
deviates (bot writes somewhere other than `C:\Results` -> set `CSV_RESULTS`).

VERIFY: `PS> Select-String CSV_SERVER= C:\courier\.env` shows the name, on a
line that does NOT start with `#`.

## Step 3 - run setup

```
PS> powershell -ExecutionPolicy Bypass -File C:\courier\setup-vps.ps1
```

Expected output, in order: an `rsync version 3.x` line, possibly Chocolatey /
package install output on first run, then a block:

```
=== <SV_NAME> set up. ONE manual step left ===
Append this line to /home/app/.ssh/authorized_keys on the server:
restrict,command="rrsync -wo /home/app/incoming" ssh-ed25519 AAAA... csv-courier-<SV_NAME>
```

Copy that whole `restrict,...` line.

VERIFY 1: the printed line ends with `csv-courier-<SV_NAME>` - if it ends
with anything else (e.g. a personal email), STOP: the wrong key was picked
up; set `CSV_SSH_KEY` in `.env` to a fresh path and re-run.
VERIFY 2: `PS> Get-ScheduledTask send-csvs` shows the task, State `Ready`.
Setup is idempotent - re-running it any time is safe and is the repair tool.

## Step 4 - authorize the key on the server

```
server$ echo 'PASTE_THE_WHOLE_LINE_FROM_STEP_3' >> /home/app/.ssh/authorized_keys
server$ chmod 600 /home/app/.ssh/authorized_keys
```

Use single quotes exactly as shown (the line contains double quotes).

VERIFY: `server$ grep -c "csv-courier-<SV_NAME>" /home/app/.ssh/authorized_keys`
prints `1` (not 2 - no duplicate lines).

## Step 5 - end-to-end test

If this is a test machine with no bot, create fake data first (skip on a real
VPS - the bot's files are already there):

```
PS> New-Item -ItemType Directory -Force C:\Results\acct1\Follows | Out-Null
PS> "Account,Date,Target`na,d,user1" | Set-Content C:\Results\acct1\Follows\FollowResults_2026_7_6.csv
PS> Get-ChildItem C:\Results -Recurse -Filter *.csv | ForEach-Object { $_.LastWriteTime = (Get-Date).AddMinutes(-10) }
```

Fire the real scheduled task (same code path as 23:55, including the SYSTEM
account):

```
PS> Start-ScheduledTask -TaskName send-csvs
PS> Start-Sleep 15; Get-Content C:\Results\send-csvs.log -Tail 5
```

VERIFY, all four:
1. Log's last entry says `rsync exit 0`.
2. CSVs older than 5 minutes are GONE from `C:\Results` (files newer than
   5 min remaining behind is CORRECT - they ship next night).
3. `server$ find /home/app/incoming/<SV_NAME> -name '*.csv'` lists the files,
   with the `<Account>/<Tool>/` structure preserved.
4. Drop-only restriction holds - this must be REFUSED (no shell, no listing):
   `PS> ssh -i $env:USERPROFILE\.ssh\csv-courier_ed25519 app@188.245.122.19 ls`

## Step 6 - done

Nothing else to start: the task runs nightly at 23:55 VPS-local time, pulls
the latest courier from this repo first, and catches up any missed night
automatically (files stay put until a transfer succeeds). Fixes are shipped
by pushing to this repo - never edit files on the box except `.env`.

## Decommission a test machine

```
PS> Unregister-ScheduledTask -TaskName send-csvs -Confirm:$false
PS> Remove-Item -Recurse -Force C:\courier, C:\Results
PS> Remove-Item $env:USERPROFILE\.ssh\csv-courier_ed25519* -Force
```

```
server$ sed -i '/csv-courier-<SV_NAME>/d' /home/app/.ssh/authorized_keys
server$ rm -rf /home/app/incoming/<SV_NAME>
```

(The same two server lines revoke any compromised VPS in seconds.)

## Known failures (all hit and fixed during shakedown - newest script has the fixes)

| Symptom | Cause | Fix |
|---|---|---|
| Parser errors: "string is missing the terminator" | Running an old copy (pre-ASCII fix) | `git -C C:\courier pull`, retry |
| Chocolatey "existing installation detected" + `choco not recognized` | Broken half-install | If `C:\ProgramData\chocolatey\bin\choco.exe` is missing: delete `C:\ProgramData\chocolatey`, re-run setup |
| Key line ends with a personal email | Old default reused an existing `id_ed25519` | Pull latest, re-run setup (dedicated `csv-courier_ed25519` default) |
| rsync: "No such file or directory" on `C:/Results` | cwRsync needs cygwin paths | In `.env`: `CSV_RESULTS=/cygdrive/c/Results` |
| "Permission denied (publickey)" | authorized_keys line mangled or perms | Re-paste as ONE line in single quotes; `chmod 600` the file |
| rsync error mentioning the destination path | rrsync missing/not executable on server | Redo step 0 |
| `git pull` fails in the log | Box was set up from a ZIP, not a clone | Redo step 1 into `C:\courier`, re-run setup |
