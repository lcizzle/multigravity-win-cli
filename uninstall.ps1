$ErrorActionPreference = "Stop"

$INSTALL_DIR = "$env:USERPROFILE\.local\bin"

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
$profileBase = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$env:USERPROFILE\AntigravityProfiles" }
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
