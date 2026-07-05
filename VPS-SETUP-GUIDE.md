# VPS Onboarding Guide (agent-executable)

Turn a Windows VPS into a CSV courier that ships bot results to the ingest
server nightly. Written so an agent (or a human following mechanically) can
run it end to end. Every step has a VERIFY with the expected result - do not
proceed past a failed VERIFY; see "Known failures" at the bottom first.

Conventions:
- `PS>` = command in an **elevated (admin) PowerShell** on the VPS.
- `server$` = command as user `app` on the ingest server (`ssh app@188.245.122.19`).
- `<SV_NAME>` = this box's unique name: SV1, SV2, ... (test machines: TEST).

## Rules for agents (read first - every one of these was violated during
## the first shakedown and cost hours)

1. **Never edit any file in `C:\courier` except `.env`.** The box pulls this
   repo nightly; local edits to tracked files make every future `git pull`
   fail, silently killing self-update. If a script seems buggy: pull first,
   re-test, and if it persists REPORT the bug upstream - do not patch locally.
2. **Before debugging anything, run `git -C C:\courier pull`.** Most bugs you
   hit have already been fixed upstream. Check `git log --oneline -3` and
   compare with the repo on GitHub before investigating.
3. **If the clone is dirty** (a previous agent edited files):
   `git -C C:\courier checkout -- . ; git -C C:\courier pull`
4. **`.env` values:** `CSV_RESULTS` must be a WINDOWS-style path
   (`C:/Results` or `C:\Results`). Never put `/cygdrive/...` in `.env` -
   the script converts for rsync internally.
5. **Test through the scheduled task** (`Start-ScheduledTask send-csvs`),
   not by running the script as your own user - the task runs as SYSTEM,
   which has different PATH, known_hosts, and env; bugs hide in the gap.
6. **Do not "fix" the rsync invocation.** The invariant (see next section)
   looks wrong to fresh eyes and is load-bearing.

## How the transfer works + where a failure localizes

Chain: PowerShell enumerates files -> pipes the list to cygwin rsync via
STDIN -> rsync spawns the CYGWIN ssh bundled with it -> server sshd checks
`authorized_keys` -> the key's forced command `rrsync -wo /home/app/incoming`
validates the rsync request -> files land under `incoming/<SV_NAME>/`.

Load-bearing invariants (violating either reintroduces a fixed bug):
- **No Windows path may appear anywhere on rsync's command line.** This
  cygwin build parses any `X:` as a remote host. Hence: file list via
  `--files-from=-` (stdin, no temp file), source and key paths converted
  to `/cygdrive/...` form by `ConvertTo-CygPath`.
- **rsync must use its bundled cygwin ssh**, never Windows-native OpenSSH
  (`C:\Windows\System32\OpenSSH`). Native ssh works interactively but
  kills the rsync protocol at 0 bytes (cygwin/native pipe mismatch).

Fault localization by symptom:
| Symptom | Layer |
|---|---|
| PowerShell parse/`Get-ChildItem` errors | script / `.env` (Windows side) |
| `could not resolve hostname <drive letter>` | a Windows path leaked onto rsync's command line |
| `Permission denied (publickey)` | server `authorized_keys` (line mangled, perms, wrong key) |
| `connection unexpectedly closed (0 bytes)` | ssh transport (wrong ssh binary) or rrsync rejected the command |
| `mkdir ... Permission denied (13)` | server filesystem (dirs root-owned) |
| `rsync exit 0` but files missing server-side | wrong `CSV_SERVER` / wrong rrsync root |

Harmless noise (ignore if the transfer succeeds): `Could not create
directory '/home/SYSTEM/.ssh'` and `Failed to add the host to the list of
known hosts` - cygwin ssh under SYSTEM has no home; the connection proceeds.

## Fast path (use this unless it fails)

Steps 1-3 below collapse into ONE paste in an admin PowerShell:

```
$env:CSV_SERVER="SV1"; irm https://raw.githubusercontent.com/HassanFaisal2604/VPS-csv-pipeline/main/bootstrap.ps1 | iex
```

Then do step 4 (authorize the printed key line on the server) and step 5
(end-to-end test). If the paste fails anywhere, fall back to the manual
steps below - they are the same actions, separated.

## Prerequisites

- Admin PowerShell access on the VPS.
- Ability to run one command on the ingest server (step 0 and step 5).
- The bot writes CSVs under `C:\Results\<Account>\<Tool>\*.csv` (if elsewhere,
  note the path for step 3).

## Step 0 - server prep (once ever, skip if another VPS is already live)

```
server$ mkdir -p /home/app/incoming /home/app/processed /home/app/failed   # run as app, NOT root
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
by pushing to this repo - never edit files on the box except `.env`
(rule 1 above; this is the one that bites agents).

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
| rsync: "source and destination cannot both be remote" | Old script passed `C:/...` to rsync (reads the colon as a remote host) | `git -C C:\courier pull` - the script now converts paths itself. `CSV_RESULTS` stays Windows-style |
| "connection unexpectedly closed (0 bytes)" right after SSH auth succeeds | cygwin rsync spawned Windows-native OpenSSH (pipe mismatch kills the protocol) | `git -C C:\courier pull` - the courier now uses the cygwin ssh bundled with the rsync package (`CSV_SSH_EXE` in `.env` overrides) |
| `mkdir ... failed: Permission denied (13)` on the server side | Step 0 dirs were created as root, so `app` cannot write them | `sudo chown -R app:app /home/app/incoming /home/app/processed /home/app/failed` |
| "Permission denied (publickey)" | authorized_keys line mangled or perms | Re-paste as ONE line in single quotes; `chmod 600` the file |
| rsync error mentioning the destination path | rrsync missing/not executable on server | Redo step 0 |
| `git pull` fails in the log | Box was set up from a ZIP, not a clone | Redo step 1 into `C:\courier`, re-run setup |
