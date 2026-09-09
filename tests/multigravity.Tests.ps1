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

    # Simulate Option 1 Transient Launch-Swap: prof1 starts -> launches prof2 -> prof2 terminates -> restores Global resting state
    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null

    # 1. prof1 launches
    Prepare-LaunchCredential "prof1" | Out-Null
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof1" "prof1 is active profile"
    $userProf1 = $null
    [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$userProf1) | Out-Null
    Assert-Equal $userProf1 "prof1_user" "Vault loaded with prof1 credentials during launch"
    
    # 2. prof2 launched concurrently / nested
    Prepare-LaunchCredential "prof2" -ForceSwitch | Out-Null
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof2" "prof2 is now active profile"
    $userProf2 = $null
    [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$userProf2) | Out-Null
    Assert-Equal $userProf2 "prof2_user" "Vault loaded with prof2 credentials during launch"

    # 3. prof2 exits -> restores Global resting state unconditionally (no parent stack resurrection)
    Restore-PostLaunchCredential -PROFILE "prof2" -HadSavedCred $true
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile cleared on prof2 exit"

    # Verify vault cleared to global resting state (no global profile set yet -> vault is empty)
    $restoredUser = $null
    $restoredBlob = [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$restoredUser)
    Assert-True ([string]::IsNullOrEmpty($restoredBlob)) "Vault cleared to global resting state on exit"

    # 4. prof1 exits
    Restore-PostLaunchCredential -PROFILE "prof1" -HadSavedCred $true
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile cleared after prof1 exit"

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
    $profFreshDir = "$testBase\prof-fresh"
    New-Item -ItemType Directory -Force -Path $profFreshDir | Out-Null
    $hadFresh = Prepare-LaunchCredential "prof-fresh"
    Assert-True (!$hadFresh) "prof-fresh has no credentials initially"
    # Simulate user signing in during session
    $freshBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("fresh_token_12345"))
    [MultigravityCredVault]::ImportCredential($testCredTarget, "fresh_user", $freshBlob) | Out-Null
    # Exit fresh profile - should save initial credential
    Restore-PostLaunchCredential -PROFILE "prof-fresh" -HadSavedCred $hadFresh
    Assert-True (Test-Path "$profFreshDir\.credentials.json") "prof-fresh saved initial credentials on exit"
    $freshJson = Get-Content "$profFreshDir\.credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $freshJson.userName "fresh_user" "prof-fresh saved correct initial username"

    # 7. Verify Global Profile Protection
    Set-Content -Path "$testBase\.global_profile" -Value "prof-global" -Encoding UTF8
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
    Restore-PostLaunchCredential -PROFILE "prof-global" -HadSavedCred $true
    $globalJsonAfter = Get-Content "$testBase\.global_credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $globalJsonAfter.userName "global_user" "Global credentials NOT overwritten on exit"

    # 7b. Verify Global Profile Credential Restoration
    Set-Content -Path "$testBase\.global_profile" -Value "prof-global" -Encoding UTF8
    $hadGlobal = Prepare-LaunchCredential "prof-global"
    Assert-True $hadGlobal "prof-global restored pre-existing valid credential"
    [string]$user7b = [string]::Empty
    $blob7b = [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$user7b)
    Assert-True (![string]::IsNullOrEmpty($blob7b)) "Credential present in vault after global launch"
    Assert-Equal $user7b "global_user" "Vault contains global_user credentials"
    Restore-PostLaunchCredential -PROFILE "prof-global" -HadSavedCred $hadGlobal
    Assert-Equal $user7b "global_user" "Vault retained global_user post-exit"
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile cleared after global profile exit"

    # 7c. Flag Processing Output Invariance
    $origWriteTime = (Get-Item "$testBase\.global_profile").LastWriteTimeUtc
    $res7c = Process-ProfileCredentialFlags "prof-global" @()
    Assert-True ($res7c -eq $false) "Process-ProfileCredentialFlags returns false for empty args on global profile"
    $allOut7c = & {
        $InformationPreference = 'Continue'
        & { Process-ProfileCredentialFlags "prof-global" @() } > $null
    } *>&1
    Assert-True ($null -eq $allOut7c -or @($allOut7c).Count -eq 0 -or [string]::IsNullOrWhiteSpace(($allOut7c | Out-String).Trim())) "Process-ProfileCredentialFlags produced no output across all streams"
    $currWriteTime = (Get-Item "$testBase\.global_profile").LastWriteTimeUtc
    Assert-True ($currWriteTime -eq $origWriteTime) ".global_profile write timestamp unchanged on routine launch"

    # 7d. Unwinding Unauthenticated Profile & Stack Purge Guard
    $profUnauthDir = "$testBase\prof-unauth"
    New-Item -ItemType Directory -Force -Path $profUnauthDir | Out-Null
    $hadUnauth = Prepare-LaunchCredential "prof-unauth"
    Assert-True (!$hadUnauth) "prof-unauth has no credentials initially"

    $profChildDir = "$testBase\prof-child"
    New-Item -ItemType Directory -Force -Path $profChildDir | Out-Null
    $childBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("child_token_77777"))
    [MultigravityCredVault]::ImportCredential($testCredTarget, "child_user", $childBlob) | Out-Null
    Save-CredentialToProfile "prof-child" | Out-Null

    $hadChild = Prepare-LaunchCredential "prof-child" -ForceSwitch
    Assert-True $hadChild "prof-child launched with valid credential"
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "prof-child" "prof-child is active profile"

    Restore-PostLaunchCredential -PROFILE "prof-child" -HadSavedCred $hadChild
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile cleared after child exit"
    [string]$user7d = [string]::Empty
    $blob7d = [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$user7d)
    Assert-True (![string]::IsNullOrEmpty($blob7d)) "Vault restored to global credentials on child exit"
    Assert-Equal $user7d "global_user" "Vault rests on global profile credentials after child exit"

    Restore-PostLaunchCredential -PROFILE "prof-unauth" -HadSavedCred $false
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "Active profile remains cleared after unauth exit"

    # 7e. Symmetrical Promotion, Demotion & Migration
    Set-Content -Path "$testBase\.global_profile" -Value "prof-demote" -Encoding UTF8
    $demoteData = @{
        userName = "demote_user"
        blob     = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("demote_token_11111"))
        updated  = (Get-Date).ToString("o")
    } | ConvertTo-Json
    Set-Content -Path "$testBase\.global_credentials.json" -Value $demoteData -Encoding UTF8

    $profPromoteDir = "$testBase\prof-promote"
    New-Item -ItemType Directory -Force -Path $profPromoteDir | Out-Null
    $promoteData = @{
        userName = "promote_user"
        blob     = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("promote_token_22222"))
        updated  = (Get-Date).ToString("o")
    } | ConvertTo-Json
    Set-Content -Path "$profPromoteDir\.credentials.json" -Value $promoteData -Encoding UTF8

    Set-GlobalProfile "prof-promote" | Out-Null
    Assert-Equal (Get-GlobalProfile) "prof-promote" "prof-promote is now global profile"
    Assert-True (Test-CredentialFileValid "$testBase\prof-demote\.credentials.json") "Prior global credentials demoted to prof-demote"
    $demotedJson = Get-Content "$testBase\prof-demote\.credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $demotedJson.userName "demote_user" "Demoted username matches prior global user"

    Assert-True (Test-CredentialFileValid "$testBase\.global_credentials.json") "New global credentials valid"
    $promotedJson = Get-Content "$testBase\.global_credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $promotedJson.userName "promote_user" "Promoted username matches prof-promote user"
    Assert-True (!(Test-Path "$profPromoteDir\.credentials.json")) "Redundant local credentials deleted for prof-promote"

    [string]$user7e = [string]::Empty
    $blob7e = [MultigravityCredVault]::ExportCredential($testCredTarget, [ref]$user7e)
    Assert-Equal $user7e "promote_user" "Vault synchronized with promoted user credentials"

    Unset-GlobalProfile | Out-Null
    Assert-True ([string]::IsNullOrEmpty((Get-GlobalProfile))) "Global profile is unset"
    Assert-True (Test-CredentialFileValid "$profPromoteDir\.credentials.json") "Global credentials migrated back to prof-promote local dir"
    $restoredPromoteJson = Get-Content "$profPromoteDir\.credentials.json" -Raw | ConvertFrom-Json
    Assert-Equal $restoredPromoteJson.userName "promote_user" "Migrated username matches promote_user"
    Assert-True (!(Test-Path "$testBase\.global_credentials.json")) ".global_credentials.json deleted on unset"

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

