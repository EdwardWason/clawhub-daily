#!/usr/bin/env pwsh
# ============================================================
# clawhub-daily one-click publisher v1.0
# Targets: GitHub (EdwardWason/clawhub-daily) + ClawHub (slug: skill-daily)
# Usage:
#   cd clawhub-daily
#   powershell -ExecutionPolicy Bypass -File .\publish_all.ps1
# Skip: -SkipGitHub / -SkipClawHub
# ============================================================

param(
    [switch]$SkipGitHub,
    [switch]$SkipClawHub
)

$ErrorActionPreference = "Continue"
$SkillDir = $PSScriptRoot
Set-Location $SkillDir
$LogFile = Join-Path $SkillDir "publish_run.log"
"" | Out-File -FilePath $LogFile -Encoding UTF8

function Log($msg, $color = "White") {
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $LogFile -Value $msg
}

# ============================================================
# STEP 0: Token loading (env vars first, .env.local fallback)
# ============================================================
$EnvFile = Join-Path $SkillDir ".env.local"
if (Test-Path $EnvFile) {
    Log "[ENV] Loading .env.local as supplement ..."
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -match '^\s*$') { return }
        if ($line -match '^\s*(GH_TOKEN|CLAWHUB_TOKEN)\s*=\s*(.+?)\s*$') {
            $name = $Matches[1]
            $value = $Matches[2]
            $cur = [Environment]::GetEnvironmentVariable($name, "User")
            if (-not $cur) { $cur = [Environment]::GetEnvironmentVariable($name, "Process") }
            if ([string]::IsNullOrWhiteSpace($cur) -and $value -notmatch '^<\w+>$') {
                Set-Item -Path "Env:\$name" -Value $value
                Log "  + $name loaded from .env.local" Yellow
            }
        }
    }
} else {
    Log "[ENV] No .env.local" Yellow
}

