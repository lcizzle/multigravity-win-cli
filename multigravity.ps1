<#
.SYNOPSIS
Run multiple Antigravity profiles at the same time.
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Mandatory = $false, DontShow = $true)]
    [string]$cmd,

    [Parameter(Mandatory = $false, DontShow = $true)]
    [string]$p,

    [Parameter(ValueFromPipeline = $true)]
    [psobject]$InputObject,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AllRawArgs
)

begin {
    $script:IsDotSourced = ($MyInvocation.InvocationName -eq '.')

    class MultigravityExitException : System.Exception {
        [int]$ExitCode
        MultigravityExitException([int]$code) : base("Exit: $code") {
            $this.ExitCode = $code
        }
    }

    function Exit-Multigravity {
        param([int]$Code = 0)
        $global:LASTEXITCODE = $Code
        if (-not $script:IsDotSourced) {
            exit $Code
        } else {
            throw [MultigravityExitException]::new($Code)
        }
    }

    $pipelineBuffer = [System.Collections.Generic.List[string]]::new()

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

function Get-BaseDir {
    if ($env:MULTIGRAVITY_HOME) {
        return $env:MULTIGRAVITY_HOME
    }
    return "$ROOT_USERPROFILE\.config\multigravity\profiles"
}

$BASE = Get-BaseDir
$env:MULTIGRAVITY_ROOT_USERPROFILE = $ROOT_USERPROFILE
$env:MULTIGRAVITY_HOME = $BASE

function Find-Antigravity {
    $paths = @(
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity\Antigravity.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
        "$env:PROGRAMFILES\Antigravity\Antigravity.exe",
        "${env:ProgramFiles(x86)}\Antigravity\Antigravity.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    
    # Try to find in PATH
    $exeCommand = Get-Command antigravity.exe, antigravity -ErrorAction SilentlyContinue
    if ($exeCommand) {
        if ($exeCommand -is [array]) { return $exeCommand[0].Source }
        return $exeCommand.Source
    }
    
    return $null
}

$APP = if ($env:MULTIGRAVITY_APP) { $env:MULTIGRAVITY_APP } else { Find-Antigravity }

function Find-AntigravityCLI {
    $paths = @(
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity\bin\agy.exe",
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity CLI\agy.exe",
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity CLI\bin\agy.exe",
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity\bin\agy.cmd",
        "$ROOT_USERPROFILE\AppData\Local\Programs\Antigravity CLI\bin\agy.cmd",
        "$env:LOCALAPPDATA\Programs\Antigravity\bin\agy.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\bin\agy.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\agy.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity\bin\agy.cmd",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\bin\agy.cmd",
        "$env:PROGRAMFILES\Antigravity\bin\agy.exe",
        "$env:PROGRAMFILES\Antigravity CLI\bin\agy.exe",
        "$env:PROGRAMFILES\Antigravity\bin\agy.cmd",
        "$env:PROGRAMFILES\Antigravity CLI\bin\agy.cmd",
        "${env:ProgramFiles(x86)}\Antigravity\bin\agy.exe",
        "${env:ProgramFiles(x86)}\Antigravity\bin\agy.cmd"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    
    # Try to find in PATH (prefer .exe)
    $cmdObj = Get-Command agy.exe, agy.cmd, agy -ErrorAction SilentlyContinue
    if ($cmdObj) {
        if ($cmdObj -is [array]) { return $cmdObj[0].Source }
        return $cmdObj.Source
    }
    
    return $null
}

$CLI_APP = if ($env:MULTIGRAVITY_CLI_APP) { $env:MULTIGRAVITY_CLI_APP } else { Find-AntigravityCLI }

function Get-TemplatesDir {
    return "$BASE\.templates"
}

function Get-SystemDataDir {
    return "$ROOT_USERPROFILE\AppData\Roaming\Antigravity"
}

function Get-SystemExtensionsDir {
    return "$ROOT_USERPROFILE\.antigravity\extensions"
}

function Get-SystemGeminiDir {
    return "$ROOT_USERPROFILE\.gemini"
}

if (-not ([System.Management.Automation.PSTypeName]'MultigravityCredVault').Type) {
    $refAssemblies = @("System.Security")
    if ($PSEdition -eq "Core" -or $IsCoreCLR) {
        $refAssemblies += "System.Security.Cryptography.ProtectedData"
    }
    Add-Type -ReferencedAssemblies $refAssemblies -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class MultigravityCredVault {
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
    public static extern void CredFree(IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredDelete(string target, int type, int reservedFlag);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string ExportCredential(string target, out string userName) {
        IntPtr ptr;
        userName = null;
        if (CredRead(target, 1, 0, out ptr)) {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            userName = cred.UserName;
            byte[] bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, (int)cred.CredentialBlobSize);
            CredFree(ptr);

            try {
                byte[] protectedBytes = System.Security.Cryptography.ProtectedData.Protect(
                    bytes, null, System.Security.Cryptography.DataProtectionScope.CurrentUser
                );
                return Convert.ToBase64String(protectedBytes);
            } catch {
                return null;
            }
        }
        return null;
    }

    public static bool ImportCredential(string target, string userName, string base64Blob) {
        if (string.IsNullOrEmpty(base64Blob)) return false;
        try {
            byte[] rawBytes = Convert.FromBase64String(base64Blob);
            byte[] bytes = null;
            try {
                // Attempt DPAPI unprotect (new format)
                bytes = System.Security.Cryptography.ProtectedData.Unprotect(
                    rawBytes, null, System.Security.Cryptography.DataProtectionScope.CurrentUser
                );
            } catch {
                // Fallback for legacy unencrypted base64 blobs
                bytes = rawBytes;
            }

            IntPtr blobPtr = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, blobPtr, bytes.Length);

            CREDENTIAL cred = new CREDENTIAL();
            cred.Type = 1; // CRED_TYPE_GENERIC
            cred.TargetName = target;
            cred.UserName = string.IsNullOrEmpty(userName) ? "antigravity" : userName;
            cred.CredentialBlobSize = (uint)bytes.Length;
            cred.CredentialBlob = blobPtr;
            cred.Persist = 2; // CRED_PERSIST_LOCAL_MACHINE

            bool result = CredWrite(ref cred, 0);
            Marshal.FreeHGlobal(blobPtr);
            return result;
        } catch {
            return false;
        }
    }

    public static bool RemoveCredential(string target) {
        return CredDelete(target, 1, 0);
    }
}
"@ -ErrorAction SilentlyContinue
}

function Get-TargetCredName {
    if ($env:MULTIGRAVITY_TEST_CRED_TARGET) {
        return $env:MULTIGRAVITY_TEST_CRED_TARGET
    }
    return "gemini:antigravity"
}

$TARGET_CRED_NAME = Get-TargetCredName

function Test-CredentialFileValid {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path)) {
        return $false
    }
    try {
        $json = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json.blob)) {
            return $false
        }
        $rawBytes = [System.Convert]::FromBase64String($json.blob)
        return ($rawBytes.Length -gt 0)
    } catch {
        return $false
    }
}

function Test-ProfileHasValidCredential {
    param($PROFILE)
    $BASE = Get-BaseDir
    $gProf = Get-GlobalProfile
    if ($gProf -and $gProf -eq $PROFILE) {
        $credPath = "$BASE\.global_credentials.json"
        if (Test-CredentialFileValid $credPath) { return $true }
    }
    $credPath = "$BASE\$PROFILE\.credentials.json"
    return (Test-CredentialFileValid $credPath)
}

function Get-GlobalProfile {
    $BASE = Get-BaseDir
    $globalFile = "$BASE\.global_profile"
    if (Test-Path $globalFile) {
        $g = (Get-Content $globalFile -Raw).Trim()
        if (![string]::IsNullOrWhiteSpace($g)) {
            return $g
        }
    }
    return $null
}

function Set-GlobalProfile {
    param($PROFILE)
    $BASE = Get-BaseDir
    if ([string]::IsNullOrWhiteSpace($PROFILE)) {
        Write-Error "Error: profile name required"
        Exit-Multigravity 1
    }
    if ($PROFILE -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-]*$") {
        Write-Error "Error: profile name must start with alphanumeric and contain only letters, numbers, or hyphens"
        Exit-Multigravity 1
    }
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }
    Set-Content -Path "$BASE\.global_profile" -Value $PROFILE -Encoding UTF8
    Write-Host "Set global profile name to '$PROFILE'"

    if (Test-Path $BASE) {
        $sharedProfiles = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\.shared" }
        foreach ($sp in $sharedProfiles) {
            Sync-SharedProfile $sp.Name
        }
    }
}