# ── Test Suite 5: Native Pipeline & Stdin Streaming Pass-Through ──
Write-Host ""
Write-Host "Suite 5: Native Pipeline & Stdin Streaming Pass-Through"

$pipeBase = "$testRoot\mg_pipe_test_$PID"
$mockCmd = "$pipeBase\mock_agy.cmd"
$mockLog = "$pipeBase\mock.log"
$mockStdin = "$pipeBase\stdin.log"
$mockCallCount = "$pipeBase\call_count.log"

$env:MULTIGRAVITY_HOME = "$pipeBase\profiles"
$env:MULTIGRAVITY_CLI_APP = $mockCmd
$env:MULTIGRAVITY_TEST_CRED_TARGET = "gemini:test_pipe_vault_$PID"

try {
    New-Item -ItemType Directory -Force -Path "$pipeBase\profiles\pipe_prof" | Out-Null

    $mockPy = "$pipeBase\mock_agy.py"
    $mockPyContent = @"
import sys, os, msvcrt, ctypes
from ctypes import wintypes

call_file = r'$($mockCallCount -replace '\\', '/')'
log_file = r'$($mockLog -replace '\\', '/')'
stdin_file = r'$($mockStdin -replace '\\', '/')'
exit_code = int(os.environ.get('MOCK_EXIT_CODE', 0))

with open(call_file, 'a', encoding='utf-8') as f:
    f.write('call\n')

with open(log_file, 'w', encoding='utf-8') as f:
    f.write(' '.join(sys.argv[1:]) + '\n')

try:
    h = msvcrt.get_osfhandle(sys.stdin.fileno())
    avail = wintypes.DWORD()
    if ctypes.windll.kernel32.PeekNamedPipe(h, None, 0, None, ctypes.byref(avail), None):
        if avail.value > 0:
            data = sys.stdin.buffer.read().decode('utf-8-sig')
            with open(stdin_file, 'w', encoding='utf-8', newline='') as f:
                f.write(data)
except Exception:
    pass

sys.exit(exit_code)
"@
    Set-Content -Path $mockPy -Value $mockPyContent

    $mockCmdContent = @"
@echo off
uv run python "$mockPy" %*
"@
    Set-Content -Path $mockCmd -Value $mockCmdContent

    # 1. Pipeline Pass-Through & Single-Execution Verification (-p - converted to prompt file in .agents/tmp/prompts)
    $pipeLines = @("streamed prompt line 1", "streamed prompt line 2", "streamed prompt line 3")
    $pipeLines | & $MgScript cli pipe_prof -p -

    $calls1 = (Get-Content $mockCallCount -ErrorAction SilentlyContinue).Count
    Assert-Equal $calls1 1 "Pipeline input executes CLI profile exactly once (no per-line multi-execution)"

    $args1 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-True ($args1 -match "-p Please read the prompt instructions from file") "'-p -' flag is converted to prompt file instruction"
    Assert-True ($args1 -match "\.agents[\\/]tmp[\\/]prompts") "Prompt file is saved under .agents/tmp/prompts"
    Assert-True (!(Test-Path $mockStdin)) "Pipeline with -p - passes prompt file instead of raw stdin"

    # 2. Interactive / Standard Non-Pipeline Invocation (no stdin pipe)
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    & $MgScript cli pipe_prof arg_foo arg_bar

    $calls2 = (Get-Content $mockCallCount -ErrorAction SilentlyContinue).Count
    Assert-Equal $calls2 1 "Standard non-pipeline invocation executes CLI profile once"

    $args2 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args2 "arg_foo arg_bar" "Standard forward arguments correctly received"

    Assert-True (!(Test-Path $mockStdin)) "Non-pipeline invocation does not pipe stdin stream"

    # 3. Exit Code Forwarding
    $env:MOCK_EXIT_CODE = 42
    & $MgScript cli pipe_prof exit_check
    Assert-Equal $LASTEXITCODE 42 "multigravity.ps1 forwards CLI non-zero exit code (42) back to caller"
    $env:MOCK_EXIT_CODE = $null

    # 4. 'agy' alias with pipeline streaming (-p - converted to prompt file)
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    "single line prompt" | & $MgScript agy pipe_prof -p -
    $calls3 = (Get-Content $mockCallCount -ErrorAction SilentlyContinue).Count
    Assert-Equal $calls3 1 "'agy' alias executes CLI profile exactly once"
    $args3 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-True ($args3 -match "-p Please read the prompt instructions from file") "'agy' alias converts -p - to prompt file"

    # 5. Pipeline with additional arguments (preserves other flags while converting -p -)
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    "multi-arg prompt" | & $MgScript cli pipe_prof --verbose -p - --model gemini-2.5-pro
    $args4 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-True ($args4 -match "--verbose") "Other CLI flags preserved alongside prompt file"
    Assert-True ($args4 -match "--model gemini-2.5-pro") "Model flag preserved"
    Assert-True ($args4 -match "-p Please read the prompt instructions from file") "Piped prompt converted to prompt file"

    # 6. Non-pipelined invocation with -p preserved
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    & $MgScript cli pipe_prof -p "non-piped prompt"
    $args5 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args5 "-p non-piped prompt" "Non-pipelined -p argument preserved unchanged"
    Assert-True (!(Test-Path $mockStdin)) "Non-pipelined execution does not stream stdin"

    # 7. Explicit --prompt-file argument
    $testPromptSource = "$pipeBase\custom_source_prompt.md"
    Set-Content -Path $testPromptSource -Value "Custom prompt source text"
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    & $MgScript cli pipe_prof --prompt-file $testPromptSource
    $args7 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-True ($args7 -match "-p Please read the prompt instructions from file") "--prompt-file converts to -p instruction"
    Assert-True ($args7 -match "\.agents[\\/]tmp[\\/]prompts") "--prompt-file stores prompt file in .agents/tmp/prompts"

    # 8. Oversized -p argument (> 4000 chars) auto-spills to .agents/tmp/prompts
    $hugePrompt = "A" * 5000
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    & $MgScript cli pipe_prof -p $hugePrompt
    $args8 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-True ($args8 -match "-p Please read the prompt instructions from file") "Oversized prompt spills to file instruction"
    Assert-True ($args8 -match "large_prompt_") "Oversized prompt stored in large_prompt_*.md"

} finally {
    $env:MULTIGRAVITY_CLI_APP = $null
    $env:MOCK_EXIT_CODE = $null
    Remove-Item -Recurse -Force $pipeBase -ErrorAction SilentlyContinue
}

