# bootstrap.ps1 - zero-to-courier in one paste. Run in an ADMIN PowerShell:
#
#   $env:CSV_SERVER="SV1"; irm https://raw.githubusercontent.com/HassanFaisal2604/VPS-csv-pipeline/main/bootstrap.ps1 | iex
#
# Installs git if missing, clones the courier repo to C:\courier, writes .env
# with this box's name, and runs setup-vps.ps1. After it finishes, ONE manual
# step remains: paste the printed authorized_keys line on the server.
# Idempotent - safe to re-run.

$ErrorActionPreference = "Stop"

$Server = $env:CSV_SERVER
if (-not $Server) { $Server = Read-Host "Box name (SV1, SV2, ...)" }
if (-not $Server) { Write-Error "no box name given"; exit 1 }

# git (winget ships on Server 2022/Win10+; fall back to choco which setup installs anyway)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

if (-not (Test-Path "C:\courier\.git")) {
    git clone https://github.com/HassanFaisal2604/VPS-csv-pipeline.git C:\courier
} else {
    git -C C:\courier pull --quiet
}

if (-not (Test-Path "C:\courier\.env")) {
    "CSV_SERVER=$Server" | Set-Content C:\courier\.env
}

& powershell -ExecutionPolicy Bypass -File C:\courier\setup-vps.ps1