function Unset-GlobalProfile {
    $BASE = Get-BaseDir
    $globalFile = "$BASE\.global_profile"
    if (Test-Path $globalFile) {
        Remove-Item $globalFile -Force -ErrorAction SilentlyContinue
    }
    $globalCred = "$BASE\.global_credentials.json"
    if (Test-Path $globalCred) {
        Remove-Item $globalCred -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Unset global profile configuration and removed global credentials."
}

function Save-GlobalCredential {
    param($PROFILE)
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    if ($PROFILE) {
        Set-GlobalProfile $PROFILE
    }
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }
    $user = $null
    $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
    if ($blob) {
        $credPath = "$BASE\.global_credentials.json"
        $data = @{
            userName = $user
            blob     = $blob
            updated  = (Get-Date).ToString("o")
        } | ConvertTo-Json
        Set-Content -Path $credPath -Value $data -Encoding UTF8
        $gName = Get-GlobalProfile
        $nameInfo = if ($gName) { " for global profile '$gName'" } else { "" }
        Write-Host "Saved global credential$nameInfo."
        return $true
    } else {
        Write-Host "No active credential found in Windows Credential Manager under '$credTarget'."
        return $false
    }
}

function Remove-GlobalCredential {
    $BASE = Get-BaseDir
    $credPath = "$BASE\.global_credentials.json"
    if (Test-Path $credPath) {
        Remove-Item $credPath -Force
        Write-Host "Removed saved global credential file."
    } else {
        Write-Host "No saved global credential file found."
    }
}

function Save-CredentialToProfile {
    param($PROFILE)
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $g = Get-GlobalProfile
    if ($g -and $g -eq $PROFILE) {
        Save-GlobalCredential $PROFILE | Out-Null
        return $true
    }
    $profileDir = "$BASE\$PROFILE"
    if (!(Test-Path $profileDir)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        Exit-Multigravity 1
    }
    $user = $null
    $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
    if ($blob) {
        $credPath = "$profileDir\.credentials.json"
        $data = @{
            userName = $user
            blob     = $blob
            updated  = (Get-Date).ToString("o")
        } | ConvertTo-Json
        Set-Content -Path $credPath -Value $data -Encoding UTF8
        Write-Host "Saved credential to profile '$PROFILE'"
        return $true
    } else {
        Write-Host "No active credential found in Windows Credential Manager under '$credTarget'."
        return $false
    }
}

function Remove-ProfileCredential {
    param($PROFILE)
    $BASE = Get-BaseDir
    $g = Get-GlobalProfile
    if ($g -and $g -eq $PROFILE) {
        Remove-GlobalCredential
        return
    }
    $profileDir = "$BASE\$PROFILE"
    if (!(Test-Path $profileDir)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        Exit-Multigravity 1
    }
    $credPath = "$profileDir\.credentials.json"
    if (Test-Path $credPath) {
        Remove-Item $credPath -Force
        Write-Host "Removed saved credentials for profile '$PROFILE'"
    } else {
        Write-Host "No saved credentials found for profile '$PROFILE'"
    }
}

function Restore-GlobalCredential {
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalCredPath = "$BASE\.global_credentials.json"
    if (Test-Path $globalCredPath) {
        try {
            $json = Get-Content $globalCredPath -Raw | ConvertFrom-Json
            if ($json.blob) {
                [MultigravityCredVault]::ImportCredential($credTarget, $json.userName, $json.blob) | Out-Null
                $gName = Get-GlobalProfile
                $nameInfo = if ($gName) { " ('$gName')" } else { "" }
                Write-Host "Restored global profile credential vault$nameInfo."
                if ($gName) {
                    Set-Content -Path "$BASE\.active_profile" -Value $gName -Encoding UTF8
                } else {
                    Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
                }
                return
            }
        } catch {}
    }
    [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
    Write-Host "Cleared credential vault (no global credential to restore)."
    Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
}

function Invoke-WithVaultMutex {
    param([scriptblock]$Action)
    $timeoutMs = if ($env:MULTIGRAVITY_MUTEX_TIMEOUT_MS) { [int]$env:MULTIGRAVITY_MUTEX_TIMEOUT_MS } else { 10000 }
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutexName = "Local\Multigravity_Vault_Mutex_$userSid"
    
    $mutex = $null
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try {
            $acquired = $mutex.WaitOne($timeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            Write-Error "Error: Timeout acquiring Multigravity credential vault mutex after ${timeoutMs}ms. Another process is actively modifying the vault."
            Exit-Multigravity 1
        }
        & $Action
    } finally {
        if ($mutex -and $acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        if ($mutex) {
            try { $mutex.Dispose() } catch {}
        }
    }
}

function Test-InstanceAlive {
    param([pscustomobject]$Entry)
    if (-not $Entry -or -not $Entry.pid) { return $false }
    $proc = Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($proc.ProcessName -notin @('agy', 'Antigravity', 'pwsh', 'powershell')) { return $false }
    if ($Entry.started) {
        try {
            $procUtc = $proc.StartTime.ToUniversalTime()
            $entryUtc = ([datetime]$Entry.started).ToUniversalTime()
            $diff = [Math]::Abs(($procUtc - $entryUtc).TotalSeconds)
            if ($diff -gt 2) { return $false }
        } catch { return $false }
    }
    return $true
}

function Get-InstanceRegistryFile {
    $BASE = Get-BaseDir
    return "$BASE\.active_instances.json"
}

function Get-ActiveInstancesRegistry {
    $regFile = Get-InstanceRegistryFile
    if (Test-Path $regFile) {
        try {
            $data = Get-Content $regFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $pruned = @()
            if ($data.instances) {
                foreach ($inst in $data.instances) {
                    if (Test-InstanceAlive $inst) {
                        $pruned += $inst
                    }
                }
            }
            $data.instances = $pruned
            return $data
        } catch {}
    }
    return [PSCustomObject]@{
        instances = @()
        profile_stack = @()
        active_vault_profile = $null
    }
}

function Save-ActiveInstancesRegistry {
    param([PSCustomObject]$Registry)
    $regFile = Get-InstanceRegistryFile
    $BASE = Get-BaseDir
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }
    $json = $Registry | ConvertTo-Json -Depth 5
    Set-Content -Path $regFile -Value $json -Encoding UTF8 -Force
}

function Register-ActiveInstance {
    param(
        $PROFILE,
        [int]$ProcessId,
        [string]$ProcessType = "app",
        [System.DateTime]$StartTime
    )
    if ($ProcessId -le 0) { return }
    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        $startIso = if ($null -ne $StartTime -and $StartTime -ne [System.DateTime]::MinValue) {
            $StartTime.ToUniversalTime().ToString("o")
        } else {
            (Get-Date).ToUniversalTime().ToString("o")
        }
        $inst = [PSCustomObject]@{
            pid = $ProcessId
            profile = $PROFILE
            type = $ProcessType
            started = $startIso
        }
        $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $ProcessId }) + @($inst)
        Save-ActiveInstancesRegistry $reg
    }
}