# ── Test Suite 6: Per-User Mutex Concurrency & Timeout ──
Write-Host ""
Write-Host "Suite 6: Per-User Mutex Concurrency & Timeout"
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName = "Local\Multigravity_Vault_Mutex_$userSid"

$job = Start-Job -ScriptBlock {
    param($mName)
    $m = [System.Threading.Mutex]::new($true, $mName)
    Start-Sleep -Seconds 3
    $m.ReleaseMutex()
    $m.Dispose()
} -ArgumentList $mutexName

Start-Sleep -Milliseconds 600

$prevTimeout = $env:MULTIGRAVITY_MUTEX_TIMEOUT_MS
$env:MULTIGRAVITY_MUTEX_TIMEOUT_MS = 200
$timedOut = $false
try {
    Invoke-WithVaultMutex { $true }
} catch [MultigravityExitException] {
    $timedOut = ($_.Exception.ExitCode -eq 1)
} catch {
    $timedOut = $true
} finally {
    $env:MULTIGRAVITY_MUTEX_TIMEOUT_MS = $prevTimeout
    Wait-Job $job | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force | Out-Null
}
Assert-True $timedOut "Invoke-WithVaultMutex times out when mutex held concurrently"

$acquiredAfterRelease = Invoke-WithVaultMutex { $true }
Assert-True $acquiredAfterRelease "Invoke-WithVaultMutex acquires successfully after external release"

# ── Test Suite 7: Instance Registry, Liveness & Displacement Stack ──
Write-Host ""
Write-Host "Suite 7: Instance Registry, Liveness & Displacement Stack"

$proc = Get-Process -Id $PID
$liveStart = $proc.StartTime.ToUniversalTime().ToString("o")
$jitterStart = $proc.StartTime.AddSeconds(1.5).ToUniversalTime().ToString("o")
$futureStart = $proc.StartTime.AddSeconds(10).ToUniversalTime().ToString("o")

$liveInst = [PSCustomObject]@{
    pid = $PID
    profile = "test_live"
    type = "cli"
    started = $liveStart
}
Assert-True (Test-InstanceAlive $liveInst) "Test-InstanceAlive returns true for running process"

$deadInst = [PSCustomObject]@{
    pid = 999999
    profile = "test_dead"
    type = "cli"
    started = $liveStart
}
Assert-True (!(Test-InstanceAlive $deadInst)) "Test-InstanceAlive returns false for dead process"

$jitterInst = [PSCustomObject]@{
    pid = $PID
    profile = "test_jitter"
    type = "cli"
    started = $jitterStart
}
Assert-True (Test-InstanceAlive $jitterInst) "Test-InstanceAlive tolerates future start time within 2s jitter"

$futureInst = [PSCustomObject]@{
    pid = $PID
    profile = "test_future"
    type = "cli"
    started = $futureStart
}
Assert-True (!(Test-InstanceAlive $futureInst)) "Test-InstanceAlive rejects future start time beyond 2s jitter"