$GH_TOKEN = [Environment]::GetEnvironmentVariable("GH_TOKEN", "User")
if (-not $GH_TOKEN) { $GH_TOKEN = [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process") }
if (-not $GH_TOKEN) { $GH_TOKEN = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "User") }
if (-not $GH_TOKEN) { $GH_TOKEN = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process") }

$CLAWHUB_TOKEN = [Environment]::GetEnvironmentVariable("CLAWHUB_TOKEN", "User")
if (-not $CLAWHUB_TOKEN) { $CLAWHUB_TOKEN = [Environment]::GetEnvironmentVariable("CLAWHUB_TOKEN", "Process") }

if ($GH_TOKEN) { Log ("[ENV] OK GH_TOKEN loaded (len: {0})" -f $GH_TOKEN.Length) Green }
else { Log "[ENV] MISSING GH_TOKEN" Red }
if ($CLAWHUB_TOKEN) { Log ("[ENV] OK CLAWHUB_TOKEN loaded (len: {0})" -f $CLAWHUB_TOKEN.Length) Green }
else { Log "[ENV] MISSING CLAWHUB_TOKEN" Red }

# ============================================================
# STEP 1: Build zip (excluding .git, data, .env.local, __pycache__)
# ============================================================
Log "`n========== 0. Build skill zip ==========" Cyan

$ZipPath = Join-Path $SkillDir "clawhub-daily-v1.0.0.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

$excludeDirs = @(".git", "data", "__pycache__", ".venv", "node_modules", "logs")
$excludeFiles = @(".env.local", "*.pyc", "*.log")

function Should-Exclude($path) {
    foreach ($d in $excludeDirs) {
        if ($path -like "*\$d\*" -or $path -like "$d") { return $true }
    }
    foreach ($f in $excludeFiles) {
        if ($path -like $f) { return $true }
    }
    return $false
}

$filesToZip = @()
Get-ChildItem -Path $SkillDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($SkillDir.Length + 1)
    if (-not (Should-Exclude $rel)) {
        $filesToZip += $_
    }
}

Log ("[ZIP] Including {0} files ..." -f $filesToZip.Count)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($SkillDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# Remove excluded entries from zip
$tempZip = "$ZipPath.tmp"
$zip = [System.IO.Compression.ZipFile]::Open($ZipPath, "Update")
$entriesToDelete = @()
foreach ($entry in $zip.Entries) {
    foreach ($d in $excludeDirs) {
        if ($entry.FullName -like "$d/*" -or $entry.FullName -like "*/$d/*") {
            $entriesToDelete += $entry
            break
        }
    }
    foreach ($f in $excludeFiles) {
        if ($entry.Name -like $f) {
            $entriesToDelete += $entry
            break
        }
    }
}
foreach ($e in $entriesToDelete) { $e.Delete() }
$zip.Dispose()

$zipSize = (Get-Item $ZipPath).Length
Log ("[ZIP] Created: {0} ({1:N0} bytes, {2} entries)" -f $ZipPath, $zipSize, (Get-ChildItem $ZipPath).Count) Green

# ============================================================
# STEP 2: Publish to GitHub
# ============================================================
$ghOk = $true
if (-not $SkipGitHub) {
    Log "`n========== 1. Publish to GitHub ==========" Cyan

    if ([string]::IsNullOrWhiteSpace($GH_TOKEN)) {
        Log "[ERROR] GH_TOKEN not configured" Red
        $ghOk = $false
    } else {
        $Repo = "clawhub-daily"
        $Owner = "EdwardWason"
        $ApiBase = "https://api.github.com"
        $Headers = @{
            "Authorization" = "token $GH_TOKEN"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "clawhub-daily-publisher"
        }

        # 1.1 Check or create repo
        Log "[1/6] Checking repo $Owner/$Repo ..."
        $repoCheck = Invoke-RestMethod -Uri "$ApiBase/repos/$Owner/$Repo" -Headers $Headers -Method Get
        if ($LASTEXITCODE -ne 0 -or $repoCheck.message) {
            Log "[1/6] Repo not found, creating ..." Yellow
            $body = @{
                name        = $Repo
                description = "Daily ClawHub Skill briefing - 4-dimension rotation, 7 pain-points, 10-day dedup"
                private     = $false
                license     = "MIT-0"
            } | ConvertTo-Json
            $resp = Invoke-RestMethod -Uri "$ApiBase/user/repos" -Headers $Headers -Method Post -Body $body -ContentType "application/json"
            if ($resp.html_url) {
                Log ("[1/6] Repo created: {0}" -f $resp.html_url) Green
            } else {
                Log ("[1/6] Repo create failed: {0}" -f ($resp.message -join ", ")) Red
                $ghOk = $false
            }
        } else {
            Log ("[1/6] Repo exists: {0}" -f $repoCheck.html_url) Green
        }

        if ($ghOk) {
            # 1.2 Upload files
            Log "[2/6] Uploading files ..."
            $uploadCount = 0
            foreach ($f in $filesToZip) {
                $rel = $f.FullName.Substring($SkillDir.Length + 1) -replace "\\", "/"
                $url = "$ApiBase/repos/$Owner/$Repo/contents/$rel"
                $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))

                # Check if exists
                $existing = $null
                try {
                    $existing = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
                } catch {}

                $payload = @{
                    message = "Add $rel"
                    content = $content
                    branch  = "main"
                } | ConvertTo-Json
                if ($existing -and $existing.sha) {
                    $payloadObj = $payload | ConvertFrom-Json
                    $payloadObj | Add-Member -NotePropertyName "sha" -NotePropertyValue $existing.sha
                    $payload = $payloadObj | ConvertTo-Json
                }

                $resp = Invoke-RestMethod -Uri $url -Headers $Headers -Method Put -Body $payload -ContentType "application/json"
                if ($resp.content.path) {
                    $uploadCount++
                } else {
                    Log ("  ! Failed: $rel") Yellow
                }
            }
            Log ("[2/6] Uploaded {0} files" -f $uploadCount) Green

            # 1.3 Prepare release notes
            Log "[3/6] Preparing release notes ..."
            # 1.4 Create release
            Log "[4/6] Creating v1.0.0 release ..."
            $releaseBody = @"
# ClawHub Daily v1.0.0 - Initial Release

> Daily scan of ClawHub global AI Agent Skill marketplace, multi-dimension curated briefing, auto-push to Feishu / IMA / local.

## Highlights

### Real data, zero fabrication
- Direct ClawHub Convex API call (wry-manatee-359.convex.cloud), fetch Top 200 Skills
- Richer fields than HTML parsing (installs_current, capability_tags, etc.)
- 0 token consumption (no LLM)

### 4-dimension rotation
- D1 trending (hot)
- D2 quality (well-reviewed)
- D3 newcomers (rising stars)
- D4 panorama (community discussion)
- Date % 4 auto-selects, avoids single-dimension monotony

### 7 pain-point library
- Automation / Dev tools / Content / Data scraping / AI augmentation / Chinese / Finance
- Keyword match + weighted scoring

### 10-day dedup
- Local JSON files, 0 database dependency
- 10-day rolling window = 5 cycles to cover 200 Skills
- Resilient: single-file read failure does not break global

### Chinese briefing (zero-token)
- chinese_one_liner auto-assembles
- English original kept in <details> for precision
- 0 token cost, predictable output

### Multi-channel push
- Feishu cloud doc + 200-400 char card message
- IMA knowledge base (CLI primary + HTTP API fallback)
- Local Markdown (default on)

## Security

- Zero hard-coded credentials (config.json or env vars)
- MIT-0 License (ClawHub mandatory)
- .gitignore isolates runtime data and credentials

## Quick start

### ClawHub one-click install
```
clawhub install skill-daily
```

### Manual install
```bash
git clone https://github.com/EdwardWason/clawhub-daily.git
cd clawhub-daily
pip install -r requirements.txt
python clawhub_daily_executor.py
```

## Documentation

- [README](https://github.com/EdwardWason/clawhub-daily#readme) - Quick start
- [SKILL.md](https://github.com/EdwardWason/clawhub-daily/blob/main/SKILL.md) - Skill spec
- [setup-wizard](https://github.com/EdwardWason/clawhub-daily/blob/main/references/setup-wizard.md) - First-install mode choice
- [prompt-templates](https://github.com/EdwardWason/clawhub-daily/blob/main/references/prompt-templates.md) - Cron prompt templates
- [CHANGELOG](https://github.com/EdwardWason/clawhub-daily/blob/main/CHANGELOG.md) - Changelog
- [CONTRIBUTING](https://github.com/EdwardWason/clawhub-daily/blob/main/docs/CONTRIBUTING.md) - Contribution guide
- [PUBLISHING_GUIDE](https://github.com/EdwardWason/clawhub-daily/blob/main/docs/PUBLISHING_GUIDE.md) - Publish guide

## Asset

clawhub-daily-v1.0.0.zip - Full skill pack (excluding .git, data/, .env.local), ready to extract and publish to ClawHub or other platforms.

## License

MIT-0 - clawhub-daily contributors
"@

            $releasePayload = @{
                tag_name         = "v1.0.0"
                target_commitish = "main"
                name             = "v1.0.0 - Initial Release"
                body             = $releaseBody
                draft            = $false
                prerelease       = $false
            } | ConvertTo-Json -Depth 10

            $release = Invoke-RestMethod -Uri "$ApiBase/repos/$Owner/$Repo/releases" -Headers $Headers -Method Post -Body $releasePayload -ContentType "application/json"
            if ($release.id) {
                Log ("[4/6] Release created: {0}" -f $release.html_url) Green

                # 1.5 Upload zip as release asset
                Log "[5/6] Uploading zip asset ..."
                $uploadUrl = $release.upload_url -replace '\{.*\}', ''
                $fileName = "clawhub-daily-v1.0.0.zip"
                $assetUrl = "$uploadUrl?name=$fileName"
                $assetHeaders = @{
                    "Authorization" = "token $GH_TOKEN"
                    "Content-Type"  = "application/zip"
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($ZipPath)
                $null = Invoke-RestMethod -Uri $assetUrl -Method Post -Headers $assetHeaders -Body $fileBytes
                Log ("[5/6] Zip uploaded as asset: {0} ({1:N0} bytes)" -f $fileName, $fileBytes.Length) Green

                Log ("[6/6] GitHub publish complete: {0}" -f $release.html_url) Green
            } else {
                Log ("[4/6] Release create failed: {0}" -f ($release.message -join ", ")) Red
                $ghOk = $false
            }
        }
    }
} else {
    Log "[SKIP] GitHub (-SkipGitHub)" Yellow
}

# ============================================================
# STEP 3: Publish to ClawHub
# ============================================================
$chOk = $true
if (-not $SkipClawHub) {
    Log "`n========== 2. Publish to ClawHub ==========" Cyan

    if ([string]::IsNullOrWhiteSpace($CLAWHUB_TOKEN)) {
        Log "[ERROR] CLAWHUB_TOKEN not configured" Red
        $chOk = $false
    } elseif (-not (Get-Command clawhub -ErrorAction SilentlyContinue)) {
        Log "[ERROR] clawhub CLI not installed (npm i -g clawhub)" Red
        $chOk = $false
    } else {
        # 2.1 Verify identity (no need to re-login; whoami validates stored creds)
        Log "[1/4] Verifying identity ..."
        $whoami = clawhub whoami 2>&1
        Log "  $whoami"
        if ($LASTEXITCODE -ne 0) {
            # If not logged in, do login
            Log "[1/4] Not logged in, attempting login ..."
            $loginResult = clawhub login --token $CLAWHUB_TOKEN --no-browser 2>&1
            Log "  $loginResult"
        }

        # 2.2 Version (hardcoded; plugin.json may have encoding issues)
        $Version = "1.0.0"
        Log ("[2/4] Using version: {0}" -f $Version)

        # 2.3 Publish (with --slug to override protected namespace)
        Log "[3/4] Publishing skill v$Version ..."
        $pubResult = clawhub publish . --slug "skill-daily" --version $Version 2>&1
        Log "  $pubResult"

        # 2.4 Done
        if ($LASTEXITCODE -eq 0) {
            Log "[4/4] ClawHub publish complete" Green
        } else {
            Log ("[4/4] ClawHub publish failed (exit={0})" -f $LASTEXITCODE) Red
            $chOk = $false
        }
    }
} else {
    Log "[SKIP] ClawHub (-SkipClawHub)" Yellow
}

# ============================================================
# STEP 4: Cleanup
# ============================================================
Log "`n========== 3. Cleanup ==========" Cyan
if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
    Log "[CLEAN] Removed $ZipPath"
}

# ============================================================
# SUMMARY
# ============================================================
Log "`n========== SUMMARY ==========" Cyan
if ($ghOk) { Log "GitHub:   OK  https://github.com/$Owner/$Repo/releases/tag/v1.0.0" Green }
else { Log "GitHub:   FAILED" Red }
if ($chOk) { Log "ClawHub:  OK" Green }
else { Log "ClawHub:  FAILED" Red }
Log "Log:      $LogFile"

if ($ghOk -and $chOk) { exit 0 } else { exit 1 }