function Prepare-LaunchCredential {
    param(
        $PROFILE,
        [int]$ProcessId = 0,
        [string]$ProcessType = "cli",
        [System.DateTime]$StartTime,
        [switch]$ForceSwitch
    )
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $profileDir = "$BASE\$PROFILE"
    $credPath   = "$profileDir\.credentials.json"
    
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }

    $hadSavedCredResult = Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        # Check for collision with running instances of a DIFFERENT profile
        $activeOther = @($reg.instances | Where-Object { $_.profile -ne $PROFILE })
        if ($activeOther.Count -gt 0 -and -not $ForceSwitch) {
            $otherProfiles = ($activeOther | Select-Object -ExpandProperty profile -Unique) -join ', '
            $otherPids = ($activeOther | Select-Object -ExpandProperty pid) -join ', '
            Write-Error "Error: Profile '$otherProfiles' (PID(s): $otherPids) is currently running. Concurrently running distinct profiles is restricted to prevent token collision on Windows Credential Manager ('$credTarget'). Pass --force-switch to proceed."
            Exit-Multigravity 1
        }

        # Check if this profile is already the active vault profile
        $alreadyActive = ($reg.active_vault_profile -and $reg.active_vault_profile -eq $PROFILE)
        $hadCred = $false

        if (-not $alreadyActive) {
            # Maintain environment variable call stack for clean nested re-entrancy
            $currentActive = if ($env:MULTIGRAVITY_ACTIVE_PROFILE) { $env:MULTIGRAVITY_ACTIVE_PROFILE } else { (Get-GlobalProfile) }
            if ($currentActive -and $currentActive -ne $PROFILE) {
                $stackEnv = if ($env:MULTIGRAVITY_PROFILE_STACK) { $env:MULTIGRAVITY_PROFILE_STACK } else { "" }
                $env:MULTIGRAVITY_PROFILE_STACK = if ($stackEnv) { "$stackEnv;$currentActive" } else { $currentActive }
            }

            if (Test-CredentialFileValid $credPath) {
                try {
                    $json = Get-Content $credPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if (![string]::IsNullOrWhiteSpace($json.blob)) {
                        $importOk = [MultigravityCredVault]::ImportCredential($credTarget, $json.userName, $json.blob)
                        if ($importOk) {
                            Write-Host "Restored credential vault for profile '$PROFILE'"
                            $hadCred = $true
                        }
                    }
                } catch {
                    Write-Host "Warning: Could not parse stored credential for profile '$PROFILE'"
                }
            }

            if (!$hadCred) {
                [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
                Write-Host "Profile '$PROFILE' starting with fresh credential state (login required)."
            }

            $reg.active_vault_profile = $PROFILE
        } else {
            $hadCred = (Test-CredentialFileValid $credPath)
        }

        # Update displacement stack
        $stackList = [System.Collections.Generic.List[string]]::new()
        if ($reg.profile_stack) {
            foreach ($item in $reg.profile_stack) {
                if ($item -ne $PROFILE) { $stackList.Add($item) }
            }
        }
        $stackList.Add($PROFILE)
        $reg.profile_stack = @($stackList)

        # Register instance if PID was provided
        if ($ProcessId -gt 0) {
            $startIso = if ($null -ne $StartTime -and $StartTime -ne [System.DateTime]::MinValue) {
                $StartTime.ToUniversalTime().ToString("o")
            } else {
                (Get-Date).ToUniversalTime().ToString("o")
            }
            $inst = [PSObject]@{
                pid = $ProcessId
                profile = $PROFILE
                type = $ProcessType
                started = $startIso
            }
            $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $ProcessId }) + @($inst)
        }

        Set-Content -Path "$BASE\.active_profile" -Value $PROFILE -Encoding UTF8
        $env:MULTIGRAVITY_ACTIVE_PROFILE = $PROFILE
        Save-ActiveInstancesRegistry $reg

        return [bool]$hadCred
    }

    return [bool]$hadSavedCredResult
}

function Restore-PostLaunchCredential {
    param(
        $PROFILE,
        [bool]$HadSavedCred,
        [int]$ProcessId = 0
    )
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalProfile = Get-GlobalProfile
    $isGlobal = ($globalProfile -and $globalProfile -eq $PROFILE)

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        # 1. Remove this instance from registry
        if ($ProcessId -gt 0) {
            $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $ProcessId })
        }

        # 2. Vault Ownership Verification on Exit:
        # Only save credentials back if active_vault_profile matches PROFILE
        if ($reg.active_vault_profile -eq $PROFILE) {
            if ($isGlobal) {
                if (!$HadSavedCred -and !(Test-ProfileHasValidCredential $PROFILE)) {
                    Save-GlobalCredential $PROFILE | Out-Null
                } else {
                    Write-Host "Global profile '$PROFILE' credential file is valid; skipping resave on exit."
                }
            } else {
                $credPath = "$BASE\$PROFILE\.credentials.json"
                if (!$HadSavedCred -and !(Test-ProfileHasValidCredential $PROFILE)) {
                    $user = $null
                    $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
                    if ($blob) {
                        $data = @{
                            userName = $user
                            blob     = $blob
                            updated  = (Get-Date).ToString("o")
                        } | ConvertTo-Json
                        Set-Content -Path $credPath -Value $data -Encoding UTF8
                        Write-Host "Saved initial credential for profile '$PROFILE'"
                    }
                } else {
                    Write-Host "Profile '$PROFILE' credential file is valid; skipping resave on exit."
                }
            }
        } else {
            Write-Host "Profile '$PROFILE' was displaced by '$($reg.active_vault_profile)'; skipping credential save on exit."
        }

        # 3. Stack Restoration:
        # Check if other instances of PROFILE are still running
        $remainingProfileInstances = @($reg.instances | Where-Object { $_.profile -eq $PROFILE })
        if ($remainingProfileInstances.Count -eq 0) {
            $reg.profile_stack = @($reg.profile_stack | Where-Object { $_ -ne $PROFILE })
        }

        # Check remaining profile_stack
        if ($reg.profile_stack -and $reg.profile_stack.Count -gt 0) {
            $parentProfile = $reg.profile_stack[-1]
            if ($env:MULTIGRAVITY_PROFILE_STACK) {
                $stackItems = @($env:MULTIGRAVITY_PROFILE_STACK -split ';' | Where-Object { $_ -ne "" })
                $remainingStack = if ($stackItems.Count -gt 1) { ($stackItems[0..($stackItems.Count - 2)]) -join ';' } else { $null }
                $env:MULTIGRAVITY_PROFILE_STACK = $remainingStack
            }
            if ($reg.active_vault_profile -ne $parentProfile) {
                if ($parentProfile -and (Test-Path "$BASE\$parentProfile\.credentials.json")) {
                    try {
                        $pJson = Get-Content "$BASE\$parentProfile\.credentials.json" -Raw | ConvertFrom-Json
                        if ($pJson.blob) {
                            [MultigravityCredVault]::ImportCredential($credTarget, $pJson.userName, $pJson.blob) | Out-Null
                            Write-Host "Restored parent credential vault for profile '$parentProfile'"
                        }
                    } catch {}
                } elseif ($parentProfile -and $parentProfile -eq $globalProfile) {
                    Restore-GlobalCredential
                }
                $reg.active_vault_profile = $parentProfile
                Set-Content -Path "$BASE\.active_profile" -Value $parentProfile -Encoding UTF8
                $env:MULTIGRAVITY_ACTIVE_PROFILE = $parentProfile
            }
        } else {
            # Zero active instances remain across all profiles
            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
            $env:MULTIGRAVITY_PROFILE_STACK = $null
            $reg.active_vault_profile = $null
            Restore-GlobalCredential
        }

        Save-ActiveInstancesRegistry $reg
    }
}

function Test-SharedProfile {
    param($name)
    $BASE = Get-BaseDir
    return Test-Path "$BASE\$name\.shared"
}

function Process-ProfileCredentialFlags {
    param($PROFILE, [string[]]$AllArgs)

    $isGlobalFlag         = $AllArgs -contains "--global"
    $isSaveFlag           = ($AllArgs -contains "--save_credential" -or $AllArgs -contains "--save-credential" -or $AllArgs -contains "--save_credentials" -or $AllArgs -contains "--save")
    $isRemoveCredsFlag    = ($AllArgs -contains "--remove_credentials" -or $AllArgs -contains "--remove-credentials" -or $AllArgs -contains "--remove-credential")

    $gProf = Get-GlobalProfile
    $isGlobal = ($isGlobalFlag -or ($gProf -and $gProf -eq $PROFILE))

    if ($isGlobal) {
        Set-GlobalProfile $PROFILE
        if ($isSaveFlag) {
            Save-GlobalCredential $PROFILE | Out-Null
            return $true
        }
        if ($isRemoveCredsFlag) {
            Remove-GlobalCredential
            return $true
        }
    } else {
        if ($isSaveFlag) {
            Save-CredentialToProfile $PROFILE | Out-Null
            return $true
        }
        if ($isRemoveCredsFlag) {
            Remove-ProfileCredential $PROFILE
            return $true
        }
    }
    return $false
}