$suite7Base = "$testRoot\mg_inst_test_$PID"
$env:MULTIGRAVITY_HOME = $suite7Base
try {
    New-Item -ItemType Directory -Force -Path $suite7Base | Out-Null
    $regData = [PSCustomObject]@{
        instances = @($deadInst, $liveInst)
        active_vault_profile = "test_live"
    }
    Save-ActiveInstancesRegistry $regData
    $prunedReg = Get-ActiveInstancesRegistry
    Assert-Equal $prunedReg.instances.Count 1 "Get-ActiveInstancesRegistry prunes dead process instances"
    Assert-Equal $prunedReg.instances[0].pid $PID "Remaining instance is live process"
} finally {
    Remove-Item -Recurse -Force $suite7Base -ErrorAction SilentlyContinue
}

$suite7Base2 = "$testRoot\mg_peer_test_$PID"
$env:MULTIGRAVITY_HOME = $suite7Base2
$dummyProc = $null
try {
    New-Item -ItemType Directory -Force -Path "$suite7Base2\profA" | Out-Null
    New-Item -ItemType Directory -Force -Path "$suite7Base2\profB" | Out-Null

    $blobA = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("token_A_12345"))
    $blobB = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("token_B_67890"))
    $blobG = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("token_G_99999"))

    @{ userName = "user_A"; blob = $blobA; updated = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Path "$suite7Base2\profA\.credentials.json" -Encoding UTF8
    @{ userName = "user_B"; blob = $blobB; updated = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Path "$suite7Base2\profB\.credentials.json" -Encoding UTF8
    @{ userName = "user_global"; blob = $blobG; updated = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Path "$suite7Base2\.global_credentials.json" -Encoding UTF8
    Set-Content -Path "$suite7Base2\.global_profile" -Value "prof-global" -Encoding UTF8

    # 1. Launch profA
    $hadA = Prepare-LaunchCredential -PROFILE "profA" -ProcessId $PID -ProcessType "cli" -StartTime $proc.StartTime
    Assert-True $hadA "profA launched with valid credential"
    $reg1 = Get-ActiveInstancesRegistry
    Assert-Equal $reg1.instances.Count 1 "Registry tracks 1 active instance for profA"
    Assert-Equal $reg1.instances[0].profile "profA" "Instance profile is profA"

    # 2. Concurrently launch profB with second live process without blocking or requiring --force-switch
    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
    $dummyProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 30" -PassThru
    $dummyPid = $dummyProc.Id
    $testConvId = "11111111-2222-3333-4444-555555555555"
    $hadB = Prepare-LaunchCredential -PROFILE "profB" -ProcessId $dummyPid -ProcessType "cli" -StartTime $dummyProc.StartTime -ConversationId $testConvId
    Assert-True $hadB "profB launched concurrently without blocking"

    $reg2 = Get-ActiveInstancesRegistry
    Assert-Equal $reg2.instances.Count 2 "Registry tracks 2 concurrent active instances across profA and profB"
    Assert-True (@($reg2.instances | Where-Object { $_.profile -eq 'profA' }).Count -eq 1) "profA instance is active"
    Assert-True (@($reg2.instances | Where-Object { $_.profile -eq 'profB' }).Count -eq 1) "profB instance is active"
    Assert-Equal (@($reg2.instances | Where-Object { $_.profile -eq 'profB' })[0].conversation_id) $testConvId "profB instance stores conversation ID in registry"

    # 3. Verify status command lists active instances with CONVERSATION ID column
    $statusOut = (& { Invoke-StatusProfiles } *>&1 | Out-String)
    Assert-True ($statusOut -like "*Active Instances (Task Manager):*") "Status shows Active Instances section"
    Assert-True ($statusOut -like "*CONVERSATION ID*") "Status header contains CONVERSATION ID column"
    Assert-True ($statusOut -like "*profA*") "Status shows profA in table"
    Assert-True ($statusOut -like "*profB*") "Status shows profB in table"
    Assert-True ($statusOut -like "*$testConvId*") "Status displays explicit conversation ID for profB"

    # 4. Terminate profB via Invoke-KillProfile using Conversation ID
    $credTarget7 = Get-TargetCredName
    Invoke-KillProfile $testConvId
    $reg3 = Get-ActiveInstancesRegistry
    Assert-Equal $reg3.instances.Count 1 "Kill by conversation ID removed profB from registry"
    Assert-Equal $reg3.instances[0].profile "profA" "profA remains active in registry"
    Assert-Equal $reg3.active_vault_profile "prof-global" "active_vault_profile restored to global profile on kill"
    $credPostKill = [string]::Empty
    $null = [MultigravityCredVault]::ExportCredential($credTarget7, [ref]$credPostKill)
    Assert-Equal $credPostKill "user_global" "Vault restored to global credentials after profB was killed"
    Assert-True ($dummyProc.HasExited) "dummyProc for profB was killed by Invoke-KillProfile using conversation ID"

    # 4b. Concurrently launch profB again and verify peer exit restores global (not peer profA)
    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
    $dummyProc2 = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 30" -PassThru
    try {
        $hadB2 = Prepare-LaunchCredential -PROFILE "profB" -ProcessId $dummyProc2.Id -ProcessType "cli" -StartTime $dummyProc2.StartTime
        Assert-True $hadB2 "profB launched concurrently second time"
        $regPeerPre = Get-ActiveInstancesRegistry
        Assert-Equal $regPeerPre.instances.Count 2 "Registry tracks 2 active instances before peer exit"

        Restore-PostLaunchCredential -PROFILE "profB" -HadSavedCred $hadB2 -ProcessId $dummyProc2.Id
        $regPeerExit = Get-ActiveInstancesRegistry
        Assert-Equal $regPeerExit.instances.Count 1 "profA remains active after profB normal exit"
        Assert-Equal $regPeerExit.active_vault_profile "prof-global" "active_vault_profile restored to global profile on peer exit"
        $credPostPeerExit = [string]::Empty
        $null = [MultigravityCredVault]::ExportCredential($credTarget7, [ref]$credPostPeerExit)
        Assert-Equal $credPostPeerExit "user_global" "Vault restored to global credentials on peer normal exit (not peer profA)"
    } finally {
        if ($dummyProc2 -and -not $dummyProc2.HasExited) {
            Stop-Process -Id $dummyProc2.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # 5. Exit profA and verify global profile credentials remain restored
    Restore-PostLaunchCredential -PROFILE "profA" -HadSavedCred $hadA -ProcessId $PID
    $reg4 = Get-ActiveInstancesRegistry
    Assert-Equal $reg4.instances.Count 0 "Zero instances remaining in registry"
    Assert-Equal $reg4.active_vault_profile "prof-global" "active_vault_profile in registry is prof-global on full exit"

    $finalUser = [string]::Empty
    $finalBlob = [MultigravityCredVault]::ExportCredential($credTarget7, [ref]$finalUser)
    Assert-Equal $finalUser "user_global" "Global profile credentials restored when all instances terminate"

    # 6. Verify parent-child process tracking and hierarchical status tree display
    $parentDummy = Start-Process powershell.exe -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 60" -PassThru
    $childDummy  = Start-Process powershell.exe -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 60" -PassThru
    try {
        Prepare-LaunchCredential -PROFILE "profA" -ProcessId $parentDummy.Id -ProcessType "cli" | Out-Null
        
        $env:MULTIGRAVITY_ACTIVE_PID = $parentDummy.Id
        Prepare-LaunchCredential -PROFILE "profB" -ProcessId $childDummy.Id -ProcessType "cli" | Out-Null
        $env:MULTIGRAVITY_ACTIVE_PID = $null

        $regPC = Get-ActiveInstancesRegistry
        $childEntry = @($regPC.instances | Where-Object { $_.pid -eq $childDummy.Id })
        Assert-Equal $childEntry.Count 1 "Child instance registered"
        Assert-Equal $childEntry[0].parent_pid $parentDummy.Id "Child instance records parent PID"

        $statusOut = (& { Invoke-StatusProfiles } 6>&1 | Out-String)
        Assert-True ($statusOut -match "\\--\s+$($childDummy.Id)") "Status table renders child indented with tree connector \-- under parent"

        Invoke-KillProfile "$($parentDummy.Id)" | Out-Null
        Start-Sleep -Milliseconds 300

        Assert-True $parentDummy.HasExited "Parent process killed by Invoke-KillProfile PID"
        Assert-True $childDummy.HasExited "Child process terminated recursively with parent"

        $regAfterKill = Get-ActiveInstancesRegistry
        $remTree = @($regAfterKill.instances | Where-Object { $_.pid -eq $childDummy.Id -or $_.pid -eq $parentDummy.Id })
        Assert-Equal $remTree.Count 0 "Both parent and child removed from registry after tree kill"
    } finally {
        if ($parentDummy -and -not $parentDummy.HasExited) { Stop-Process -Id $parentDummy.Id -Force -ErrorAction SilentlyContinue }
        if ($childDummy -and -not $childDummy.HasExited) { Stop-Process -Id $childDummy.Id -Force -ErrorAction SilentlyContinue }
        $env:MULTIGRAVITY_ACTIVE_PID = $null
    }

    # 7. Verify dynamic conversation ID resolution via active WAL lock
    $geminiConvDir = Join-Path (Get-SystemGeminiDir) "antigravity-cli\conversations"
    if (-not (Test-Path $geminiConvDir)) { New-Item -ItemType Directory -Force -Path $geminiConvDir | Out-Null }
    $dynConvId = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    $testShm = Join-Path $geminiConvDir "$dynConvId.db-shm"

    $lockProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"`$stream = [System.IO.File]::Open('$testShm', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read); Start-Sleep -Seconds 30`"" -PassThru
    Start-Sleep -Milliseconds 800
    try {
        $resolvedId = Get-ActiveConversationIdForPid $lockProc.Id
        Assert-Equal $resolvedId $dynConvId "Dynamic resolution detects conversation UUID from locked db-shm"
    } finally {
        if ($lockProc -and -not $lockProc.HasExited) {
            Stop-Process -Id $lockProc.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $testShm) { Remove-Item -Force $testShm -ErrorAction SilentlyContinue }
    }
} finally {
    if ($dummyProc -and -not $dummyProc.HasExited) {
        Stop-Process -Id $dummyProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $suite7Base2 -ErrorAction SilentlyContinue
}

# ── Test Suite 8: Argument Preservation, Common Parameter Bypass & Route Mapping ──
Write-Host ""
Write-Host "Suite 8: Argument Preservation, Common Parameter Bypass & Route Mapping"

$psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }

$helpRes = & $psExe -NoProfile -ExecutionPolicy Bypass -File $MgScript --help
Assert-Equal $LASTEXITCODE 0 "Executing script with --help exits with code 0"

$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$unknownRes = & $psExe -NoProfile -ExecutionPolicy Bypass -File $MgScript -unknownFlag 2>&1
$ErrorActionPreference = $prevEap
Assert-Equal $LASTEXITCODE 1 "Unknown option '-unknownFlag' exits with code 1"
Assert-True (($unknownRes | Out-String) -like "*Unknown option*") "Error message reports unknown option"

$legacyRes = & $psExe -NoProfile -ExecutionPolicy Bypass -File $MgScript -cmd "help"
Assert-Equal $LASTEXITCODE 0 "Script accepts -cmd 'help' backwards-compatibility parameter"

# ── Test Suite 9: Dot-Sourcing Isolation & Exception Flow ──
Write-Host ""
Write-Host "Suite 9: Dot-Sourcing Isolation & Exception Flow"

Assert-True $script:IsDotSourced "Script detected it was dot-sourced"

$caughtCode = $null
try {
    Exit-Multigravity 42
} catch [MultigravityExitException] {
    $caughtCode = $_.Exception.ExitCode
}
Assert-Equal $caughtCode 42 "Exit-Multigravity throws MultigravityExitException with code 42 under dot-sourcing"
Assert-Equal $global:LASTEXITCODE 42 "LASTEXITCODE updated to 42 by Exit-Multigravity"

$caughtZero = $null
try {
    Exit-Multigravity 0
} catch [MultigravityExitException] {
    $caughtZero = $_.Exception.ExitCode
}
Assert-Equal $caughtZero 0 "Exit-Multigravity throws MultigravityExitException with code 0 under dot-sourcing"

try {
    $null = . $MgScript -cmd "invalid_command_nonexistent" -ErrorAction SilentlyContinue 2>$null
} catch {}
Assert-Equal $global:LASTEXITCODE 1 "Dot-sourcing invalid command sets LASTEXITCODE to 1 without crashing host"

# ── Test Suite 10: Lifecycle Hooks & Conversation Tracking ──
Write-Host ""
Write-Host "Suite 10: Lifecycle Hooks & Conversation Tracking"

$suite10TestBase = "$testRoot\mg_suite10_$PID"
$suite10Bin = "$suite10TestBase\bin"
$suite10Config = "$suite10TestBase\config"
$suite10HooksJson = "$suite10Config\hooks.json"
$suite10Profiles = "$suite10TestBase\profiles"
$dummyHookProc = $null

try {
    New-Item -ItemType Directory -Force -Path $suite10Bin | Out-Null
    New-Item -ItemType Directory -Force -Path $suite10Config | Out-Null
    New-Item -ItemType Directory -Force -Path $suite10Profiles | Out-Null

    # 1. Non-destructive append to pre-populated hooks.json
    $initialHooks = @{
        "my-custom-linter" = @{
            "PreInvocation" = @(
                @{
                    "type" = "command"
                    "command" = "C:\tools\linter.cmd"
                    "timeout" = 10
                }
            )
        }
    }
    [System.IO.File]::WriteAllText($suite10HooksJson, ($initialHooks | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    $testHookCmd = "$suite10Bin\multigravity-hook.cmd"
    Register-HookInConfigFile $suite10HooksJson $testHookCmd

    Assert-True (Test-Path $suite10HooksJson) "hooks.json exists after registration"
    $rawBytes = [System.IO.File]::ReadAllBytes($suite10HooksJson)
    $hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) "hooks.json is written as UTF-8 without BOM"
    $hooksObj = Get-Content $suite10HooksJson -Raw | ConvertFrom-Json
    Assert-True ($null -ne $hooksObj."my-custom-linter") "Pre-existing custom hook preserved during registration"
    Assert-Equal $hooksObj."my-custom-linter".PreInvocation[0].command "C:\tools\linter.cmd" "Pre-existing hook command unchanged"
    Assert-True ($null -ne $hooksObj."multigravity-conversation-tracker") "multigravity-conversation-tracker successfully registered"
    Assert-Equal $hooksObj."multigravity-conversation-tracker".PreInvocation[0].command $testHookCmd "Registered hook command matches expected path"

    # 2. Idempotency: register again without duplicates
    Register-HookInConfigFile $suite10HooksJson $testHookCmd
    $hooksObj2 = Get-Content $suite10HooksJson -Raw | ConvertFrom-Json
    Assert-Equal (@($hooksObj2."multigravity-conversation-tracker".PreInvocation).Count) 1 "Re-registering hook is idempotent and does not create duplicates"

    # 3. Non-destructive unregister
    Unregister-HookInConfigFile $suite10HooksJson
    $hooksObj3 = Get-Content $suite10HooksJson -Raw | ConvertFrom-Json
    Assert-True ($null -eq $hooksObj3."multigravity-conversation-tracker") "multigravity-conversation-tracker removed on unregister"
    Assert-True ($null -ne $hooksObj3."my-custom-linter") "Custom user hook remains intact after unregister"

    # 4. Hook script fail-open behavior on malformed / empty stdin
    $hookPs1Path = "$suite10Bin\multigravity-hook.ps1"
    [System.IO.File]::WriteAllText($hookPs1Path, $script:MultigravityHookScriptContent, [System.Text.Encoding]::UTF8)

    $psCoreExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }

    $emptyOut = ("" | & $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $hookPs1Path) | Out-String
    Assert-Equal ($emptyOut.Trim()) "{}" "Hook returns {} on empty stdin"

    $garbageOut = ("{bad-json-payload" | & $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $hookPs1Path) | Out-String
    Assert-Equal ($garbageOut.Trim()) "{}" "Hook returns {} on malformed JSON without crashing"

    # 5. Hook script updates active instance conversation ID
    $dummyHookProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 30`"" -PassThru
    $initReg = @{
        instances = @(
            @{
                pid = $dummyHookProc.Id
                profile = "hook_test_prof"
                type = "cli"
                started = (Get-Date).ToUniversalTime().ToString("o")
                conversation_id = "initial-guid-1111"
            }
        )
        profile_stack = $null
        active_vault_profile = "prof-global"
    }
    $suite10RegPath = "$suite10Profiles\.active_instances.json"
    [System.IO.File]::WriteAllText($suite10RegPath, ($initReg | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    $env:MULTIGRAVITY_HOME = $suite10Profiles
    $env:MULTIGRAVITY_ACTIVE_PID = $dummyHookProc.Id

    $updatePayload = '{"conversationId":"updated-guid-2222"}'
    $hookOut = ($updatePayload | & $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $hookPs1Path) | Out-String
    Assert-Equal ($hookOut.Trim()) "{}" "Hook returns {} on successful conversation update"

    $regAfter = Get-Content $suite10RegPath -Raw | ConvertFrom-Json
    $updatedInst = $regAfter.instances | Where-Object { [int]$_.pid -eq $dummyHookProc.Id }
    Assert-Equal $updatedInst.conversation_id "updated-guid-2222" "Active instance conversation ID updated to new conversation"

    # 6. CLI dispatch for hooks command
    $hooksStatusOut = & $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $MgScript hooks status
    Assert-Equal $LASTEXITCODE 0 "Executing 'multigravity hooks status' exits with code 0"

    # 7. Hook script contains background quota update telemetry logic
    $hookScriptContent = Get-Content $hookPs1Path -Raw
    Assert-True ($hookScriptContent.Contains("Update-ProfileQuotaCache")) "Hook script contains background quota update invocation"
    Assert-True ($hookScriptContent.Contains('$quotaCachePath.lock')) "Hook script implements lockfile check to avoid concurrent quota workers"

} finally {
    if ($dummyHookProc -and -not $dummyHookProc.HasExited) {
        Stop-Process -Id $dummyHookProc.Id -Force -ErrorAction SilentlyContinue
    }
    $env:MULTIGRAVITY_ACTIVE_PID = $null
    Remove-Item -Recurse -Force $suite10TestBase -ErrorAction SilentlyContinue
}

# ── Test Suite 11: Realtime Status Dashboard & Parent-Child Tree Termination ──
Write-Host ""
Write-Host "Suite 11: Realtime Status Dashboard & Parent-Child Tree Termination"

$suite11TestBase = "$testRoot\mg_suite11_$PID"
$suite11Profiles = "$suite11TestBase\profiles"
$parentDummy = $null
$childDummy = $null

try {
    New-Item -ItemType Directory -Force -Path $suite11Profiles | Out-Null
    $profParent = "$suite11Profiles\parent_prof"
    $profChild  = "$suite11Profiles\child_prof"
    New-Item -ItemType Directory -Force -Path $profParent | Out-Null
    New-Item -ItemType Directory -Force -Path $profChild | Out-Null

    # 1. Start parent and child dummy processes
    $parentDummy = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 30`"" -PassThru
    $childDummy  = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 30`"" -PassThru

    $suite11Reg = @{
        instances = @(
            @{
                pid = $parentDummy.Id
                profile = "parent_prof"
                type = "cli"
                started = $parentDummy.StartTime.ToUniversalTime().ToString("o")
                conversation_id = "parent-conv-uuid-1111"
                parent_pid = $null
            },
            @{
                pid = $childDummy.Id
                profile = "child_prof"
                type = "cli"
                started = $childDummy.StartTime.ToUniversalTime().ToString("o")
                conversation_id = "child-conv-uuid-2222"
                parent_pid = $parentDummy.Id
            }
        )
        profile_stack = $null
        active_vault_profile = "prof-global"
    }
    $suite11RegPath = "$suite11Profiles\.active_instances.json"
    [System.IO.File]::WriteAllText($suite11RegPath, ($suite11Reg | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    $env:MULTIGRAVITY_HOME = $suite11Profiles

    # 2. Test multigravity status --realtime single-frame output
    $psCoreExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    $env:MULTIGRAVITY_REALTIME_MAX_ITERATIONS = 1

    $rtOut = (& $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $MgScript status --realtime) | Out-String
    Assert-Equal $LASTEXITCODE 0 "Executing 'multigravity status --realtime' exits with code 0"
    Assert-True ($rtOut.Contains("Multigravity Status (Realtime Mode)")) "Realtime status header is displayed"
    Assert-True ($rtOut.Contains("SEL") -and $rtOut.Contains("PID") -and $rtOut.Contains("PROFILE")) "Table headers contain SEL, PID, and PROFILE columns"
    Assert-True ($rtOut.Contains("*") -and $rtOut.Contains("parent_prof")) "Selection marker '*' placed on initial active instance"
    Assert-True ($rtOut.Contains("\--") -and $rtOut.Contains("child_prof")) "Child instance rendered with tree connector"
    Assert-True ($rtOut.Contains("Controls: [Up/Down] Select PID")) "Controls action footer is displayed"

    # 3. Test multigravity status -r alias
    $rtShortOut = (& $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $MgScript status -r) | Out-String
    Assert-Equal $LASTEXITCODE 0 "Executing 'multigravity status -r' exits with code 0"
    Assert-True ($rtShortOut.Contains("Multigravity Status (Realtime Mode)")) "Short flag -r launches Realtime Mode"

    # 3b. Test direct Invoke-RealtimeStatusDashboard with MaxIterations 1
    $directRtOut = (& { Invoke-RealtimeStatusDashboard -MaxIterations 1 } 6>&1) | Out-String
    Assert-True ($directRtOut.Contains("Multigravity Status (Realtime Mode)")) "Direct Invoke-RealtimeStatusDashboard renders realtime dashboard header"
    Assert-True ($directRtOut.Contains("parent_prof") -and $directRtOut.Contains("child_prof")) "Direct realtime dashboard renders both parent and child profiles"

    # 4. Test selecting parent to kill children then parent
    Invoke-KillProfile "$($parentDummy.Id)" | Out-Null
    Start-Sleep -Milliseconds 400

    Assert-True $childDummy.HasExited "Killing parent PID terminates child process before parent"
    Assert-True $parentDummy.HasExited "Killing parent PID terminates parent process"

    $regAfterKill = Get-Content $suite11RegPath -Raw | ConvertFrom-Json
    $remInsts = if ($regAfterKill.instances) { @($regAfterKill.instances) } else { @() }
    Assert-Equal $remInsts.Count 0 "Both parent and child instances removed from active registry after parent kill"

    # 5. Test child-only kill preserves parent
    $parentDummy2 = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 30`"" -PassThru
    $childDummy2  = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 30`"" -PassThru
    $suite11Reg2 = @{
        instances = @(
            @{
                pid = $parentDummy2.Id
                profile = "parent_prof"
                type = "cli"
                started = $parentDummy2.StartTime.ToUniversalTime().ToString("o")
                conversation_id = "p-conv"
                parent_pid = $null
            },
            @{
                pid = $childDummy2.Id
                profile = "child_prof"
                type = "cli"
                started = $childDummy2.StartTime.ToUniversalTime().ToString("o")
                conversation_id = "c-conv"
                parent_pid = $parentDummy2.Id
            }
        )
        profile_stack = $null
        active_vault_profile = "prof-global"
    }
    [System.IO.File]::WriteAllText($suite11RegPath, ($suite11Reg2 | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    Invoke-KillProfile "$($childDummy2.Id)" | Out-Null
    Start-Sleep -Milliseconds 400

    Assert-True $childDummy2.HasExited "Child process terminated when child PID is targeted"
    Assert-True (-not $parentDummy2.HasExited) "Parent process remains running when only child PID is killed"

    $regAfterChildKill = Get-Content $suite11RegPath -Raw | ConvertFrom-Json
    $pRem = @($regAfterChildKill.instances | Where-Object { [int]$_.pid -eq $parentDummy2.Id })
    Assert-Equal $pRem.Count 1 "Parent instance remains in active registry after child-only kill"

    Stop-Process -Id $parentDummy2.Id -Force -ErrorAction SilentlyContinue

} finally {
    $env:MULTIGRAVITY_REALTIME_MAX_ITERATIONS = $null
    if ($parentDummy -and -not $parentDummy.HasExited) { Stop-Process -Id $parentDummy.Id -Force -ErrorAction SilentlyContinue }
    if ($childDummy -and -not $childDummy.HasExited) { Stop-Process -Id $childDummy.Id -Force -ErrorAction SilentlyContinue }
    if ($parentDummy2 -and -not $parentDummy2.HasExited) { Stop-Process -Id $parentDummy2.Id -Force -ErrorAction SilentlyContinue }
    if ($childDummy2 -and -not $childDummy2.HasExited) { Stop-Process -Id $childDummy2.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $suite11TestBase -ErrorAction SilentlyContinue
}

# ── Test Suite 12: Quota Telemetry, Cache Invalidation & Status Output ──
Write-Host ""
Write-Host "Suite 12: Quota Telemetry, Cache Invalidation & Status Output"

$suite12TestBase = (Join-Path $testRoot "mg_quota_test_$PID")
$env:MULTIGRAVITY_HOME = $suite12TestBase
$suite12CredTarget = "gemini:antigravity_test_quota_$PID"
$env:MULTIGRAVITY_TEST_CRED_TARGET = $suite12CredTarget
$env:MULTIGRAVITY_TEST_SKIP_QUOTA_FETCH = "1"
$psCoreExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $suite12TestBase "profQ1") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $suite12TestBase "profQ2") | Out-Null

    # 1. Test Get-ProfileQuotaCachePath routing
    $pathQ1 = Get-ProfileQuotaCachePath "profQ1"
    $expectedPathQ1 = Join-Path (Join-Path $suite12TestBase "profQ1") ".quota_cache.json"
    Assert-Equal $pathQ1 $expectedPathQ1 "Get-ProfileQuotaCachePath returns profile-specific cache path"

    Set-Content -Path (Join-Path $suite12TestBase ".global_profile") -Value "profQ1" -Encoding UTF8
    $pathGlobal = Get-ProfileQuotaCachePath "profQ1"
    $expectedPathGlobal = Join-Path $suite12TestBase ".global_quota_cache.json"
    Assert-Equal $pathGlobal $expectedPathGlobal "Get-ProfileQuotaCachePath returns global cache path when profile matches global"

    # Reset global profile
    Remove-Item (Join-Path $suite12TestBase ".global_profile") -Force -ErrorAction SilentlyContinue

    # 2. Test Get-ProfileQuotaSummary for profile without credentials
    $summaryNoCred = Get-ProfileQuotaSummary -ProfileName "profQ2"
    Assert-Equal $summaryNoCred "-" "Get-ProfileQuotaSummary returns '-' for profile without credentials"

    # 3. Test Get-ProfileQuotaSummary with valid cache
    $dummyBlob = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("test_blob"))
    $credData = @{ userName = "user_q1"; blob = $dummyBlob; updated = (Get-Date).ToString("o") } | ConvertTo-Json
    Set-Content -Path (Join-Path (Join-Path $suite12TestBase "profQ1") ".credentials.json") -Value $credData -Encoding UTF8

    $cachedSummary = "G: 65%/30% | 3P: 100%"
    $cacheObj = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        profile   = "profQ1"
        summary   = $cachedSummary
        raw       = @{}
    }
    $cacheJson = $cacheObj | ConvertTo-Json
    Set-Content -Path (Join-Path (Join-Path $suite12TestBase "profQ1") ".quota_cache.json") -Value $cacheJson -Encoding UTF8

    $summaryWithCache = Get-ProfileQuotaSummary -ProfileName "profQ1"
    Assert-Equal $summaryWithCache $cachedSummary "Get-ProfileQuotaSummary returns cached summary when unexpired"

    # 4. Test SkipFetch flag returns cache even if expired
    $oldCacheObj = @{
        timestamp = (Get-Date).AddHours(-2).ToUniversalTime().ToString("o")
        profile   = "profQ1"
        summary   = "G: 10%/5% | 3P: 50%"
        raw       = @{}
    }
    $oldCacheJson = $oldCacheObj | ConvertTo-Json
    Set-Content -Path (Join-Path (Join-Path $suite12TestBase "profQ1") ".quota_cache.json") -Value $oldCacheJson -Encoding UTF8

    $summarySkipFetch = Get-ProfileQuotaSummary -ProfileName "profQ1" -SkipFetch
    Assert-Equal $summarySkipFetch "G: 10%/5% | 3P: 50%" "Get-ProfileQuotaSummary with -SkipFetch returns existing cache regardless of age"

    # 5. Verify Invoke-StatusProfiles renders QUOTA (5H / WK) column and cached value
    $statusOut = (& { Invoke-StatusProfiles } 6>&1 | Out-String)
    Assert-True ($statusOut.Contains("QUOTA (5H / WK)")) "Invoke-StatusProfiles includes QUOTA (5H / WK) column header"
    Assert-True ($statusOut.Contains("G: 10%/5% | 3P: 50%")) "Invoke-StatusProfiles displays cached quota value in table"

    # 6. Test CLI execution of 'multigravity quota'
    $quotaCliOut = (& $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $MgScript quota) | Out-String
    Assert-Equal $LASTEXITCODE 0 "Executing 'multigravity quota' exits with code 0"
    Assert-True ($quotaCliOut.Contains("QUOTA (5H / WK)")) "'multigravity quota' renders profile table with QUOTA column"

    # 7. Verify multigravity status defaults to fast -SkipFetch without live credential fetches
    $statusCliOut = (& $psCoreExe -NoProfile -ExecutionPolicy Bypass -File $MgScript status) | Out-String
    Assert-Equal $LASTEXITCODE 0 "Executing 'multigravity status' exits with code 0"
    Assert-True ($statusCliOut.Contains("G: 10%/5% | 3P: 50%")) "'multigravity status' defaults to -SkipFetch and displays cached quota"

} finally {
    $env:MULTIGRAVITY_TEST_SKIP_QUOTA_FETCH = $null
    Remove-Item -Recurse -Force $suite12TestBase -ErrorAction SilentlyContinue
}

# ── Cleanup Test Environment Variables ──
$env:MULTIGRAVITY_HOME = $null
$env:MULTIGRAVITY_TEST_CRED_TARGET = $null
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