<#
.SYNOPSIS
Automated test suite for multigravity-win-cli.
#>

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$ProjectRoot = Split-Path $ScriptDir -Parent
$MgScript = Join-Path $ProjectRoot "multigravity.ps1"

Write-Host "=================================================="
Write-Host " Running multigravity automated test suite        "
Write-Host " Target script: $MgScript                         "
Write-Host "=================================================="
Write-Host ""

$Passed = 0
$Failed = 0

function Assert-Equal($actual, $expected, $testName) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $testName" -ForegroundColor Red
        Write-Host "         Expected: '$expected'"
        Write-Host "         Actual:   '$actual'"
        $script:Failed++
    }
}

function Assert-True($condition, $testName) {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $testName" -ForegroundColor Red
        $script:Failed++
    }
}

# ── Test Suite 1: Canonical Base & Root Profile Discovery ──
Write-Host "Suite 1: Canonical Base & Root Profile Discovery"

$testRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
$fakeBase = "$testRoot\mg_test_base_$PID"
$env:MULTIGRAVITY_HOME = $fakeBase
$env:MULTIGRAVITY_TEST_CRED_TARGET = "gemini:antigravity_unit_test_$PID"

try {
    . $MgScript -cmd "help" | Out-Null

    Assert-Equal (Get-CanonicalUserProfile) $ROOT_USERPROFILE "Get-CanonicalUserProfile returns root user profile"
    Assert-Equal $BASE $fakeBase "MULTIGRAVITY_HOME correctly overrides BASE"
    Assert-Equal $env:MULTIGRAVITY_HOME $fakeBase "MULTIGRAVITY_HOME is exported to process environment"

    # Test Regex recovery if USERPROFILE is simulated as a subfolder
    $simulatedNested = "C:\Users\TestUser\.config\multigravity\profiles\subagent"
    $regexMatch = if ($simulatedNested -match '^(.*?)[\\/]\.config[\\/]multigravity[\\/]profiles') { $Matches[1] } else { $null }
    Assert-Equal $regexMatch "C:\Users\TestUser" "Nested USERPROFILE correctly parses host root user path"

} finally {
    Remove-Item -Recurse -Force $fakeBase -ErrorAction SilentlyContinue
}

# ── Test Suite 2: Credential Vault DPAPI Export/Import/Restore ──
Write-Host ""
Write-Host "Suite 2: DPAPI Credential Vault & Re-entrancy Stack"

$testBase = "$testRoot\mg_vault_test_$PID"
$env:MULTIGRAVITY_HOME = $testBase
$testCredTarget = "gemini:antigravity_test_vault_$PID"
$env:MULTIGRAVITY_TEST_CRED_TARGET = $testCredTarget