function Write-Usage {
    Write-Host "Usage: multigravity <command> [args]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  new <name> [options]        Create a new profile"
    Write-Host "      --global                Set this profile as the global default profile"
    Write-Host "      --shared                Share extensions & settings; isolate only accounts"
    Write-Host "      --from <template>        Seed from a saved template"
    Write-Host "      --shortcut              Create Start Menu shortcut for this profile"
    Write-Host "  global [name|save_credential|remove_credentials|unset]   Manage global profile and credentials"
    Write-Host "  <profile> --save_credential   Save current credential to profile"
    Write-Host "  <profile> --remove_credentials Remove saved credentials for a profile"
    Write-Host "  <profile> --global [--save_credential|--remove_credentials]   Set profile as global / manage credential"
    Write-Host "  list                        List existing profiles"
    Write-Host "  status                      Show running state, type, and last-used per profile"
    Write-Host "  rename <old> <new>          Rename a profile (updates shortcut if present)"
    Write-Host "  delete <name>               Delete a profile and its data"
    Write-Host "  clone <src> <dest>          Copy an existing profile"
    Write-Host "  template save <profile> <name>   Save a profile as a reusable template"
    Write-Host "  template list               List saved templates"
    Write-Host "  template delete <name>      Remove a template"
    Write-Host "  export <name> [path]        Archive a profile to a .zip file"
    Write-Host "  import <archive> [name]     Restore a profile from a .zip archive"
    Write-Host "  update                      Update multigravity to the latest version"
    Write-Host "  doctor                      Run a system diagnosis"
    Write-Host "  stats                       Show storage usage per profile"
    Write-Host "  shortcuts [profile|restore]  Create or restore Start Menu shortcuts"
    Write-Host "  completion                  Show setup instructions for shell completion"
    Write-Host "  cli <name> [args]           Launch Antigravity CLI (agy) with the given profile"
    Write-Host "  agy <name> [args]           Alias for cli"
    Write-Host "  app <name> [args]           Launch Antigravity Desktop UI with the given profile"
    Write-Host "  <name>                      Launch Antigravity Desktop UI with the given profile"
    Write-Host "  help                        Show this help"
    Write-Host ""
    Write-Host "Profile names: alphanumeric and hyphens only (e.g. work, personal, test-1)"
}

function Validate-Name {
    param($name)
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Error "Error: profile name required"
        Exit-Multigravity 1
    }
    if ($name -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-]*$") {
        Write-Error "Error: profile name must start with alphanumeric and contain only letters, numbers, or hyphens"
        Exit-Multigravity 1
    }
}

function Invoke-CreateProfile {
    param($PROFILE)
    $PROFILE_DIR = "$BASE\$PROFILE"
    
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.antigravity\extensions" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.gemini\antigravity" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.gemini\antigravity-cli" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.gemini\antigravity-ide" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.gemini\config" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\AppData\Roaming" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\AppData\Local" | Out-Null
}

function New-SharedFileLink {
    param(
        [string]$src,
        [string]$dest
    )

    $destParent = Split-Path $dest
    if (!(Test-Path $destParent)) {
        New-Item -ItemType Directory -Force -Path $destParent | Out-Null
    }

    $srcParent = Split-Path $src
    if (!(Test-Path $srcParent)) {
        New-Item -ItemType Directory -Force -Path $srcParent | Out-Null
    }

    if (!(Test-Path $src)) {
        Set-Content -Path $src -Value "{}`n" -Encoding UTF8
    }

    if (Test-Path $dest) {
        $item = Get-Item $dest -ErrorAction SilentlyContinue
        if ($item) {
            if ($item.LinkType -eq "SymbolicLink" -or $item.Attributes -match "ReparsePoint") {
                if ($item.Target -contains $src -or $item.Target -eq $src) {
                    return $true
                }
            }
        }
        Remove-Item -Force $dest -ErrorAction SilentlyContinue
    }

    $linked = $false
    try {
        New-Item -ItemType SymbolicLink -Path $dest -Target $src -ErrorAction Stop | Out-Null
        $linked = $true
    } catch {
        try {
            New-Item -ItemType HardLink -Path $dest -Target $src -ErrorAction Stop | Out-Null
            $linked = $true
        } catch {
            try {
                Copy-Item -Path $src -Destination $dest -Force -ErrorAction Stop
                $linked = $true
            } catch {}
        }
    }

    return $linked
}

function New-SharedDirJunction {
    param(
        [string]$src,
        [string]$dest
    )

    $destParent = Split-Path $dest
    if (!(Test-Path $destParent)) {
        New-Item -ItemType Directory -Force -Path $destParent | Out-Null
    }

    if (!(Test-Path $src)) {
        New-Item -ItemType Directory -Force -Path $src | Out-Null
    }

    if (Test-Path $dest) {
        $item = Get-Item $dest -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -match "ReparsePoint" -or $item.LinkType -eq "Junction" -or $item.LinkType -eq "SymbolicLink")) {
            if ($item.Target -contains $src -or $item.Target -eq $src) {
                return $true
            }
        }
        Remove-Item -Force -Recurse $dest -ErrorAction SilentlyContinue
    }

    try {
        New-Item -ItemType Junction -Path $dest -Target $src -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Sync-SharedProfile {
    param($name)
    if (!(Test-SharedProfile $name)) { return }

    $profileDir = "$BASE\$name"
    $sysData     = Get-SystemDataDir
    $sysExt      = Get-SystemExtensionsDir
    $sysGemini   = Get-SystemGeminiDir

    $userDataDir = "$profileDir\AppData\Roaming\Antigravity\User"
    if (!(Test-Path $userDataDir)) {
        New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    }
    if (!(Test-Path "$profileDir\AppData\Local")) {
        New-Item -ItemType Directory -Force -Path "$profileDir\AppData\Local" | Out-Null
    }

    # 1. Share extensions via Junction
    $extDir = "$profileDir\.antigravity\extensions"
    if (!(New-SharedDirJunction -src $sysExt -dest $extDir)) {
        Write-Warning "Failed to create extensions junction for shared profile '$name'. Shared profiles require directory junction creation privileges."
    }

    # 2. Share .gemini subdirectories directly via Junctions
    if (Test-Path $sysGemini) {
        $profGeminiDir = "$profileDir\.gemini"
        if (!(Test-Path $profGeminiDir)) {
            New-Item -ItemType Directory -Force -Path $profGeminiDir | Out-Null
        }
        foreach ($sub in @("antigravity", "antigravity-cli", "antigravity-ide", "config")) {
            $srcSub  = "$sysGemini\$sub"
            $destSub = "$profGeminiDir\$sub"
            if (Test-Path $srcSub) {
                if (!(New-SharedDirJunction -src $srcSub -dest $destSub)) {
                    Write-Warning "Failed to create .gemini\$sub junction for shared profile '$name'."
                }
            }
        }
    }

    # 3. Share Settings, Keybindings, Snippets, Tasks
    foreach ($f in @("settings.json", "keybindings.json", "snippets", "tasks.json")) {
        $src  = "$sysData\User\$f"
        $dest = "$userDataDir\$f"

        if ($f -eq "snippets") {
            if (!(New-SharedDirJunction -src $src -dest $dest)) {
                Write-Warning "Failed to create junction for '$f' in shared profile '$name'."
            }
        } else {
            if (!(New-SharedFileLink -src $src -dest $dest)) {
                Write-Warning "Failed to link '$f' for shared profile '$name'."
            }
        }
    }

    # 4. Share Global Storage (extension configuration & data, keeping login account & auth session DBs isolated)
    $sysGlobalStorage = "$sysData\User\globalStorage"
    $profGlobalStorage = "$userDataDir\globalStorage"
    if (!(Test-Path $sysGlobalStorage)) {
        New-Item -ItemType Directory -Force -Path $sysGlobalStorage | Out-Null
    }
    if (!(Test-Path $profGlobalStorage)) {
        New-Item -ItemType Directory -Force -Path $profGlobalStorage | Out-Null
    }
    $authExclusionPatterns = @("state.vscdb*", "storage.json*", "secrets.json*", "lockfile*")
    $items = Get-ChildItem -Path $sysGlobalStorage -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        $isExcluded = $false
        foreach ($pat in $authExclusionPatterns) {
            if ($item.Name -like $pat) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) { continue }
        $destItem = "$profGlobalStorage\$($item.Name)"
        if ($item.PSIsContainer) {
            if (!(New-SharedDirJunction -src $item.FullName -dest $destItem)) {
                Write-Warning "Failed to create junction for '$($item.Name)' in shared profile '$name'."
            }
        } else {
            if (!(New-SharedFileLink -src $item.FullName -dest $destItem)) {
                Write-Warning "Failed to link '$($item.Name)' for shared profile '$name'."
            }
        }
    }
}

function Invoke-CreateSharedProfile {
    param($name)
    $profileDir = "$BASE\$name"

    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    New-Item -ItemType File      -Force -Path "$profileDir\.shared" | Out-Null

    Sync-SharedProfile $name
}

