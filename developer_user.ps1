<#
.SYNOPSIS
    Config-Driven & Recursive Submodule Workspace Manager (PowerShell)

.DESCRIPTION
    - Reads master repo and submodule version targets from developer_config.json.
    - Recursively initializes and syncs all submodules, including nested submodules.
    - Generates a comprehensive RELEASE_NOTES.md traceability manifest.
    - Sets up the workspace and auto-deploys "Open MATLAB.bat" and path automation.

.EXAMPLE
    .\developer_user.ps1 -Action setup
    .\developer_user.ps1 -Action status
    .\developer_user.ps1 -Action shift-release -Target all
#>

[CmdletBinding()]
param (
    # Action to perform: setup, update, status, shift-release
    [ValidateSet("setup", "update", "status", "shift-release")]
    [string]$Action = "setup",

    # Path to external configuration file (JSON)
    [string]$ConfigFile = "developer_config.json",

    # Master repository URL (overrides config file if specified)
    [string]$MasterRepoUrl = "",

    # Master repository branch, tag, or commit (overrides config file if specified)
    [string]$MasterVersion = "",

    # Target local workspace directory (overrides default ./<repo_name>)
    [string]$WorkspaceDir = "",

    # Target artifact when running shift-release
    [string]$Target = "all"
)

function Write-Info    { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success { param([string]$msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn    { param([string]$msg) Write-Warning "[WARN] $msg" }
function Write-Err     { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Header  { param([string]$msg) Write-Host $msg -ForegroundColor Magenta }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err "Git is not installed or not available in system PATH."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==============================================================================
# CONFIG FILE LOADER (developer_config.json)
# ==============================================================================
$SubmoduleOverrides = @{}

$ResolvedConfigPath = ""
if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
    if (Test-Path $ConfigFile) { $ResolvedConfigPath = $ConfigFile }
} else {
    $candidate = Join-Path $ScriptDir $ConfigFile
    if (Test-Path $candidate) { $ResolvedConfigPath = $candidate }
    elseif (Test-Path $ConfigFile) { $ResolvedConfigPath = (Resolve-Path $ConfigFile).Path }
}

if (-not [string]::IsNullOrWhiteSpace($ResolvedConfigPath)) {
    Write-Info "Loading configuration from: $ResolvedConfigPath"
    try {
        $ConfigData = Get-Content $ResolvedConfigPath -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($MasterRepoUrl) -and $ConfigData.master_repo.url) {
            $MasterRepoUrl = $ConfigData.master_repo.url
        }
        if ([string]::IsNullOrWhiteSpace($MasterVersion) -and $ConfigData.master_repo.version) {
            $MasterVersion = $ConfigData.master_repo.version
        }
        if ([string]::IsNullOrWhiteSpace($WorkspaceDir) -and $ConfigData.workspace_dir) {
            $WorkspaceDir = $ConfigData.workspace_dir
        }
        if ($ConfigData.submodules) {
            foreach ($prop in $ConfigData.submodules.PSObject.Properties) {
                $SubmoduleOverrides[$prop.Name] = $prop.Value
            }
        }
    } catch {
        Write-Warn "Could not parse JSON configuration file: $_"
    }
}

if ([string]::IsNullOrWhiteSpace($MasterVersion)) { $MasterVersion = "main" }

if ([string]::IsNullOrWhiteSpace($MasterRepoUrl)) {
    $currentGitRemote = (git rev-parse --is-inside-work-tree 2>$null)
    if ($currentGitRemote -eq "true") {
        $MasterRepoUrl = (git remote get-url origin 2>$null)
        Write-Info "Auto-detected Git remote URL: $MasterRepoUrl"
    }
}

if ([string]::IsNullOrWhiteSpace($MasterRepoUrl)) {
    $MasterRepoUrl = "https://github.com/your-org/COE_AKC_FullSystem.git"
    Write-Warn "No repository URL supplied. Using default: $MasterRepoUrl"
}

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension($MasterRepoUrl)
    $WorkspaceDir = Join-Path $ScriptDir $repoName
} elseif (-not [System.IO.Path]::IsPathRooted($WorkspaceDir)) {
    $WorkspaceDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $WorkspaceDir))
}

$ProjectName = Split-Path -Leaf $WorkspaceDir

