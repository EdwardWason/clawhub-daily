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
# STEP 1: Build zip (excluding sensitive/runtime files)
# ============================================================
Log "`n========== 0. Build skill zip ==========" Cyan

$ZipPath = Join-Path $SkillDir "clawhub-daily-v1.0.1.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

# IMPORTANT: keep this list comprehensive.  Anything here MUST NOT be in the public release.
# - Directories: source control, runtime data, build artifacts, IDE/cache, venv
# - Files: env/credential files, logs (any extension), pyc, debug/temp scripts starting with _
$excludeDirs  = @(".git", "data", "__pycache__", ".venv", "node_modules", "logs", ".idea", ".vscode", "dist", "build")
$excludeFiles = @(".env", ".env.local", ".env.*", "*.log", "*.pyc", "*.tmp", "*.bak", "*.swp", "_*.ps1", "_*.sh", "_*.py", "_*.md")

function Should-Exclude($relPath) {
    if (-not $relPath) { return $true }
    # Normalize to forward slashes for consistent matching
    $norm = $relPath -replace "\\", "/"
    foreach ($d in $excludeDirs) {
        # Match: at start (".git/..."), or anywhere with slashes ("/data/...")
        if ($norm -eq $d) { return $true }
        if ($norm.StartsWith($d + "/")) { return $true }
        if ($norm.Contains("/" + $d + "/")) { return $true }
    }
    foreach ($f in $excludeFiles) {
        # Direct match (exact filename) or wildcard match against basename
        $base = Split-Path $norm -Leaf
        if ($f -notmatch '[\*\?\[]') {
            # Literal pattern
            if ($base -eq $f) { return $true }
        } else {
            # Wildcard pattern
            if ($base -like $f) { return $true }
        }
    }
    return $false
}

# Debug-only list of files that WILL be included
$includeLog = @()

$filesToZip = @()
Get-ChildItem -Path $SkillDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($SkillDir.Length + 1)
    if (-not (Should-Exclude $rel)) {
        $filesToZip += $_
        $includeLog += ("  + {0}  ({1} bytes)" -f $rel, $_.Length)
    }
}

Log ("[ZIP] Including {0} files:" -f $filesToZip.Count)
foreach ($line in $includeLog) { Log $line }
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Use TEMP path to avoid Git/AV file-locking on $SkillDir
$tmpDirName = "clawhub_zip_" + [Guid]::NewGuid().ToString("N")
$tmpZipDir = Join-Path $env:TEMP $tmpDirName
New-Item -ItemType Directory -Path $tmpZipDir -Force | Out-Null
$tmpZip = Join-Path $tmpZipDir "clawhub-daily-v1.0.1.zip"
if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }

# CreateFromDirectory with retry (Windows file lock is intermittent)
$maxRetries = 5
$retryDelay = 2
$created = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SkillDir, $tmpZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $created = $true
        break
    } catch {
        Log ("[ZIP] CreateFromDirectory attempt {0}/{1} failed: {2}" -f $i, $maxRetries, $_.Exception.Message) Yellow
        Start-Sleep -Seconds $retryDelay
    }
}
if (-not $created) {
    Log "[ZIP] FATAL: could not create zip after $maxRetries attempts" Red
    exit 1
}

# Remove excluded entries from zip
$zip = [System.IO.Compression.ZipFile]::Open($tmpZip, "Update")
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

# Move final zip to SkillDir (so the GitHub upload step can read it)
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Move-Item $tmpZip $ZipPath -Force
Remove-Item $tmpZipDir -Recurse -Force -ErrorAction SilentlyContinue