function Invoke-LaunchProfile {
    param($PROFILE, $ArgsToForward)

    if (Process-ProfileCredentialFlags $PROFILE $ArgsToForward) {
        return
    }

    if ([string]::IsNullOrEmpty($APP) -or !(Test-Path $APP)) {
        Write-Error "Error: Antigravity Desktop App not found"
        Exit-Multigravity 1
    }

    $gProf = Get-GlobalProfile
    $isGlobal = ($gProf -and $gProf -eq $PROFILE)
    $isShared = Test-SharedProfile $PROFILE
    $forceSwitch = ($ArgsToForward -contains "--force-switch" -or $ArgsToForward -contains "--displace")

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!$isGlobal -and !(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        Exit-Multigravity 1
    }

    $cleanForward = if ($ArgsToForward) {
        @($ArgsToForward | Where-Object {
            $_ -ne "--global" -and
            $_ -ne "--save" -and
            $_ -ne "--save_credential" -and
            $_ -ne "--save-credential" -and
            $_ -ne "--save_credentials" -and
            $_ -ne "--remove_credentials" -and
            $_ -ne "--remove-credentials" -and
            $_ -ne "--remove-credential" -and
            $_ -ne "--force-switch" -and
            $_ -ne "--displace"
        })
    } else { @() }

    $targetName = if ($isGlobal) { "global profile '$PROFILE'" } else { "profile '$PROFILE'" }
    Write-Host "Launching Antigravity Desktop App for $targetName"

    if ($isShared) {
        Sync-SharedProfile $PROFILE
    }

    $hadSavedCred = Prepare-LaunchCredential -PROFILE $PROFILE -ForceSwitch:$forceSwitch
    $desktopProcess = $null

    $oldUserProfile  = $env:USERPROFILE
    $oldAppData      = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA

    try {
        $userDataDir = if ($isGlobal) { "$ROOT_USERPROFILE\AppData\Roaming\Antigravity" } else { "$PROFILE_DIR\AppData\Roaming\Antigravity" }
        $extDir = if ($isGlobal) { "$ROOT_USERPROFILE\.antigravity\extensions" } else { "$PROFILE_DIR\.antigravity\extensions" }

        $launchArgs = @(
            "--user-data-dir", $userDataDir,
            "--extensions-dir", $extDir,
            "--password-store=basic"
        )
        if ($cleanForward) {
            $launchArgs += $cleanForward
        }

        # For shared profiles, run in native Windows user environment so internal terminals have full host access
        if (!$isShared -and !$isGlobal) {
            $env:USERPROFILE  = $PROFILE_DIR
            $env:APPDATA      = "$PROFILE_DIR\AppData\Roaming"
            $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"
        }

        $desktopProcess = Start-Process -FilePath $APP -ArgumentList $launchArgs -PassThru
        if ($desktopProcess) {
            Register-ActiveInstance -PROFILE $PROFILE -ProcessId $desktopProcess.Id -ProcessType "app" -StartTime $desktopProcess.StartTime
            $desktopProcess.WaitForExit()
        }
    } finally {
        if (!$isShared -and !$isGlobal) {
            $env:USERPROFILE  = $oldUserProfile
            $env:APPDATA      = $oldAppData
            $env:LOCALAPPDATA = $oldLocalAppData
        }

        $childPid = if ($desktopProcess) { $desktopProcess.Id } else { 0 }
        Restore-PostLaunchCredential -PROFILE $PROFILE -HadSavedCred $hadSavedCred -ProcessId $childPid
    }
}

function Invoke-LaunchCLIProfile {
    param($PROFILE, $ArgsToForward)

    if (Process-ProfileCredentialFlags $PROFILE $ArgsToForward) {
        return
    }

    if ([string]::IsNullOrEmpty($CLI_APP) -or !(Test-Path $CLI_APP)) {
        Write-Error "Error: Antigravity CLI (agy) not found"
        Exit-Multigravity 1
    }

    $gProf = Get-GlobalProfile
    $isGlobal = ($gProf -and $gProf -eq $PROFILE)
    $isShared = Test-SharedProfile $PROFILE
    $forceSwitch = ($ArgsToForward -contains "--force-switch" -or $ArgsToForward -contains "--displace")

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!$isGlobal -and !(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        Exit-Multigravity 1
    }

    $targetName = if ($isGlobal) { "global profile '$PROFILE'" } else { "profile '$PROFILE'" }
    Write-Host "Launching Antigravity CLI for $targetName"

    if ($isShared) {
        Sync-SharedProfile $PROFILE
    }

    $cleanForwardArgs = if ($ArgsToForward) {
        $filtered = @($ArgsToForward | Where-Object {
            $_ -ne "--global" -and
            $_ -ne "--save" -and
            $_ -ne "--save_credential" -and
            $_ -ne "--save-credential" -and
            $_ -ne "--save_credentials" -and
            $_ -ne "--remove_credentials" -and
            $_ -ne "--remove-credentials" -and
            $_ -ne "--remove-credential" -and
            $_ -ne "--force-switch" -and
            $_ -ne "--displace"
        })
        if ($pipelineBuffer -and $pipelineBuffer.Count -gt 0) {
            $res = [System.Collections.Generic.List[string]]::new()
            $skipNext = $false
            for ($i = 0; $i -lt $filtered.Count; $i++) {
                if ($skipNext) { $skipNext = $false; continue }
                if (($filtered[$i] -in @("-p", "--print", "--prompt")) -and ($i + 1 -lt $filtered.Count) -and ($filtered[$i + 1] -eq "-")) {
                    $skipNext = $true
                    continue
                }
                if ($filtered[$i] -match '^(-p|--print|--prompt)=-$') {
                    continue
                }
                $res.Add($filtered[$i])
            }
            @($res)
        } else {
            $filtered
        }
    } else { @() }

    $currentProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $hadSavedCred = Prepare-LaunchCredential -PROFILE $PROFILE -ProcessId $currentProc.Id -ProcessType "cli" -StartTime $currentProc.StartTime -ForceSwitch:$forceSwitch

    $oldUserProfile  = $env:USERPROFILE
    $oldAppData      = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    $cliExitCode = 0

    try {
        # For shared profiles, run in native Windows user environment (USERPROFILE, APPDATA, LOCALAPPDATA intact)
        if (!$isShared -and !$isGlobal) {
            $env:USERPROFILE  = $PROFILE_DIR
            $env:APPDATA      = "$PROFILE_DIR\AppData\Roaming"
            $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"
        }

        if ($pipelineBuffer -and $pipelineBuffer.Count -gt 0) {
            $pipelineBuffer | & $CLI_APP @cleanForwardArgs
        } else {
            & $CLI_APP @cleanForwardArgs
        }
        $cliExitCode = $LASTEXITCODE
    } finally {
        if (!$isShared -and !$isGlobal) {
            $env:USERPROFILE  = $oldUserProfile
            $env:APPDATA      = $oldAppData
            $env:LOCALAPPDATA = $oldLocalAppData
        }

        Restore-PostLaunchCredential -PROFILE $PROFILE -HadSavedCred $hadSavedCred -ProcessId $currentProc.Id
    }

    if ($null -ne $cliExitCode) {
        $global:LASTEXITCODE = $cliExitCode
        Exit-Multigravity $cliExitCode
    }
}

function Invoke-ListProfiles {
    Write-Host "Existing profiles:"
    $globalProf = Get-GlobalProfile
    if (Test-Path $BASE) {
        $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.PSIsContainer -and $_.Name -ne ".templates" }
        if ($profiles.Count -gt 0) {
            foreach ($p in $profiles) {
                $gTag = if ($globalProf -and $p.Name -eq $globalProf) { " (global)" } else { "" }
                Write-Host "$($p.Name)$gTag"
            }
        }
        elseif ($profiles -is [System.IO.DirectoryInfo]) {
            $gTag = if ($globalProf -and $profiles.Name -eq $globalProf) { " (global)" } else { "" }
            Write-Host "$($profiles.Name)$gTag"
        }
        else {
            Write-Host "(none)"
        }
    }
    else {
        Write-Host "(none)"
    }
}