# ==============================================================================
# RECURSIVE SUBMODULE DISCOVERY
# ==============================================================================
function Get-RecursiveSubmodules {
    param([string]$targetPath)
    $subs = @()

    $gitDir = Join-Path $targetPath ".git"
    if (-not (Test-Path $gitDir)) { return $subs }

    $statusOutput = (git -C $targetPath submodule status --recursive 2>$null)
    if ($statusOutput) {
        foreach ($line in $statusOutput) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $parts = $line.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
                if ($parts.Count -ge 2) {
                    $subPath = $parts[1]
                    $subs += $subPath
                }
            }
        }
    }

    if ($subs.Count -eq 0) {
        $dirs = Get-ChildItem -Path $targetPath -Directory
        foreach ($d in $dirs) {
            $subGit = Join-Path $d.FullName ".git"
            if (Test-Path $subGit) { $subs += $d.Name }
        }
    }

    return ($subs | Select-Object -Unique)
}

# ==============================================================================
# MANIFEST GENERATOR: RELEASE_NOTES.md
# ==============================================================================
function New-ReleaseNotes {
    param([string]$targetPath)
    $manifestFile = Join-Path $targetPath "RELEASE_NOTES.md"
    $currentDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $masterSha = (git -C $targetPath rev-parse HEAD 2>$null).Trim()
    $masterShortSha = if ($masterSha.Length -ge 8) { $masterSha.Substring(0, 8) } else { $masterSha }
    $masterBranch = (git -C $targetPath rev-parse --abbrev-ref HEAD 2>$null).Trim()
    $masterTag = (git -C $targetPath describe --tags --exact-match 2>$null)
    if ([string]::IsNullOrWhiteSpace($masterTag)) { $masterTag = "None" }
    $masterMsg = (git -C $targetPath log -1 --pretty=format:"%s" 2>$null) -replace '\|', '-'
    $masterAuthor = (git -C $targetPath log -1 --pretty=format:"%an (%ad)" --date=short 2>$null)

    $allSubs = Get-RecursiveSubmodules $targetPath

    $md = @"
# Release & Workspace Traceability Notes

> **Generated Date:** $currentDate  
> **Workspace Path:** ``$targetPath``  

---

## 1. Master Repository

| Property | Value |
| :--- | :--- |
| **Project Name** | **$ProjectName** |
| **Repository URL** | ``$MasterRepoUrl`` |
| **Target Requested Version** | ``$MasterVersion`` |
| **Active Branch / Ref** | ``$masterBranch`` |
| **Active Tag** | ``$masterTag`` |
| **Commit SHA** | ``$masterShortSha`` (``$masterSha``) |
| **Latest Commit Note** | $masterMsg |
| **Author & Date** | $masterAuthor |

---

## 2. Submodules & Nested Submodules Hierarchy

"@

    if ($allSubs.Count -eq 0) {
        $md += "`n*No submodules detected in this repository.*`n"
    } else {
        $md += @"
| Level | Submodule Path | Target Config | Active Commit | Tag / Branch Ref | Latest Commit Message |
| :---: | :--- | :---: | :---: | :--- | :--- |
"@
        foreach ($subRel in $allSubs) {
            $subFull = Join-Path $targetPath $subRel
            $slashCount = ($subRel.ToCharArray() | Where-Object { $_ -eq '/' -or $_ -eq '\' }).Count
            $level = "L$($slashCount + 1)"
            $displayName = $subRel
            if ($slashCount -gt 0) {
                $indent = "  " * $slashCount
                $leaf = Split-Path -Leaf $subRel
                $displayName = "$indent+-- $leaf"
            }

            $leafName = Split-Path -Leaf $subRel
            $subTarget = if ($SubmoduleOverrides.ContainsKey($subRel)) { $SubmoduleOverrides[$subRel] } elseif ($SubmoduleOverrides.ContainsKey($leafName)) { $SubmoduleOverrides[$leafName] } else { "PINNED" }

            $subSha = "N/A"
            $subShortSha = "N/A"
            $subRef = "N/A"
            $subMsg = "N/A"

            if (Test-Path $subFull) {
                $rawSha = (git -C $subFull rev-parse HEAD 2>$null)
                if ($rawSha) {
                    $subSha = $rawSha.Trim()
                    $subShortSha = if ($subSha.Length -ge 8) { $subSha.Substring(0, 8) } else { $subSha }
                }
                $exactTag = (git -C $subFull describe --tags --exact-match 2>$null)
                $curBranch = (git -C $subFull rev-parse --abbrev-ref HEAD 2>$null)
                if (-not [string]::IsNullOrWhiteSpace($exactTag)) {
                    $subRef = "Tag: ``$exactTag``"
                } elseif (-not [string]::IsNullOrWhiteSpace($curBranch) -and $curBranch -ne "HEAD") {
                    $subRef = "Branch: ``$curBranch``"
                } else {
                    $subRef = "Detached HEAD"
                }
                $rawMsg = (git -C $subFull log -1 --pretty=format:"%s" 2>$null)
                if ($rawMsg) { $subMsg = $rawMsg -replace '\|', '-' }
            }

            $md += "`n| **$level** | ``$displayName`` | ``$subTarget`` | ``$subShortSha`` | $subRef | $subMsg |"
        }
    }

    $md += @"


---

## 3. Submodule Tree View

````text
$ProjectName ($masterBranch @ $masterShortSha)
"@
    foreach ($subRel in $allSubs) {
        $subFull = Join-Path $targetPath $subRel
        $subSha = "N/A"
        $subRef = ""
        if (Test-Path $subFull) {
            $rawSha = (git -C $subFull rev-parse --short HEAD 2>$null)
            if ($rawSha) { $subSha = $rawSha.Trim() }
            $tag = (git -C $subFull describe --tags --exact-match 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($tag)) {
                $subRef = "($tag @ $subSha)"
            } else {
                $subRef = "(@ $subSha)"
            }
        }
        $slashCount = ($subRel.ToCharArray() | Where-Object { $_ -eq '/' -or $_ -eq '\' }).Count
        $indent = "    " * $slashCount
        $md += "`n$indent+-- $subRel $subRef"
    }

    $md += @"

````

---

## 4. How to Start Working
1. Launch MATLAB via **\`Open MATLAB.bat\`** in the repository root.
2. \`startup.m\` will automatically discover and link all primary and nested submodule directories.
"@

    Set-Content -Path $manifestFile -Value $md -Encoding Utf8
    Write-Info "Traceability manifest written to: $manifestFile"
}

# ==============================================================================
# ACTION: STATUS
# ==============================================================================
function Show-Status {
    Write-Header "=================================================================="
    Write-Header "  Repository & Submodule Hierarchy: $ProjectName (PowerShell)"
    Write-Header "=================================================================="

    if (-not (Test-Path $WorkspaceDir)) {
        Write-Warn "Workspace directory does not exist yet at: $WorkspaceDir"
        return
    }

    $masterBranch = (git -C $WorkspaceDir rev-parse --abbrev-ref HEAD 2>$null)
    $masterHash = (git -C $WorkspaceDir rev-parse --short HEAD 2>$null)
    $masterTag = (git -C $WorkspaceDir describe --tags --exact-match 2>$null)
    Write-Host "Master Repo : $ProjectName [Branch: $masterBranch | Tag: $(if($masterTag){$masterTag}else{'None'}) | SHA: $masterHash]" -ForegroundColor Green

    Write-Host ""
    Write-Info "Submodules & Nested Submodules (Discovered recursively):"
    $allSubs = Get-RecursiveSubmodules $WorkspaceDir

    if ($allSubs.Count -eq 0) {
        Write-Host "  (No submodules configured)"
    } else {
        foreach ($subRel in $allSubs) {
            $subFull = Join-Path $WorkspaceDir $subRel
            $slashCount = ($subRel.ToCharArray() | Where-Object { $_ -eq '/' -or $_ -eq '\' }).Count
            $level = "L$($slashCount + 1)"
            $prefix = "  [$level] "
            if ($slashCount -gt 0) {
                $prefix = ("  " * $slashCount) + "+-- [$level] "
            }

            $leafName = Split-Path -Leaf $subRel
            $cfgTarget = if ($SubmoduleOverrides.ContainsKey($subRel)) { $SubmoduleOverrides[$subRel] } elseif ($SubmoduleOverrides.ContainsKey($leafName)) { $SubmoduleOverrides[$leafName] } else { "PINNED" }

            if (Test-Path $subFull) {
                $subHash = (git -C $subFull rev-parse --short HEAD 2>$null)
                $subBranch = (git -C $subFull rev-parse --abbrev-ref HEAD 2>$null)
                $subTag = (git -C $subFull describe --tags --exact-match 2>$null)
                Write-Host "${prefix}${subRel} : Target: $cfgTarget | Active: $subHash (Tag: $(if($subTag){$subTag}else{'None'}), Ref: $subBranch)" -ForegroundColor Yellow
            } else {
                Write-Host "${prefix}${subRel} : Target: $cfgTarget | NOT INITIALIZED" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    $relNotesPath = Join-Path $WorkspaceDir "RELEASE_NOTES.md"
    if (Test-Path $relNotesPath) {
        Write-Info "Traceability document: $relNotesPath"
    }
    Write-Header "=================================================================="
}

# ==============================================================================
# ACTION: SETUP / UPDATE
# ==============================================================================
function Invoke-Setup {
    Write-Header "=================================================================="
    Write-Header "  Config-Driven Workspace Setup: $ProjectName"
    Write-Header "=================================================================="
    Write-Info "Master Repo    : $MasterRepoUrl"
    Write-Info "Master Version : $MasterVersion"
    Write-Info "Workspace Path : $WorkspaceDir"
    Write-Header "------------------------------------------------------------------"

    # 1. Clone or sync master repository
    if (-not (Test-Path $WorkspaceDir)) {
        Write-Info "Cloning master repository..."
        git -c protocol.file.allow=always clone $MasterRepoUrl $WorkspaceDir
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone repository." }
    } else {
        $gitDir = Join-Path $WorkspaceDir ".git"
        if (-not (Test-Path $gitDir)) {
            Write-Err "Target folder exists but is not a Git repository: $WorkspaceDir"
            exit 1
        }
        Write-Info "Workspace folder already exists. Fetching updates..."
        git -C $WorkspaceDir fetch --all --tags --prune
    }

    # 2. Checkout requested Master version
    Write-Info "Checking out master version: $MasterVersion..."
    git -C $WorkspaceDir checkout $MasterVersion 2>$null
    if ($LASTEXITCODE -ne 0) {
        git -C $WorkspaceDir checkout -b $MasterVersion "origin/$MasterVersion" 2>$null
    }
    git -C $WorkspaceDir pull origin $MasterVersion 2>$null

    $currentSha = (git -C $WorkspaceDir rev-parse --short HEAD).Trim()
    Write-Success "Master checked out at commit: $currentSha"

    # 3. Initialize and update ALL submodules RECURSIVELY
    Write-Info "Initializing all submodules and nested submodules recursively..."
    git -C $WorkspaceDir -c protocol.file.allow=always submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Failed to update submodules." }

    # 4. Apply version targets to submodules
    $allSubs = Get-RecursiveSubmodules $WorkspaceDir
    foreach ($subRel in $allSubs) {
        $subFull = Join-Path $WorkspaceDir $subRel
        if (-not (Test-Path $subFull)) { continue }

        $leafName = Split-Path -Leaf $subRel
        $targetVer = if ($SubmoduleOverrides.ContainsKey($subRel)) { $SubmoduleOverrides[$subRel] } elseif ($SubmoduleOverrides.ContainsKey($leafName)) { $SubmoduleOverrides[$leafName] } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($targetVer) -and $targetVer -ne "PINNED") {
            Write-Info "Switching submodule '$subRel' to configured target: $targetVer..."
            git -C $subFull fetch --all --tags --prune
            git -C $subFull checkout $targetVer 2>$null
        }

        $subSha = (git -C $subFull rev-parse --short HEAD 2>$null)
        Write-Success "Submodule '$subRel' active at: $subSha"
    }

    # 5. Setup development/ folder
    $devDir = Join-Path $WorkspaceDir "development"
    if (-not (Test-Path $devDir)) {
        New-Item -ItemType Directory -Force -Path $devDir | Out-Null
    }

    foreach ($sf in @("Validation", "Tools", "Docu", "CommonFiles")) {
        $targetSf = Join-Path $devDir $sf
        if (-not (Test-Path $targetSf)) {
            New-Item -ItemType Directory -Force -Path $targetSf | Out-Null
        }
    }

    # 6. Deploy MATLAB environment files and "Open MATLAB.bat"
    Write-Info "Deploying MATLAB environment files and launchers..."
    $filesToDeploy = @(
        "setup_project_paths.m",
        "startup.m",
        "clean_project_paths.m",
        "shift_to_release.m",
        "Open MATLAB.bat"
    )

    foreach ($f in $filesToDeploy) {
        $srcFile = Join-Path $ScriptDir $f
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $WorkspaceDir $f) -Force
            if ($f.EndsWith(".m")) {
                Copy-Item -Path $srcFile -Destination (Join-Path $devDir $f) -Force
            }
            Write-Info "  - Deployed: $f"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedConfigPath) -and (Test-Path $ResolvedConfigPath)) {
        Copy-Item -Path $ResolvedConfigPath -Destination (Join-Path $WorkspaceDir "developer_config.json") -Force
        Write-Info "  - Deployed: developer_config.json"
    }

    # 7. Generate RELEASE_NOTES.md
    New-ReleaseNotes $WorkspaceDir

    # 8. Console summary
    Write-Host ""
    Write-Header "=================================================================="
    Write-Header "  WORKSPACE READY: $ProjectName"
    Write-Header "=================================================================="
    Write-Success "Master Repository : $ProjectName ($MasterVersion @ $currentSha)"
    Write-Host ""
    Write-Info "Submodule Hierarchy & Checked-Out Versions:"
    foreach ($subRel in $allSubs) {
        $subFull = Join-Path $WorkspaceDir $subRel
        $slashCount = ($subRel.ToCharArray() | Where-Object { $_ -eq '/' -or $_ -eq '\' }).Count
        $level = "L$($slashCount + 1)"
        $prefix = "  [$level] "
        if ($slashCount -gt 0) { $prefix = ("  " * $slashCount) + "+-- [$level] " }

        $subHash = (git -C $subFull rev-parse --short HEAD 2>$null)
        $subTag = (git -C $subFull describe --tags --exact-match 2>$null)
        $subRef = if ($subTag) { "Tag: $subTag" } else { (git -C $subFull rev-parse --abbrev-ref HEAD 2>$null) }
        Write-Host "${prefix}${subRel} : Commit $subHash [$subRef]" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Success "Detailed traceability manifest saved to: RELEASE_NOTES.md"
    Write-Info "To start working in MATLAB:"
    Write-Info "  - Double-click 'Open MATLAB.bat' in the repository root"
    Write-Header "=================================================================="
}

# ==============================================================================
# ACTION: SHIFT TO RELEASE
# ==============================================================================
function Invoke-ShiftRelease {
    Write-Header "=================================================================="
    Write-Header "  Project: $ProjectName - Shift Artifacts to Release"
    Write-Header "=================================================================="

    $devDir = Join-Path $WorkspaceDir "development"
    $relDir = Join-Path $WorkspaceDir "release"

    if (-not (Test-Path $devDir)) {
        Write-Err "Development directory not found at: $devDir"
        exit 1
    }

    if (-not (Test-Path $relDir)) {
        New-Item -ItemType Directory -Force -Path $relDir | Out-Null
    }

    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $backupDir = Join-Path $relDir ".backup_$timestamp"

    $filesToShift = @()
    if ($Target -eq "all") {
        $models = Get-ChildItem -Path $devDir -Include "*.slx", "*.mdl" -File -Recurse:$false
        $mFiles = Get-ChildItem -Path $devDir -Filter "MAIN_*.m" -File
        $filesToShift += $models.Name
        $filesToShift += $mFiles.Name
    } else {
        $filesToShift += $Target
    }

    if ($filesToShift.Count -eq 0) {
        Write-Warn "No artifacts matching '$Target' found in $devDir."
        return
    }

    $backedUp = $false
    foreach ($item in $filesToShift) {
        $existingRel = Join-Path $relDir $item
        if (Test-Path $existingRel) {
            if (-not $backedUp) {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $backedUp = $true
            }
            Copy-Item -Path $existingRel -Destination (Join-Path $backupDir $item) -Force
            Write-Info "Backed up existing release/$item -> $backupDir/"
        }
    }

    $copiedCount = 0
    foreach ($item in $filesToShift) {
        $srcPath = Join-Path $devDir $item
        $destPath = Join-Path $relDir $item
        if (Test-Path $srcPath) {
            Copy-Item -Path $srcPath -Destination $destPath -Force
            Write-Success "Promoted: $item -> release/$item"
            $copiedCount++
        }
    }

    $changelogs = Get-ChildItem -Path $WorkspaceDir -Filter "ChangeLog*.md"
    if ($changelogs.Count -gt 0) {
        $changelogFile = $changelogs[0].FullName
    } else {
        $changelogFile = Join-Path $WorkspaceDir "ChangeLog_Release.md"
    }

    $currentDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = @"

## Promotion to Release ($currentDate)
- **Promoted Artifacts:** $($filesToShift -join ', ')
- **Status:** Promoted from development/ to release/
- **Backup Created:** $backupDir
"@
    Add-Content -Path $changelogFile -Value $logEntry -Encoding Utf8
    Write-Info "Logged promotion in: $changelogFile"
    Write-Success "Shift to release completed ($copiedCount artifact(s) promoted)."
    Write-Header "=================================================================="
}

# ==============================================================================
# MAIN ROUTER
# ==============================================================================
switch ($Action) {
    "setup"         { Invoke-Setup }
    "update"        { Invoke-Setup }
    "status"        { Show-Status }
    "shift-release" { Invoke-ShiftRelease }
}