# Sanity: verify zip has the expected number of entries
$verifyZip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
$zipEntryCount = $verifyZip.Entries.Count
$verifyZip.Dispose()
$zipSize = (Get-Item $ZipPath).Length
Log ("[ZIP] Created: {0} ({1:N0} bytes, {2} entries)" -f $ZipPath, $zipSize, $zipEntryCount) Green
if ($zipEntryCount -ne $filesToZip.Count) {
    Log ("[ZIP] WARNING: expected {0} entries but got {1}!" -f $filesToZip.Count, $zipEntryCount) Red
}

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

        # 1.1 Check or create repo (use try/catch for proper 404 detection)
        Log "[1/6] Checking repo $Owner/$Repo ..."
        $repoExists = $false
        try {
            $repoCheck = Invoke-RestMethod -Uri "$ApiBase/repos/$Owner/$Repo" -Headers $Headers -Method Get
            if ($repoCheck.html_url) { $repoExists = $true }
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -ne 404) {
                Log ("[1/6] Repo check error: {0} {1}" -f $code, $_.Exception.Message) Red
                $ghOk = $false
            }
        }

        if ($repoExists) {
            Log ("[1/6] Repo exists: {0}" -f $repoCheck.html_url) Green
        } elseif ($ghOk) {
            Log "[1/6] Repo not found, creating ..." Yellow
            $body = @{
                name        = $Repo
                description = "Daily ClawHub Skill briefing - 4-dimension rotation, 7 pain-points, 10-day dedup"
                private     = $false
                license     = "MIT-0"
            } | ConvertTo-Json
            try {
                $resp = Invoke-RestMethod -Uri "$ApiBase/user/repos" -Headers $Headers -Method Post -Body $body -ContentType "application/json"
                if ($resp.html_url) {
                    Log ("[1/6] Repo created: {0}" -f $resp.html_url) Green
                } else {
                    Log ("[1/6] Repo create returned no html_url") Red
                    $ghOk = $false
                }
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($code -eq 422) {
                    # 422 = name exists (race condition: another run created it)
                    Log "[1/6] Repo already exists (422), continuing ..." Yellow
                } else {
                    $bodyText = ""
                    try {
                        $s = $_.Exception.Response.GetResponseStream()
                        $rd = New-Object System.IO.StreamReader($s)
                        $bodyText = $rd.ReadToEnd()
                    } catch {}
                    Log ("[1/6] Repo create failed: {0} {1}" -f $code, $bodyText) Red
                    $ghOk = $false
                }
            }
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
            Log "[4/6] Creating v1.0.1 release ..."
            $releaseBody = @"
# ClawHub Daily v1.0.1 - Security Fix

> **v1.0.0 was withdrawn** because the published zip accidentally included a debug script containing a credential string. **v1.0.1 is the safe release.**

## What changed from v1.0.0

- **Removed** debug scripts and local run logs from the published zip
- **Hardened** zip exclude list to cover all sensitive/runtime files
- **No** changes to skill behavior, scan logic, or push channels

## What you need to do

1. **Revoke** any GitHub PAT that you may have shared with the author (if you downloaded v1.0.0 zip)
2. **Delete** any local copies of v1.0.0 zip
3. **Use** v1.0.1 zip below

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

## Naming note

- **GitHub repo**: `clawhub-daily` (EdwardWason/clawhub-daily)
- **ClawHub slug**: `skill-daily` (ClawHub protects `clawhub-` namespace; slug is locked once published)
- Both names refer to the same skill.

## License

MIT-0 - clawhub-daily contributors
"@

            $releasePayload = @{
                tag_name         = "v1.0.1"
                target_commitish = "main"
                name             = "v1.0.1 - Security Fix (withdraws v1.0.0)"
                body             = $releaseBody
                draft            = $false
                prerelease       = $false
            } | ConvertTo-Json -Depth 10

            $release = Invoke-RestMethod -Uri "$ApiBase/repos/$Owner/$Repo/releases" -Headers $Headers -Method Post -Body $releasePayload -ContentType "application/json"
            if ($release.id) {
                Log ("[4/6] Release created: {0}" -f $release.html_url) Green

                # 1.5 Upload zip as release asset
                Log "[5/6] Uploading zip asset ..."
                # upload_url is "https://uploads.github.com/.../assets{?name,label}" - strip {...}
                $uploadUrl = $release.upload_url
                $braceIdx = $uploadUrl.IndexOf('{')
                if ($braceIdx -gt 0) { $uploadUrl = $uploadUrl.Substring(0, $braceIdx) }
                $fileName = "clawhub-daily-v1.0.1.zip"
                $assetUrl = $uploadUrl + "?name=" + $fileName
                $assetHeaders = @{
                    "Authorization" = "token $GH_TOKEN"
                    "Content-Type"  = "application/zip"
                    "Accept"        = "application/vnd.github.v3+json"
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($ZipPath)
                $null = Invoke-RestMethod -Uri $assetUrl -Method Post -Headers $assetHeaders -Body $fileBytes -TimeoutSec 60
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
        $Version = "1.0.1"
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
if ($ghOk) { Log "GitHub:   OK  https://github.com/$Owner/$Repo/releases/tag/v1.0.1" Green }
else { Log "GitHub:   FAILED" Red }
if ($chOk) { Log "ClawHub:  OK" Green }
else { Log "ClawHub:  FAILED" Red }
Log "Log:      $LogFile"

if ($ghOk -and $chOk) { exit 0 } else { exit 1 }