function Invoke-CreateShortcut {
    param($PROFILE)
    $APP_NAME = "Multigravity $PROFILE"
    $SHORTCUT_PATH = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\$APP_NAME.lnk"
    
    $SCRIPT_PATH = $MyInvocation.MyCommand.Path
    # If script path is empty (e.g. running from prompt), try to find it
    if ([string]::IsNullOrEmpty($SCRIPT_PATH)) {
        $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
        if ($cmdObj) { $SCRIPT_PATH = $cmdObj.Source }
    }
    
    $WshShell = New-Object -comObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($SHORTCUT_PATH)
    $Shortcut.TargetPath = "powershell.exe"
    $escapedScriptPath = $SCRIPT_PATH -replace "'", "''"
    $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$escapedScriptPath' $PROFILE`""
    if ($APP) {
        $Shortcut.IconLocation = "$APP, 0"
    }
    $shortcutDir = [System.IO.Path]::GetDirectoryName($SHORTCUT_PATH)
    if (!(Test-Path $shortcutDir)) {
        New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    }
    $Shortcut.Save()

    Write-Host "Shortcut created: $SHORTCUT_PATH"
}

function Invoke-NewProfile {
    param($name, [string[]]$extraArgs)

    $shared        = $false
    $fromTpl       = ""
    $isGlobal      = $false
    $createShortcut = $false
    $i = 0
    while ($i -lt $extraArgs.Count) {
        switch ($extraArgs[$i]) {
            "--shared"   { $shared = $true }
            "--from"     { $i++; if ($i -lt $extraArgs.Count) { $fromTpl = $extraArgs[$i] } }
            "--global"   { $isGlobal = $true }
            "--shortcut" { $createShortcut = $true }
            "--shortcuts"{ $createShortcut = $true }
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Error "Error: profile name required"
        Exit-Multigravity 1
    }

    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (Test-Path $profileDir) {
        Write-Error "Error: profile '$name' already exists"
        Exit-Multigravity 1
    }

    New-Item -ItemType Directory -Force -Path $BASE | Out-Null

    if ($fromTpl) {
        $tplPath = "$(Get-TemplatesDir)\$fromTpl"
        if (!(Test-Path $tplPath)) {
            Write-Error "Error: template '$fromTpl' not found. Run: multigravity template list"
            Exit-Multigravity 1
        }
        Write-Host "Creating profile '$name' from template '$fromTpl'..."
        Copy-Item -Path $tplPath -Destination $profileDir -Recurse
    } elseif ($shared) {
        Invoke-CreateSharedProfile $name
    } else {
        Invoke-CreateProfile $name
    }

    Write-Host "Created profile '$name'"

    if ($isGlobal) {
        Set-GlobalProfile $name
    }

    if ($createShortcut) {
        Invoke-CreateShortcut $name
    }
}

function Invoke-DeleteProfile {
    param($PROFILE)
    Validate-Name $PROFILE

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        Exit-Multigravity 1
    }

    $confirm = Read-Host "Delete profile '$PROFILE' and all its data? [y/N]"
    if ($confirm -match "^[Yy]$") {
        try {
            Remove-Item -Recurse -Force $PROFILE_DIR -ErrorAction Stop
            
            $SHORTCUT_PATH = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Multigravity $PROFILE.lnk"
            if (Test-Path $SHORTCUT_PATH) {
                Remove-Item -Force $SHORTCUT_PATH
                Write-Host "Removed shortcut: $SHORTCUT_PATH"
            }

            $g = Get-GlobalProfile
            if ($g -and $g -eq $PROFILE) {
                Unset-GlobalProfile
            }

            Write-Host "Deleted profile '$PROFILE'"
        } catch {
            Write-Error "Error: could not delete profile directory. Ensure Antigravity is closed and no files are in use."
            Write-Host "Details: $_"
        }
    }
    else {
        Write-Host "Aborted."
    }
}

function Invoke-RenameProfile {
    param($OLD, $NEW)
    Validate-Name $OLD
    Validate-Name $NEW

    $OLD_DIR = "$BASE\$OLD"
    $NEW_DIR = "$BASE\$NEW"

    if (!(Test-Path $OLD_DIR)) {
        Write-Error "Error: profile '$OLD' does not exist"
        Exit-Multigravity 1
    }
    if (Test-Path $NEW_DIR) {
        Write-Error "Error: profile '$NEW' already exists"
        Exit-Multigravity 1
    }

    Rename-Item -Path $OLD_DIR -NewName $NEW

    $g = Get-GlobalProfile
    if ($g -and $g -eq $OLD) {
        Set-Content -Path "$BASE\.global_profile" -Value $NEW -Encoding UTF8
    }

    $OLD_SHORTCUT = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Multigravity $OLD.lnk"
    if (Test-Path $OLD_SHORTCUT) {
        Remove-Item -Force $OLD_SHORTCUT
        Invoke-CreateShortcut $NEW
    }

    Write-Host "Renamed profile '$OLD' to '$NEW'"
}

function Invoke-CloneProfile {
    param($SRC, $DEST, [string[]]$extraArgs)
    Validate-Name $SRC
    Validate-Name $DEST

    $SRC_DIR = "$BASE\$SRC"
    $DEST_DIR = "$BASE\$DEST"

    if (!(Test-Path $SRC_DIR)) {
        Write-Error "Error: source profile '$SRC' does not exist"
        Exit-Multigravity 1
    }
    if (Test-Path $DEST_DIR) {
        Write-Error "Error: destination profile '$DEST' already exists"
        Exit-Multigravity 1
    }

    Write-Host "Cloning profile '$SRC' to '$DEST'..."
    Copy-Item -Path $SRC_DIR -Destination $DEST_DIR -Recurse
    if (Test-SharedProfile $SRC) {
        New-Item -ItemType File -Force -Path "$DEST_DIR\.shared" | Out-Null
        Sync-SharedProfile $DEST
    }

    if ($extraArgs -contains "--shortcut" -or $extraArgs -contains "--shortcuts") {
        Invoke-CreateShortcut $DEST
    }

    Write-Host "Successfully cloned '$SRC' to '$DEST'"
}

function Get-FolderSize {
    param($Path)
    $size = (Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($size -ge 1GB) { "{0:N2} GB" -f ($size / 1GB) }
    elseif ($size -ge 1MB) { "{0:N2} MB" -f ($size / 1MB) }
    elseif ($size -ge 1KB) { "{0:N2} KB" -f ($size / 1KB) }
    else { "$size B" }
}

function Invoke-ProfileStats {
    if (!(Test-Path $BASE)) {
        Write-Host "No profiles found."
        return
    }

    Write-Host "Profile Storage Usage:"
    Write-Host ("{0,-20} {1,-10} {2,-10}" -f "PROFILE", "SIZE", "EXTENSIONS")
    Write-Host ("{0,-20} {1,-10} {2,-10}" -f "-------", "----", "----------")

    $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.Name -ne ".templates" }
    foreach ($p in $profiles) {
        $size = Get-FolderSize $p.FullName
        $extPath = Join-Path $p.FullName ".antigravity\extensions"
        $extCount = if (Test-Path $extPath) { (Get-ChildItem $extPath).Count } else { 0 }
        Write-Host ("{0,-20} {1,-10} {2,-10}" -f $p.Name, $size, $extCount)
    }

    Write-Host ""
    $total = Get-FolderSize $BASE
    Write-Host "Total usage: $total"
}

function Invoke-RestoreShortcuts {
    param([switch]$Force)

    if (!(Test-Path $BASE)) {
        Write-Host "No profiles found."
        return
    }

    $profiles = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike ".*" }
    $globalProf = Get-GlobalProfile

    $profileNames = @()
    if ($profiles) {
        $profileNames += ($profiles | Select-Object -ExpandProperty Name)
    }
    if ($globalProf -and ($profileNames -notcontains $globalProf)) {
        $profileNames += $globalProf
    }

    if (!$profileNames -or $profileNames.Count -eq 0) {
        Write-Host "No profiles found."
        return
    }

    $createdCount = 0
    $skippedCount = 0

    foreach ($name in $profileNames) {
        $shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Multigravity $name.lnk"
        if ($Force -or !(Test-Path $shortcutPath)) {
            Invoke-CreateShortcut $name
            $createdCount++
        } else {
            Write-Host "Shortcut already exists: $shortcutPath"
            $skippedCount++
        }
    }

    Write-Host "Shortcuts restore completed ($createdCount created/restored, $skippedCount skipped)."
}

