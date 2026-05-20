# Deploy Hermes Agent to Railway from this repository.
# Requires: railway CLI, RAILWAY_TOKEN (or `railway login` in an interactive terminal).
#
# Usage (from repo root):
#   $env:RAILWAY_TOKEN = "<token from Railway dashboard → Account → Tokens>"
#   .\scripts\deploy-railway.ps1
#
# Optional:
#   .\scripts\deploy-railway.ps1 -ProjectId <uuid> -ServiceId <uuid> -EnvironmentId <uuid>
#   .\scripts\deploy-railway.ps1 -SyncHermesEnv   # copy keys from ~/.hermes/.env (non-interactive keys only)

param(
    [string]$ProjectId = $env:RAILWAY_PROJECT_ID,
    [string]$ServiceId = $env:RAILWAY_SERVICE_ID,
    [string]$EnvironmentId = $env:RAILWAY_ENVIRONMENT_ID,
    [switch]$SyncHermesEnv,
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

function Require-RailwayCli {
    if (-not (Get-Command railway -ErrorAction SilentlyContinue)) {
        throw "railway CLI not found. Install: https://docs.railway.com/develop/cli"
    }
}

function Test-RailwayAuth {
    $null = railway whoami 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw @"
Railway CLI is not authenticated.
  1. Create a token: Railway dashboard → Account → Tokens
  2. `$env:RAILWAY_TOKEN = '<token>'
  Or run `railway login` in an interactive terminal (not in CI/agent shells).
"@
    }
}

function Invoke-RailwayLink {
    if ($ProjectId) {
        $linkArgs = @("link", "-p", $ProjectId)
        if ($EnvironmentId) { $linkArgs += @("-e", $EnvironmentId) }
        if ($ServiceId) { $linkArgs += @("-s", $ServiceId) }
        & railway @linkArgs
        if ($LASTEXITCODE -ne 0) { throw "railway link failed" }
    } elseif (-not (Test-Path (Join-Path $RepoRoot ".railway"))) {
        Write-Host "No -ProjectId and no .railway link. Run: railway link" -ForegroundColor Yellow
        & railway link
        if ($LASTEXITCODE -ne 0) { throw "railway link failed" }
    }
}

function Set-RailwayVar {
    param([string]$Key, [string]$Value, [switch]$SkipDeploys)
    $args = @("variable", "set", "${Key}=${Value}")
    if ($SkipDeploys) { $args += "--skip-deploys" }
    & railway @args
    if ($LASTEXITCODE -ne 0) { throw "Failed to set variable $Key" }
}

function Ensure-Volume {
    $listJson = railway volume list --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not list volumes; ensure /opt/data is mounted in the Railway dashboard." -ForegroundColor Yellow
        return
    }
    $volumes = $listJson | ConvertFrom-Json
    $mounted = $false
    foreach ($v in $volumes) {
        if ($v.mountPath -eq "/opt/data") { $mounted = $true; break }
    }
    if (-not $mounted) {
        Write-Host "Adding volume at /opt/data ..."
        railway volume add --mount-path /opt/data
        if ($LASTEXITCODE -ne 0) { throw "railway volume add failed" }
    }
}

function Set-DashboardVariables {
    Set-RailwayVar -Key "HERMES_DASHBOARD" -Value "1" -SkipDeploys
    Set-RailwayVar -Key "HERMES_DASHBOARD_HOST" -Value "0.0.0.0" -SkipDeploys
  # Railway service variable reference for the public HTTP port
    Set-RailwayVar -Key "HERMES_DASHBOARD_PORT" -Value '${{PORT}}' -SkipDeploys
    Set-RailwayVar -Key "API_SERVER_ENABLED" -Value "true" -SkipDeploys
    Set-RailwayVar -Key "API_SERVER_HOST" -Value "127.0.0.1" -SkipDeploys
    Set-RailwayVar -Key "API_SERVER_PORT" -Value "8642" -SkipDeploys
    $apiKey = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
    Set-RailwayVar -Key "API_SERVER_KEY" -Value $apiKey -SkipDeploys
    Set-RailwayVar -Key "GATEWAY_HEALTH_URL" -Value "http://127.0.0.1:8642" -SkipDeploys
}

function Sync-FromHermesEnv {
    $envPath = Join-Path $env:USERPROFILE ".hermes\.env"
    if (-not (Test-Path $envPath)) {
        Write-Host "No $envPath — skip -SyncHermesEnv" -ForegroundColor Yellow
        return
    }
    $skipKeys = @(
        "HERMES_DASHBOARD", "HERMES_DASHBOARD_HOST", "HERMES_DASHBOARD_PORT",
        "API_SERVER_ENABLED", "API_SERVER_HOST", "API_SERVER_PORT", "API_SERVER_KEY",
        "GATEWAY_HEALTH_URL", "PORT", "RAILWAY_TOKEN", "RAILWAY_API_TOKEN"
    )
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { return }
        $name = $Matches[1]
        $val = $Matches[2].Trim().Trim('"').Trim("'")
        if ($name -in $skipKeys -or [string]::IsNullOrWhiteSpace($val)) { return }
        Set-RailwayVar -Key $name -Value $val -SkipDeploys
    }
}

Require-RailwayCli
Test-RailwayAuth
Invoke-RailwayLink

Write-Host "Railway context:" -ForegroundColor Cyan
railway status

Ensure-Volume
Set-DashboardVariables
if ($SyncHermesEnv) { Sync-FromHermesEnv }

if (-not $SkipDeploy) {
    Write-Host "Deploying from $RepoRoot ..." -ForegroundColor Cyan
    railway up --detach
    if ($LASTEXITCODE -ne 0) { throw "railway up failed" }
    Write-Host "Deployment started. Logs: railway logs" -ForegroundColor Green
    railway domain 2>$null
}
