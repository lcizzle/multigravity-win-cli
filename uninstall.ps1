$ErrorActionPreference = "Stop"

function Get-CanonicalUserProfile {
    if ($env:MULTIGRAVITY_ROOT_USERPROFILE -and (Test-Path $env:MULTIGRAVITY_ROOT_USERPROFILE)) {
        return $env:MULTIGRAVITY_ROOT_USERPROFILE
    }
    try {
        $regDesktop = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -Name "Desktop" -ErrorAction Stop).Desktop
        if ($regDesktop) {
            $parent = Split-Path $regDesktop -Parent
            if (Test-Path $parent) { return $parent }
        }
    } catch {}
    if ($env:USERPROFILE -match '^(.*?)[\\/]\.config[\\/]multigravity[\\/]profiles') {
        return $Matches[1]
    }
    return [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
}

$ROOT_USERPROFILE = Get-CanonicalUserProfile
$INSTALL_DIR = "$ROOT_USERPROFILE\.local\bin"

function Write-Step ($message) {
    Write-Host "  -> $message"
}

Write-Host "Uninstalling Multigravity..."
Write-Host ""

$removed = 0

# ── binary + wrapper ──────────────────────────────────────────────────────────
foreach ($file in @("multigravity.ps1", "multigravity.cmd")) {
    $path = "$INSTALL_DIR\$file"
    if (Test-Path $path) {
        Write-Step "Removing $path"
        Remove-Item -Force $path
        $removed++
    }
}

# ── Start Menu shortcuts ──────────────────────────────────────────────────────
$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$shortcuts = Get-ChildItem -Path $startMenu -Filter "Multigravity *.lnk" -ErrorAction SilentlyContinue
foreach ($s in $shortcuts) {
    Write-Step "Removing shortcut: $($s.FullName)"
    Remove-Item -Force $s.FullName
}

# ── PATH cleanup ──────────────────────────────────────────────────────────────
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath -and $userPath -like "*$INSTALL_DIR*") {
    $cleaned = ($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $INSTALL_DIR.TrimEnd('\') }) -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $cleaned, "User")
    Write-Step "Removed $INSTALL_DIR from user PATH"
}

# ── profile data (opt-in) ─────────────────────────────────────────────────────
$profileBase = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$ROOT_USERPROFILE\.config\multigravity\profiles" }
if (Test-Path $profileBase) {
    Write-Host ""
    $confirm = Read-Host "Remove all profile data at '$profileBase'? [y/N]"
    if ($confirm -match "^[Yy]$") {
        Write-Step "Removing profile data: $profileBase"
        Remove-Item -Recurse -Force $profileBase
    } else {
        Write-Host "  Keeping profile data."
    }
}

Write-Host ""
if ($removed -eq 0) {
    Write-Host "Multigravity files were not found — nothing to remove."
} else {
    Write-Host "✓ Multigravity uninstalled."
}