function Invoke-ShortcutsCmd {
    param($subCmd, $extraArgs)

    $force = $false
    if ($subCmd -eq "--force" -or $subCmd -eq "-f" -or ($extraArgs -contains "--force") -or ($extraArgs -contains "-f")) {
        $force = $true
    }

    if ([string]::IsNullOrWhiteSpace($subCmd) -or $subCmd -eq "restore" -or $subCmd -eq "--force" -or $subCmd -eq "-f") {
        Invoke-RestoreShortcuts -Force:$force
    } else {
        $targetProfile = $subCmd
        if ($subCmd -eq "create" -and $extraArgs.Count -gt 0) {
            $targetProfile = $extraArgs[0]
        }
        Validate-Name $targetProfile
        Invoke-CreateShortcut $targetProfile
    }
}

function Invoke-DoctorCli {
    $errors = 0
    $warnings = 0

    Write-Host "Checking multigravity environment..."

    # 0. Canonical Root User Profile
    Write-Host "  [OK] Host User Profile: $ROOT_USERPROFILE"
    Write-Host "  [OK] Profile Base Dir: $BASE"

    # 1. Antigravity Desktop Installation
    if ($APP -and (Test-Path $APP)) {
        Write-Host "  [OK] Antigravity Desktop App: Found at $APP"
    } else {
        Write-Host "  [WARN] Antigravity Desktop App: Not found. Ensure it is installed or set MULTIGRAVITY_APP."
        $warnings++
    }

    # 1b. Antigravity CLI Installation
    if ($CLI_APP -and (Test-Path $CLI_APP)) {
        Write-Host "  [OK] Antigravity CLI: Found at $CLI_APP"
    } else {
        Write-Host "  [WARN] Antigravity CLI: 'agy' not found. Set MULTIGRAVITY_CLI_APP or ensure agy is in PATH."
        $warnings++
    }

    # 2. Path Check
    $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
    if ($cmdObj) {
        Write-Host "  [OK] Global Binary: $($cmdObj.Source)"
    } else {
        Write-Host "  [WARN] Global Binary: Not found in PATH. Run install script or update PATH."
        $warnings++
    }

    # 3. Base Directory
    if (Test-Path $BASE) {
        # Check writability
        try {
            $testFile = Join-Path $BASE ".write-test"
            New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
            Remove-Item $testFile -Force
            Write-Host "  [OK] Profile storage: $BASE (writable)"
        } catch {
            Write-Host "  [FAIL] Profile storage: $BASE (NOT writable)"
            $errors++
        }
    } else {
        Write-Host "  [WARN] Profile storage: $BASE (Not yet created)"
    }

    # 4. Global Profile Check
    $gProf = Get-GlobalProfile
    if ($gProf) {
        $hasGlobalCred = Test-Path "$BASE\$gProf\.credentials.json"
        $credState = if ($hasGlobalCred) { "credential saved" } else { "no saved credential" }
        Write-Host "  [OK] Global Profile: $gProf ($credState)"
    } else {
        Write-Host "  [INFO] Global Profile: None set (run 'multigravity global <name>' or 'multigravity new <name> --global')"
    }

    # 5. Shared Profiles Health Check
    if (Test-Path $BASE) {
        $sharedProfiles = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\.shared" }
        if ($sharedProfiles) {
            foreach ($sp in $sharedProfiles) {
                Sync-SharedProfile $sp.Name
                Write-Host "  [OK] Shared Profile '$($sp.Name)': Extensions, .gemini & settings synced (native host shell)"
            }
        }
    }

    # 6. Active Profile & Re-entrancy Stack
    if (Test-Path "$BASE\.active_profile") {
        $act = (Get-Content "$BASE\.active_profile" -Raw).Trim()
        Write-Host "  [INFO] Active profile indicator: $act"
    }

    Write-Host ""
    if ($errors -eq 0) {
        if ($warnings -eq 0) {
            Write-Host "Your environment looks perfect!"
        } else {
            Write-Host "Found $warnings warning(s). Multigravity should still work, but some features might be degraded."
        }
    } else {
        Write-Host "Found $errors error(s) and $warnings warning(s). Please fix the errors above."
    }
}

function Invoke-UpdateCli {
    $script_url = "https://raw.githubusercontent.com/lcizzle/multigravity-win-cli/main/multigravity.ps1"
    $target = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($target)) {
        $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
        if ($cmdObj) { $target = $cmdObj.Source }
    }

    if ([string]::IsNullOrEmpty($target)) {
        Write-Error "Error: could not determine script path for update"
        Exit-Multigravity 1
    }

    Write-Host "Updating multigravity from $script_url ..."
    try {
        $result = Invoke-WebRequest -Uri $script_url -UseBasicParsing -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($result.Content) -or $result.Content.Length -lt 500) {
            Write-Error "Error: downloaded update payload is invalid or empty"
            Exit-Multigravity 1
        }
        [System.IO.File]::WriteAllText($target, $result.Content, [System.Text.Encoding]::UTF8)
        Write-Host "Successfully updated multigravity!"
    } catch {
        Write-Error "Error: failed to download update: $_"
        Exit-Multigravity 1
    }
}

function Invoke-HelpCompletion {
    Write-Host "To enable autocompletion in PowerShell, add the following to your `$PROFILE:"
    Write-Host ""
    Write-Host '  Invoke-Expression (& multigravity completion powershell)'
    Write-Host ""
    Write-Host "Then restart your terminal or run: . `$PROFILE"
}

function Invoke-GenerateCompletion {
    param($shell)
    if ($shell -eq "powershell") {
        @"
Register-ArgumentCompleter -Native -CommandName multigravity -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    `$opts = @('new', 'list', 'status', 'rename', 'delete', 'clone', 'template', 'export', 'import', 'update', 'doctor', 'stats', 'shortcuts', 'completion', 'help', '--shortcut')
    `$profiles = if (Test-Path '$BASE') { Get-ChildItem -Directory -Path '$BASE' | Select-Object -ExpandProperty Name } else { @() }
    (`$opts + `$profiles) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
    } else {
        Write-Host "Only 'powershell' completion is supported on Windows."
    }
}

function Invoke-TemplateCmd {
    param($sub, $a, $b)
    switch ($sub) {
        "save" {
            if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) {
                Write-Error "Error: usage: multigravity template save <profile> <name>"; Exit-Multigravity 1
            }
            Validate-Name $a; Validate-Name $b
            $srcDir  = "$BASE\$a"
            $tplDir  = Get-TemplatesDir
            $tplPath = "$tplDir\$b"
            if (!(Test-Path $srcDir))  { Write-Error "Error: profile '$a' does not exist"; Exit-Multigravity 1 }
            if (Test-Path $tplPath)    { Write-Error "Error: template '$b' already exists"; Exit-Multigravity 1 }
            New-Item -ItemType Directory -Force -Path $tplDir | Out-Null
            Write-Host "Saving '$a' as template '$b'..."
            Copy-Item -Path $srcDir -Destination $tplPath -Recurse
            $marker = "$tplPath\.shared"
            if (Test-Path $marker) { Remove-Item $marker -Force }
            Write-Host "Saved template '$b'"
        }
        "list" {
            $tplDir = Get-TemplatesDir
            Write-Host "Templates:"
            if (!(Test-Path $tplDir)) { Write-Host "  (none)"; return }
            $items = Get-ChildItem -Directory -Path $tplDir -ErrorAction SilentlyContinue
            if ($items.Count -eq 0) { Write-Host "  (none)"; return }
            foreach ($t in $items) {
                Write-Host ("  {0,-20} {1}" -f $t.Name, (Get-FolderSize $t.FullName))
            }
        }
        "delete" {
            if ([string]::IsNullOrWhiteSpace($a)) { Write-Error "Error: template name required"; Exit-Multigravity 1 }
            Validate-Name $a
            $tplPath = "$(Get-TemplatesDir)\$a"
            if (!(Test-Path $tplPath)) { Write-Error "Error: template '$a' does not exist"; Exit-Multigravity 1 }
            Remove-Item -Recurse -Force $tplPath
            Write-Host "Deleted template '$a'"
        }
        default {
            Write-Error "Error: usage: multigravity template <save|list|delete>"; Exit-Multigravity 1
        }
    }
}