try {
    New-Item -ItemType Directory -Force -Path $testBase | Out-Null

    # Test raw Credential Vault write/read/delete
    $dummyUser = "test_user_$PID"
    $dummyBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("test_token_payload_12345"))
    
    $importOk = [MultigravityCredVault]::ImportCredential($testCredTarget, $dummyUser, $dummyBlob)
    Assert-True $importOk "MultigravityCredVault successfully imported credential"

    $readUser = $null
    $exportedBlob = [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$readUser)
    Assert-True (![string]::IsNullOrEmpty($exportedBlob)) "MultigravityCredVault successfully exported credential"
    Assert-Equal $readUser $dummyUser "Exported username matches imported username"

    $removeOk = [MultigravityCredVault]::RemoveCredential($testCredTarget)
    Assert-True $removeOk "MultigravityCredVault successfully removed credential"

    # Test Profile Credential Lifecycle (Prepare -> Save -> Re-entrant Stack -> Restore)
    $prof1Dir = "$testBase\prof1"
    $prof2Dir = "$testBase\prof2"
    New-Item -ItemType Directory -Force -Path $prof1Dir | Out-Null
    New-Item -ItemType Directory -Force -Path $prof2Dir | Out-Null

    # Save initial credential for prof1
    [MultigravityCredVault]::ImportCredential($testCredTarget, "prof1_user", $dummyBlob) | Out-Null
    Save-CredentialToProfile "prof1" | Out-Null
    Assert-True (Test-Path "$prof1Dir\.credentials.json") "prof1 credential JSON saved"

    # Save different credential for prof2
    $prof2Blob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("prof2_token_99999"))
    [MultigravityCredVault]::ImportCredential($testCredTarget, "prof2_user", $prof2Blob) | Out-Null
    Save-CredentialToProfile "prof2" | Out-Null
    Assert-True (Test-Path "$prof2Dir\.credentials.json") "prof2 credential JSON saved"

    # Simulate Stack Re-entrancy: prof1 starts -> launches prof2 -> prof2 terminates -> restores prof1
    $env:MULTIGRAVITY_PROFILE_STACK = $null
    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null

    # 1. prof1 launches
    Prepare-LaunchCredential "prof1" | Out-Null
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof1" "prof1 is active profile"
    
    # 2. prof2 launched inside prof1
    Prepare-LaunchCredential "prof2" | Out-Null
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof2" "prof2 is now active profile"
    Assert-Equal $env:MULTIGRAVITY_PROFILE_STACK "prof1" "Profile stack holds prof1 as parent"

    # 3. prof2 exits
    Restore-PostLaunchCredential -PROFILE "prof2" -HadSavedCred $true
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof1" "Stack restored prof1 as active profile"
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_PROFILE_STACK)) "Profile stack is now empty"

    # Verify prof1 credentials restored in vault
    $restoredUser = $null
    [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$restoredUser) | Out-Null
    Assert-Equal $restoredUser "prof1_user" "Vault restored to prof1 credentials"

    # 4. prof1 exits
    Restore-PostLaunchCredential -PROFILE "prof1" -HadSavedCred $true
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile cleared after root exit"

    # 5. Verify Credential Pollution Prevention (Pre-existing credentials must NOT be overwritten on exit)
    $prof1BlobBefore = (Get-Content "$prof1Dir\.credentials.json" -Raw | ConvertFrom-Json).blob
    $hadProf1 = Prepare-LaunchCredential "prof1"
    Assert-True $hadProf1 "prof1 launched with pre-existing valid credential"
    # Simulate concurrent profile or restore swapping vault to alien credential
    $alienBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("alien_token_corrupted"))
    [MultigravityCredVault]::ImportCredential($testCredTarget, "alien_user", $alienBlob) | Out-Null
    # When prof1 exits, it must NOT save alien_user over its own credentials
    Restore-PostLaunchCredential -PROFILE "prof1" -HadSavedCred $hadProf1
    $prof1JsonAfter = Get-Content "$prof1Dir\.credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $prof1JsonAfter.userName "prof1_user" "prof1 credentials NOT overwritten on exit"
    Assert-Equal $prof1JsonAfter.blob $prof1BlobBefore "prof1 credential blob preserved intact"
    Assert-True ($prof1JsonAfter.blob -ne $alienBlob) "prof1 credential blob is not corrupted by alien token"

    # 6. Verify Initial Login Save Behavior for Fresh Profile
    $profFreshDir = "$testBase\prof_fresh"
    New-Item -ItemType Directory -Force -Path $profFreshDir | Out-Null
    $hadFresh = Prepare-LaunchCredential "prof_fresh"
    Assert-True (!$hadFresh) "prof_fresh has no credentials initially"
    # Simulate user signing in during session
    $freshBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("fresh_token_12345"))
    [MultigravityCredVault]::ImportCredential($testCredTarget, "fresh_user", $freshBlob) | Out-Null
    # Exit fresh profile - should save initial credential
    Restore-PostLaunchCredential -PROFILE "prof_fresh" -HadSavedCred $hadFresh
    Assert-True (Test-Path "$profFreshDir\.credentials.json") "prof_fresh saved initial credentials on exit"
    $freshJson = Get-Content "$profFreshDir\.credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $freshJson.userName "fresh_user" "prof_fresh saved correct initial username"

    # 7. Verify Global Profile Protection
    Set-Content -Path "$testBase\.global_profile" -Value "prof_global" -Encoding UTF8
    $globalCredData = @{
        userName = "global_user"
        blob     = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("global_token_54321"))
        updated  = (Get-Date).ToString("o")
    } | ConvertTo-Json
    Set-Content -Path "$testBase\.global_credentials.json" -Value $globalCredData -Encoding UTF8
    Assert-True (Test-CredentialFileValid "$testBase\.global_credentials.json") "Global credentials file is valid"
    # Simulate vault swap to alien credential while global was running
    [MultigravityCredVault]::ImportCredential($testCredTarget, "alien_user", $alienBlob) | Out-Null
    # When global profile exits with HadSavedCred = true, it must NOT overwrite .global_credentials.json
    Restore-PostLaunchCredential -PROFILE "prof_global" -HadSavedCred $true
    $globalJsonAfter = Get-Content "$testBase\.global_credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $globalJsonAfter.userName "global_user" "Global credentials NOT overwritten on exit"

} finally {
    [MultigravityCredVault]::RemoveCredential($testCredTarget) | Out-Null
    Remove-Item -Recurse -Force $testBase -ErrorAction SilentlyContinue
}

