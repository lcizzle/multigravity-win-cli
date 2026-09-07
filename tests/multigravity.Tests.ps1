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
    Prepare-LaunchCredential "prof2" -ForceSwitch | Out-Null
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

    # 1. Pipeline Pass-Through & Single-Execution Verification (-p - stripped)
    $pipeLines = @("streamed prompt line 1", "streamed prompt line 2", "streamed prompt line 3")
    $pipeLines | & $MgScript cli pipe_prof -p -

    $calls1 = (Get-Content $mockCallCount -ErrorAction SilentlyContinue).Count
    Assert-Equal $calls1 1 "Pipeline input executes CLI profile exactly once (no per-line multi-execution)"

    $args1 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args1 "" "'-p -' flag is stripped when streaming pipeline input to CLI app"

    $stdinContent = if (Test-Path $mockStdin) { (Get-Content $mockStdin -Raw).Trim() } else { "" }
    $expectedStdin = ($pipeLines -join "`r`n")
    Assert-Equal $stdinContent $expectedStdin "Full multi-line pipeline buffer correctly streamed into CLI stdin"

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

    # 4. 'agy' alias with pipeline streaming (-p - stripped)
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    "single line prompt" | & $MgScript agy pipe_prof -p -
    $calls3 = (Get-Content $mockCallCount -ErrorAction SilentlyContinue).Count
    Assert-Equal $calls3 1 "'agy' alias executes CLI profile exactly once"
    $args3 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args3 "" "'agy' alias strips -p - when streaming pipeline"
    $stdin3 = if (Test-Path $mockStdin) { (Get-Content $mockStdin -Raw).Trim() } else { "" }
    Assert-Equal $stdin3 "single line prompt" "'agy' alias streams pipeline buffer"

    # 5. Pipeline with additional arguments (preserves other flags while stripping -p -)
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    "multi-arg prompt" | & $MgScript cli pipe_prof --verbose -p - --model gemini-2.5-pro
    $args4 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args4 "--verbose --model gemini-2.5-pro" "Other CLI flags preserved while stripping -p -"
    $stdin4 = if (Test-Path $mockStdin) { (Get-Content $mockStdin -Raw).Trim() } else { "" }
    Assert-Equal $stdin4 "multi-arg prompt" "Pipeline stream delivered alongside other flags"

    # 6. Non-pipelined invocation with -p preserved
    Remove-Item $mockCallCount, $mockLog, $mockStdin -Force -ErrorAction SilentlyContinue
    & $MgScript cli pipe_prof -p "non-piped prompt"
    $args5 = if (Test-Path $mockLog) { (Get-Content $mockLog -Raw).Trim() } else { "" }
    Assert-Equal $args5 "-p non-piped prompt" "Non-pipelined -p argument preserved unchanged"
    Assert-True (!(Test-Path $mockStdin)) "Non-pipelined execution does not stream stdin"

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
        profile_stack = @("test_live")
        active_vault_profile = "test_live"
    }
    Save-ActiveInstancesRegistry $regData
    $prunedReg = Get-ActiveInstancesRegistry
    Assert-Equal $prunedReg.instances.Count 1 "Get-ActiveInstancesRegistry prunes dead process instances"
    Assert-Equal $prunedReg.instances[0].pid $PID "Remaining instance is live process"
} finally {
    Remove-Item -Recurse -Force $suite7Base -ErrorAction SilentlyContinue
}

$suite7Base2 = "$testRoot\mg_mutex_test_$PID"
$env:MULTIGRAVITY_HOME = $suite7Base2
try {
    New-Item -ItemType Directory -Force -Path "$suite7Base2\profA" | Out-Null
    New-Item -ItemType Directory -Force -Path "$suite7Base2\profB" | Out-Null
    
    Prepare-LaunchCredential -PROFILE "profA" -ProcessId $PID -ProcessType "cli" -StartTime $proc.StartTime | Out-Null
    
    $blocked = $false
    try {
        Prepare-LaunchCredential -PROFILE "profB"
    } catch [MultigravityExitException] {
        $blocked = ($_.Exception.ExitCode -eq 1)
    } catch {
        $blocked = $true
    }
    Assert-True $blocked "Prepare-LaunchCredential blocks distinct profile when another profile has active instances"

    Prepare-LaunchCredential -PROFILE "profB" -ForceSwitch | Out-Null
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "profB" "Force-switch sets profB as active profile"
    Assert-True ($env:MULTIGRAVITY_PROFILE_STACK -like "*profA*") "Displacement stack holds profA"
    
    Restore-PostLaunchCredential -PROFILE "profB" -HadSavedCred $false
    Assert-Equal $env:MULTIGRAVITY_ACTIVE_PROFILE "profA" "Restores profA after profB exits"
    
    Restore-PostLaunchCredential -PROFILE "profA" -HadSavedCred $false -ProcessId $PID
    Assert-True ([string]::IsNullOrEmpty($env:MULTIGRAVITY_ACTIVE_PROFILE)) "All profiles cleared from active state"
} finally {
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