function Invoke-StatusProfiles {
    if (!(Test-Path $BASE)) { Write-Host "No profiles found."; return }

    Write-Host ("{0,-18} {1,-10} {2,-12} {3,-20} {4}" -f "PROFILE", "RUNNING", "TYPE", "LAST USED", "SIZE")
    Write-Host ("{0,-18} {1,-10} {2,-12} {3,-20} {4}" -f "-------", "-------", "----", "---------", "----")

    $dirs = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ".templates" }

    foreach ($d in $dirs) {
        $running = "no"
        $procs = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($proc in $procs) {
                try {
                    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                    if ($cl -and $cl -like "*$($d.Name)*") { $running = "yes"; break }
                } catch {}
            }
        }

        $gProf = Get-GlobalProfile
        $ptype = if ($gProf -and $d.Name -eq $gProf) {
            if (Test-Path "$($d.FullName)\.shared") { "global (shared)" } else { "global" }
        } elseif (Test-Path "$($d.FullName)\.shared") { "shared" } else { "full" }
        $lastUsed = $d.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        $size     = Get-FolderSize $d.FullName

        if ($running -eq "yes") {
            Write-Host ("{0,-18} " -f $d.Name) -NoNewline
            Write-Host ("{0,-10} " -f $running) -NoNewline -ForegroundColor Green
            Write-Host ("{0,-12} {1,-20} {2}" -f $ptype, $lastUsed, $size)
        } else {
            Write-Host ("{0,-18} {1,-10} {2,-12} {3,-20} {4}" -f $d.Name, $running, $ptype, $lastUsed, $size)
        }
    }
}

function Invoke-ExportProfile {
    param($name, $outPath)
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Error "Error: profile name required"; Exit-Multigravity 1 }
    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (!(Test-Path $profileDir)) { Write-Error "Error: profile '$name' does not exist"; Exit-Multigravity 1 }

    if ([string]::IsNullOrWhiteSpace($outPath)) { $outPath = ".\$name.zip" }

    Write-Host "Exporting '$name' to $outPath ..."
    Compress-Archive -Path $profileDir -DestinationPath $outPath -Force
    Write-Host "Done."
}

function Invoke-ImportProfile {
    param($archivePath, $name, [string[]]$extraArgs)

    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        Write-Error "Error: usage: multigravity import <archive.zip> [name]"; Exit-Multigravity 1
    }
    if (!(Test-Path $archivePath)) {
        Write-Error "Error: file not found: $archivePath"; Exit-Multigravity 1
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($archivePath)
    }
    Validate-Name $name

    $dest = "$BASE\$name"
    if (Test-Path $dest) {
        Write-Error "Error: profile '$name' already exists - choose a different name or delete it first"
        Exit-Multigravity 1
    }

    New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    Write-Host "Importing as '$name'..."

    $tmp = "$BASE\_mg_import_$(Get-Random)"
    try {
        Expand-Archive -Path $archivePath -DestinationPath $tmp -Force

        $top = Get-ChildItem -Directory -Path $tmp
        if ($top.Count -eq 1) {
            Move-Item -Path $top[0].FullName -Destination $dest
        } else {
            Rename-Item -Path $tmp -NewName $name
        }
    } finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($extraArgs -contains "--shortcut" -or $extraArgs -contains "--shortcuts") {
        Invoke-CreateShortcut $name
    }
    Write-Host "Imported profile '$name'"
}
} # end begin

process {
    if ($null -ne $InputObject) {
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            foreach ($item in $InputObject) {
                if ($null -ne $item) { $pipelineBuffer.Add([string]$item) }
            }
        } else {
            $pipelineBuffer.Add([string]$InputObject)
        }
    }
}

end {
try {
    $rawTokens = [System.Collections.Generic.List[string]]::new()
    if ($cmd) { $rawTokens.Add($cmd) }
    if ($AllRawArgs) { $rawTokens.AddRange($AllRawArgs) }
    if ($PSBoundParameters.ContainsKey('p')) {
        $rawTokens.Add("-p")
        $rawTokens.Add($p)
    }

    if ($rawTokens.Count -eq 0) {
        Write-Usage
        Exit-Multigravity 1
    }

    $firstToken = $rawTokens[0]
    $forward = if ($rawTokens.Count -ge 2) { @($rawTokens | Select-Object -Skip 1) } else { @() }
    $arg1 = if ($forward.Count -ge 1) { $forward[0] } else { $null }
    $arg2 = if ($forward.Count -ge 2) { $forward[1] } else { $null }
    $extra = if ($forward.Count -ge 3) { @($forward | Select-Object -Skip 2) } else { @() }
    $subForward = if ($forward.Count -ge 1) { @($forward | Select-Object -Skip 1) } else { @() }

    if ($firstToken -in @("help", "--help", "-h", "-?", "/?")) {
        Write-Usage
        Exit-Multigravity 0
    }

    switch ($firstToken) {
        "new" {
            $newArgs = @()
            if ($arg2) { $newArgs += $arg2 }
            if ($extra) { $newArgs += $extra }
            Invoke-NewProfile $arg1 $newArgs
        }
        "global" {
            $sub = $arg1
            if ($sub -eq "save_credential" -or $sub -eq "save-credential" -or $sub -eq "save" -or $sub -eq "--save_credential" -or $sub -eq "--save-credential" -or $sub -eq "--save") {
                $prof = if ($arg2) { $arg2 } else { Get-GlobalProfile }
                Save-GlobalCredential $prof | Out-Null
            } elseif ($sub -eq "remove_credentials" -or $sub -eq "remove-credentials" -or $sub -eq "--remove_credentials" -or $sub -eq "--remove-credentials" -or $sub -eq "remove" -or $sub -eq "--remove") {
                Remove-GlobalCredential
            } elseif ($sub -eq "unset" -or $sub -eq "clear" -or $sub -eq "--unset") {
                Unset-GlobalProfile
            } elseif ([string]::IsNullOrWhiteSpace($sub)) {
                $g = Get-GlobalProfile
                if ($g) {
                    Write-Host "Current global profile: $g"
                } else {
                    Write-Host "No global profile currently set. Set one with: multigravity global <profile-name>"
                }
            } else {
                Set-GlobalProfile $sub
            }
        }
        "list" {
            Invoke-ListProfiles
        }
        "status" {
            Invoke-StatusProfiles
        }
        "rename" {
            Invoke-RenameProfile $arg1 $arg2
        }
        "delete" {
            Invoke-DeleteProfile $arg1
        }
        "clone" {
            $cloneExtra = @()
            if ($extra) { $cloneExtra += $extra }
            Invoke-CloneProfile $arg1 $arg2 $cloneExtra
        }
        "template" {
            $tplArg3 = if ($extra -and $extra.Count -gt 0) { $extra[0] } else { $null }
            Invoke-TemplateCmd $arg1 $arg2 $tplArg3
        }
        "export" {
            Invoke-ExportProfile $arg1 $arg2
        }
        "import" {
            $importExtra = @()
            if ($extra) { $importExtra += $extra }
            Invoke-ImportProfile $arg1 $arg2 $importExtra
        }
        "update" {
            Invoke-UpdateCli
        }
        "doctor" {
            Invoke-DoctorCli
        }
        "stats" {
            Invoke-ProfileStats
        }
        "shortcuts" {
            $shortExtra = @()
            if ($arg2) { $shortExtra += $arg2 }
            if ($extra) { $shortExtra += $extra }
            Invoke-ShortcutsCmd $arg1 $shortExtra
        }
        "shortcut" {
            $shortExtra = @()
            if ($arg2) { $shortExtra += $arg2 }
            if ($extra) { $shortExtra += $extra }
            Invoke-ShortcutsCmd $arg1 $shortExtra
        }
        "completion" {
            if ($arg1) {
                Invoke-GenerateCompletion $arg1
            } else {
                Invoke-HelpCompletion
            }
        }
        "app" {
            Invoke-LaunchProfile $arg1 $subForward
        }
        "desktop" {
            Invoke-LaunchProfile $arg1 $subForward
        }
        "cli" {
            Invoke-LaunchCLIProfile $arg1 $subForward
        }
        "agy" {
            Invoke-LaunchCLIProfile $arg1 $subForward
        }
        default {
            if ($firstToken.StartsWith("-")) {
                Write-Error "Error: Unknown option '$firstToken'. Run 'multigravity help' for usage."
                Exit-Multigravity 1
            }
            if ($forward -contains "--cli" -or $forward -contains "--agy") {
                $filteredArgs = @($forward | Where-Object { $_ -ne "--cli" -and $_ -ne "--agy" })
                Invoke-LaunchCLIProfile $firstToken $filteredArgs
            } else {
                Invoke-LaunchProfile $firstToken $forward
            }
        }
    }
} catch [MultigravityExitException] {
    return $_.Exception.ExitCode
}
} # end end