# ── Test Suite 3: Shared Profile SQLite WAL/SHM Exclusions ──
Write-Host ""
Write-Host "Suite 3: Shared Profile Exclusion Patterns"

$testExclusionPatterns = @("state.vscdb*", "storage.json*", "secrets.json*", "lockfile*")
$testFiles = @(
    @{ name = "state.vscdb"; expectExcluded = $true },
    @{ name = "state.vscdb-wal"; expectExcluded = $true },
    @{ name = "state.vscdb-shm"; expectExcluded = $true },
    @{ name = "state.vscdb.backup"; expectExcluded = $true },
    @{ name = "storage.json"; expectExcluded = $true },
    @{ name = "secrets.json"; expectExcluded = $true },
    @{ name = "lockfile"; expectExcluded = $true },
    @{ name = "extension_config.json"; expectExcluded = $false },
    @{ name = "custom_tool_cache"; expectExcluded = $false }
)

foreach ($tf in $testFiles) {
    $isEx = $false
    foreach ($pat in $testExclusionPatterns) {
        if ($tf.name -like $pat) { $isEx = $true; break }
    }
    Assert-Equal $isEx $tf.expectExcluded "File '$($tf.name)' exclusion matching is $($tf.expectExcluded)"
}

# ── Test Suite 4: Environment Inheritance in Shared vs Full Profiles ──
Write-Host ""
Write-Host "Suite 4: Profile Topology and Native Environment Rules"

$sharedBase = "$testRoot\mg_shared_test_$PID"
$env:MULTIGRAVITY_HOME = $sharedBase

try {
    New-Item -ItemType Directory -Force -Path "$sharedBase\shared_prof" | Out-Null
    New-Item -ItemType File -Force -Path "$sharedBase\shared_prof\.shared" | Out-Null
    New-Item -ItemType Directory -Force -Path "$sharedBase\full_prof" | Out-Null

    Assert-True (Test-SharedProfile "shared_prof") "Test-SharedProfile returns true for .shared profile"
    Assert-True (!(Test-SharedProfile "full_prof")) "Test-SharedProfile returns false for full profile"

} finally {
    Remove-Item -Recurse -Force $sharedBase -ErrorAction SilentlyContinue
}

# ── Cleanup Test Environment Variables ──
$env:MULTIGRAVITY_HOME = $null
$env:MULTIGRAVITY_TEST_CRED_TARGET = $null
$env:MULTIGRAVITY_PROFILE_STACK = $null
$env:MULTIGRAVITY_ACTIVE_PROFILE = $null

Write-Host ""
Write-Host "=================================================="
Write-Host " Test Summary: $Passed Passed, $Failed Failed     "
Write-Host "=================================================="

if ($Failed -gt 0) {
    exit 1
} else {
    exit 0
}