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

    public static bool PayloadsEqual(string base64BlobA, string base64BlobB) {
        if (string.IsNullOrEmpty(base64BlobA) || string.IsNullOrEmpty(base64BlobB)) return false;
        if (base64BlobA == base64BlobB) return true;
        try {
            byte[] bytesA = Convert.FromBase64String(base64BlobA);
            bool unprotectA = false;
            try {
                bytesA = System.Security.Cryptography.ProtectedData.Unprotect(
                    bytesA, null, System.Security.Cryptography.DataProtectionScope.CurrentUser
                );
                unprotectA = true;
            } catch {}

            byte[] bytesB = Convert.FromBase64String(base64BlobB);
            bool unprotectB = false;
            try {
                bytesB = System.Security.Cryptography.ProtectedData.Unprotect(
                    bytesB, null, System.Security.Cryptography.DataProtectionScope.CurrentUser
                );
                unprotectB = true;
            } catch {}

            if (unprotectA != unprotectB) return false;
            if (bytesA.Length != bytesB.Length) return false;
            for (int i = 0; i < bytesA.Length; i++) {
                if (bytesA[i] != bytesB[i]) return false;
            }
            return true;
        } catch {
            return false;
        }
    }
}
"@ -ErrorAction SilentlyContinue
}

if (-not ([System.Management.Automation.PSTypeName]'MultigravityFileUtil').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class MultigravityFileUtil {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;

    enum RM_APP_TYPE {
        RmUnknownApp = 0,
        RmMainWindow = 1,
        RmOtherWindow = 2,
        RmService = 3,
        RmExplorer = 4,
        RmConsole = 5,
        RmCritical = 1000
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
        public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint pSessionHandle, out uint pnProcInfoNeeded,
        ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static int[] GetLockingProcessIds(string path) {
        if (string.IsNullOrEmpty(path)) return new int[0];
        uint handle;
        string key = Guid.NewGuid().ToString();
        List<int> processes = new List<int>();

        int res = RmStartSession(out handle, 0, key);
        if (res != 0) return processes.ToArray();

        try {
            string[] resources = new string[] { path };
            res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
            if (res != 0) return processes.ToArray();

            uint nProcInfoNeeded = 0;
            uint nProcInfo = 0;
            uint lpdwRebootReasons = 0;

            res = RmGetList(handle, out nProcInfoNeeded, ref nProcInfo, null, ref lpdwRebootReasons);
            if (res == 234) { // ERROR_MORE_DATA
                RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[nProcInfoNeeded];
                nProcInfo = nProcInfoNeeded;
                res = RmGetList(handle, out nProcInfoNeeded, ref nProcInfo, processInfo, ref lpdwRebootReasons);
                if (res == 0) {
                    for (int i = 0; i < nProcInfo; i++) {
                        processes.Add(processInfo[i].Process.dwProcessId);
                    }
                }
            }
        } catch {
        } finally {
            RmEndSession(handle);
        }
        return processes.ToArray();
    }
}
"@ -ErrorAction SilentlyContinue
}

function Get-ActiveConversationIdForPid {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return $null }

    $candidatePids = [System.Collections.Generic.HashSet[int]]::new()
    $candidatePids.Add($ProcessId) | Out-Null

    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if ($children) {
            foreach ($ch in $children) {
                $candidatePids.Add($ch.ProcessId) | Out-Null
                $gChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($ch.ProcessId)" -ErrorAction SilentlyContinue
                if ($gChildren) {
                    foreach ($gc in $gChildren) {
                        $candidatePids.Add($gc.ProcessId) | Out-Null
                    }
                }
            }
        }
    } catch {}

    $sysGemini = Get-SystemGeminiDir
    $convDirs = @(
        (Join-Path $sysGemini "antigravity-cli\conversations"),
        (Join-Path $sysGemini "antigravity\conversations")
    )

    foreach ($convDir in $convDirs) {
        if (-not (Test-Path $convDir)) { continue }

        # First check .db-shm files (active SQLite WAL lock)
        $shmFiles = Get-ChildItem -Path $convDir -Filter "*.db-shm" -ErrorAction SilentlyContinue
        if ($shmFiles) {
            foreach ($file in $shmFiles) {
                try {
                    $lockingPids = [MultigravityFileUtil]::GetLockingProcessIds($file.FullName)
                    foreach ($lp in $lockingPids) {
                        if ($candidatePids.Contains($lp)) {
                            if ($file.Name -match '^([0-9a-fA-F\-]{36})\.db-shm$') {
                                return $Matches[1]
                            }
                        }
                    }
                } catch {}
            }
        }

        # Fallback: check recent .db files directly
        $dbFiles = Get-ChildItem -Path $convDir -Filter "*.db" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending |
                   Select-Object -First 20
        if ($dbFiles) {
            foreach ($file in $dbFiles) {
                try {
                    $lockingPids = [MultigravityFileUtil]::GetLockingProcessIds($file.FullName)
                    foreach ($lp in $lockingPids) {
                        if ($candidatePids.Contains($lp)) {
                            if ($file.Name -match '^([0-9a-fA-F\-]{36})\.db$') {
                                return $Matches[1]
                            }
                        }
                    }
                } catch {}
            }
        }
    }

    return $null
}

$script:MultigravityHookScriptContent = @'
<#
.SYNOPSIS
    Antigravity PreInvocation Lifecycle Hook for Multigravity Conversation Tracking.
    Receives JSON on stdin, updates .active_instances.json, and returns {} on stdout.
#>
[CmdletBinding()]
param()

$outputJson = "{}"

try {
    # 1. Read JSON payload from stdin
    $rawInput = [System.Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        return
    }

    $payload = $rawInput | ConvertFrom-Json -ErrorAction Stop
    $convId = $payload.conversationId
    if ([string]::IsNullOrEmpty($convId)) {
        return
    }

    # 2. Determine base directory
    $userProfile = if ($env:MULTIGRAVITY_ROOT_USERPROFILE) {
        $env:MULTIGRAVITY_ROOT_USERPROFILE
    } else {
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    }
    $baseDir = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$userProfile\.config\multigravity\profiles" }
    $regPath = "$baseDir\.active_instances.json"

    if (-not (Test-Path $regPath)) { return }

    # 3. Identify target instance PID
    $targetPid = if ($env:MULTIGRAVITY_ACTIVE_PID) {
        [int]$env:MULTIGRAVITY_ACTIVE_PID
    } else {
        # Fallback: find ancestor PID listed in active instances
        $myPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $candidatePids = [System.Collections.Generic.HashSet[int]]::new()
        $cur = $myPid
        for ($i = 0; $i -lt 6; $i++) {
            try {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $cur" -ErrorAction SilentlyContinue
                if ($proc -and $proc.ParentProcessId -gt 0) {
                    $cur = [int]$proc.ParentProcessId
                    $candidatePids.Add($cur) | Out-Null
                } else { break }
            } catch { break }
        }
        $found = 0
        try {
            $rawReg = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8)
            $regObj = $rawReg | ConvertFrom-Json
            if ($regObj.instances) {
                foreach ($inst in $regObj.instances) {
                    if ($candidatePids.Contains([int]$inst.pid)) {
                        $found = [int]$inst.pid
                        break
                    }
                }
            }
        } catch {}
        $found
    }

    if ($targetPid -le 0) { return }

    # 4. Fast check: is conversation_id already matching?
    try {
        $rawRegFast = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8)
        $regFastObj = $rawRegFast | ConvertFrom-Json
        if ($regFastObj.instances) {
            foreach ($inst in $regFastObj.instances) {
                if ([int]$inst.pid -eq $targetPid -and $inst.conversation_id -eq $convId) {
                    return
                }
            }
        }
    } catch {}

    # 5. Acquire vault mutex and update registry if changed
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutexName = "Local\Multigravity_Vault_Mutex_$userSid"
    $mutex = $null
    $acquired = $false

    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try {
            $acquired = $mutex.WaitOne(2000)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { return }

        $rawReg = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8)
        $regObj = $rawReg | ConvertFrom-Json
        $updated = $false

        if ($regObj.instances) {
            foreach ($inst in $regObj.instances) {
                if ([int]$inst.pid -eq $targetPid) {
                    if ($inst.conversation_id -ne $convId) {
                        $inst | Add-Member -NotePropertyName "conversation_id" -NotePropertyValue $convId -Force
                        $updated = $true
                    }
                    break
                }
            }
        }

        if ($updated) {
            $newJson = $regObj | ConvertTo-Json -Depth 5
            $tmpPath = "$regPath.tmp"
            [System.IO.File]::WriteAllText($tmpPath, $newJson, [System.Text.Encoding]::UTF8)
            Move-Item -Path $tmpPath -Destination $regPath -Force
        }
    } finally {
        if ($acquired -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { try { $mutex.Dispose() } catch {} }
    }
} catch {
} finally {
    [System.Console]::WriteLine($outputJson)
}
'@

function Register-HookInConfigFile {
    param(
        [string]$ConfigFilePath,
        [string]$HookCmdPath,
        [switch]$Force
    )

    $existing = [ordered]@{}
    if (Test-Path $ConfigFilePath) {
        $raw = [System.IO.File]::ReadAllText($ConfigFilePath, [System.Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($parsed) {
                    foreach ($prop in $parsed.psobject.Properties) {
                        $existing[$prop.Name] = $prop.Value
                    }
                }
            } catch {
                Write-Warning "Existing hooks.json at '$ConfigFilePath' contains invalid JSON syntax. Backing up to '$ConfigFilePath.corrupt.bak' and skipping auto-registration to prevent data loss."
                try { Copy-Item -Path $ConfigFilePath -Destination "$ConfigFilePath.corrupt.bak" -Force } catch {}
                return $false
            }
        }
    }

    $trackerSpec = [ordered]@{
        "PreInvocation" = @(
            [ordered]@{
                "type"    = "command"
                "command" = $HookCmdPath
                "timeout" = 5
            }
        )
    }

    # Check if already up to date
    if (-not $Force -and $existing.Contains("multigravity-conversation-tracker")) {
        $cur = $existing["multigravity-conversation-tracker"]
        if ($cur.PreInvocation -and $cur.PreInvocation.Count -gt 0 -and $cur.PreInvocation[0].command -eq $HookCmdPath) {
            return $true
        }
    }

    # Non-destructively set / append key
    $existing["multigravity-conversation-tracker"] = $trackerSpec

    $newJson = $existing | ConvertTo-Json -Depth 10
    $tmpPath = "$ConfigFilePath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $newJson, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpPath -Destination $ConfigFilePath -Force
    return $true
}

function Unregister-HookInConfigFile {
    param([string]$ConfigFilePath)

    if (-not (Test-Path $ConfigFilePath)) { return $true }
    $raw = [System.IO.File]::ReadAllText($ConfigFilePath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $parsed) { return $true }
        $existing = [ordered]@{}
        $found = $false
        foreach ($prop in $parsed.psobject.Properties) {
            if ($prop.Name -eq "multigravity-conversation-tracker") {
                $found = $true
            } else {
                $existing[$prop.Name] = $prop.Value
            }
        }
        if ($found) {
            $newJson = $existing | ConvertTo-Json -Depth 10
            $tmpPath = "$ConfigFilePath.tmp"
            [System.IO.File]::WriteAllText($tmpPath, $newJson, [System.Text.Encoding]::UTF8)
            Move-Item -Path $tmpPath -Destination $ConfigFilePath -Force
        }
        return $true
    } catch {
        return $false
    }
}

function Ensure-MultigravityHooks {
    param(
        [string]$ProfileName = "",
        [switch]$Force
    )

    $installDir = if ($env:MULTIGRAVITY_INSTALL_DIR) {
        $env:MULTIGRAVITY_INSTALL_DIR
    } else {
        "$ROOT_USERPROFILE\.local\bin"
    }
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    }

    $hookPs1Path = Join-Path $installDir "multigravity-hook.ps1"
    $hookCmdPath = Join-Path $installDir "multigravity-hook.cmd"

    # Write hook script and wrapper if missing or forced
    if ($Force -or (-not (Test-Path $hookPs1Path))) {
        [System.IO.File]::WriteAllText($hookPs1Path, $script:MultigravityHookScriptContent, [System.Text.Encoding]::UTF8)
    }
    if ($Force -or (-not (Test-Path $hookCmdPath))) {
        $wrapper = "@echo off`r`nsetlocal`r`nchcp 65001 >nul`r`nwhere.exe pwsh.exe >nul 2>&1`r`nif %ERRORLEVEL% equ 0 (`r`n    pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%~dp0multigravity-hook.ps1`" %*`r`n) else (`r`n    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%~dp0multigravity-hook.ps1`" %*`r`n)`r`nexit /b 0`r`n"
        [System.IO.File]::WriteAllText($hookCmdPath, $wrapper, [System.Text.Encoding]::ASCII)
    }

    # Register in ~/.gemini/config/hooks.json
    $sysGemini = Get-SystemGeminiDir
    $globalConfigDir = Join-Path $sysGemini "config"
    if (-not (Test-Path $globalConfigDir)) {
        New-Item -ItemType Directory -Force -Path $globalConfigDir | Out-Null
    }
    $globalHooksJson = Join-Path $globalConfigDir "hooks.json"
    Register-HookInConfigFile -ConfigFilePath $globalHooksJson -HookCmdPath $hookCmdPath -Force:$Force | Out-Null

    # If ProfileName is specified and it's an isolated profile (not shared, not global)
    if ($ProfileName) {
        $isGlob = ($ProfileName -eq (Get-GlobalProfile))
        $isSh = Test-SharedProfile $ProfileName
        if (-not $isGlob -and -not $isSh) {
            $profGeminiConfig = Join-Path (Join-Path $BASE $ProfileName) ".gemini\config"
            if (-not (Test-Path $profGeminiConfig)) {
                New-Item -ItemType Directory -Force -Path $profGeminiConfig | Out-Null
            }
            $profHooksJson = Join-Path $profGeminiConfig "hooks.json"
            Register-HookInConfigFile -ConfigFilePath $profHooksJson -HookCmdPath $hookCmdPath -Force:$Force | Out-Null
        }
    }
}

function Invoke-HooksCommand {
    param(
        [string]$sub = "status",
        $extraArgs = @()
    )

    $subCmd = if (-not [string]::IsNullOrWhiteSpace($sub)) { $sub.ToLowerInvariant() } else { "status" }
    switch ($subCmd) {
        "install" {
            Ensure-MultigravityHooks -Force
            Write-Host "[OK] Multigravity conversation tracking hook installed and registered successfully."
            break
        }
        "status" {
            $installDir = if ($env:MULTIGRAVITY_INSTALL_DIR) { $env:MULTIGRAVITY_INSTALL_DIR } else { "$ROOT_USERPROFILE\.local\bin" }
            $hookPs1 = Join-Path $installDir "multigravity-hook.ps1"
            $hookCmd = Join-Path $installDir "multigravity-hook.cmd"
            $sysGemini = Get-SystemGeminiDir
            $globalHooksJson = Join-Path (Join-Path $sysGemini "config") "hooks.json"

            Write-Host "Multigravity Hooks Status:"
            Write-Host "  Hook script: $(if (Test-Path $hookPs1) { '[OK] Present' } else { '[FAIL] Missing' }) ($hookPs1)"
            Write-Host "  CMD wrapper: $(if (Test-Path $hookCmd) { '[OK] Present' } else { '[FAIL] Missing' }) ($hookCmd)"
            
            $regStatus = "[FAIL] Not configured"
            if (Test-Path $globalHooksJson) {
                try {
                    $json = Get-Content $globalHooksJson -Raw | ConvertFrom-Json
                    if ($json."multigravity-conversation-tracker") {
                        $regStatus = "[OK] Registered in $globalHooksJson"
                    }
                } catch {}
            }
            Write-Host "  Global registration: $regStatus"
            break
        }
        "uninstall" {
            $sysGemini = Get-SystemGeminiDir
            $globalHooksJson = Join-Path (Join-Path $sysGemini "config") "hooks.json"
            Unregister-HookInConfigFile $globalHooksJson | Out-Null
            Write-Host "[OK] Multigravity conversation tracking hook unregistered from $globalHooksJson."
            break
        }
        default {
            Write-Host "Usage: multigravity hooks [install|status|uninstall]"
            break
        }
    }
}

function Get-TargetCredName {
    if ($env:MULTIGRAVITY_TEST_CRED_TARGET) {
        return $env:MULTIGRAVITY_TEST_CRED_TARGET
    }
    return "gemini:antigravity"
}

$TARGET_CRED_NAME = Get-TargetCredName

function Get-ProfileCredentialPath {
    param([string]$profileName)
    $BASE = Get-BaseDir
    $globalProfile = Get-GlobalProfile
    if ($globalProfile -and $profileName -eq $globalProfile) {
        return "$BASE\.global_credentials.json"
    } else {
        return "$BASE\$profileName\.credentials.json"
    }
}

function Test-CredentialFileValid {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path)) {
        return $false
    }
    $delays = @(20, 50, 100)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $item = Get-Item -Path $Path -ErrorAction Stop
            if ($item.Length -lt 10) { return $false }
            $content = Get-Content -Path $Path -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($content)) { return $false }
            $json = $content | ConvertFrom-Json -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($json.blob)) {
                return $false
            }
            $rawBytes = [System.Convert]::FromBase64String($json.blob)
            return ($rawBytes.Length -gt 0)
        } catch {
            if ($i -lt 2) { Start-Sleep -Milliseconds $delays[$i] }
        }
    }
    return $false
}

function Test-ProfileHasValidCredential {
    param($PROFILE)
    $credPath = Get-ProfileCredentialPath $PROFILE
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

function Invoke-WithVaultMutex {
    param([scriptblock]$Action)
    if ($script:MultigravityVaultMutexDepth -gt 0) {
        $script:MultigravityVaultMutexDepth++
        try {
            return (& $Action)
        } finally {
            $script:MultigravityVaultMutexDepth--
        }
    }

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
        $script:MultigravityVaultMutexDepth = 1
        try {
            return (& $Action)
        } finally {
            $script:MultigravityVaultMutexDepth = 0
            if ($acquired -and $mutex) {
                try { $mutex.ReleaseMutex() } catch {}
            }
        }
    } finally {
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

function Get-ActiveInstancesRegistry {
    $BASE = Get-BaseDir
    $regPath = "$BASE\.active_instances.json"
    if (-not (Test-Path $regPath)) {
        return [PSCustomObject]@{
            active_vault_profile = $null
            instances            = @()
        }
    }

    $retries = 5
    $delays = @(25, 50, 100, 200, 400)
    $reg = $null
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            $raw = Get-Content -Path $regPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $reg = $raw | ConvertFrom-Json -ErrorAction Stop
                break
            }
        } catch {
            if ($i -eq ($retries - 1)) {
                Write-Error "Error: Failed to read or parse active instances registry at '$regPath': $_"
                throw
            }
            Start-Sleep -Milliseconds $delays[$i]
        }
    }

    if (-not $reg) {
        return [PSCustomObject]@{
            active_vault_profile = $null
            instances            = @()
        }
    }

    # Prune dead instances
    $pruned = @()
    $dirty = $false
    $deadProfiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($reg.instances) {
        foreach ($inst in $reg.instances) {
            if ($inst.pid -gt 0) {
                if (Test-InstanceAlive $inst) {
                    $pruned += $inst
                } else {
                    $dirty = $true
                    $deadProfiles.Add($inst.profile) | Out-Null
                }
            }
        }
    }

    # If any profile in deadProfiles still has an alive instance, remove it from deadProfiles
    foreach ($inst in $pruned) {
        if ($inst.profile -and $deadProfiles.Contains($inst.profile)) {
            $deadProfiles.Remove($inst.profile) | Out-Null
        }
    }

    # If an instance's parent_pid is dead, clear its parent_pid so it promotes to top-level
    $alivePids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($inst in $pruned) {
        $alivePids.Add([int]$inst.pid) | Out-Null
    }
    foreach ($inst in $pruned) {
        if ($inst.parent_pid -and -not $alivePids.Contains([int]$inst.parent_pid)) {
            $inst.parent_pid = $null
            $dirty = $true
        }
    }

    $reg.instances = $pruned

    # Reconcile active_vault_profile if its owner definitively crashed
    if ($reg.active_vault_profile -and $deadProfiles.Contains($reg.active_vault_profile)) {
        $dirty = $true
        $reg.active_vault_profile = $null
    }

    # Persist cleaned state if dirty and currently inside mutex
    if ($dirty -and $script:MultigravityVaultMutexDepth -gt 0) {
        Save-ActiveInstancesRegistry $reg
    }

    return $reg
}

function Register-ActiveInstance {
    param(
        [string]$PROFILE,
        [int]$ProcessId,
        [string]$ProcessType = "app",
        [System.DateTime]$StartTime = [System.DateTime]::MinValue,
        [int]$ReplacePid = 0,
        [string]$ConversationId = $null,
        [Nullable[int]]$ParentPid = $null
    )
    if ($ProcessId -le 0) { return }
    $BASE = Get-BaseDir
    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        $startIso = if ($null -ne $StartTime -and $StartTime -ne [System.DateTime]::MinValue) {
            $StartTime.ToUniversalTime().ToString("o")
        } else {
            (Get-Date).ToUniversalTime().ToString("o")
        }

        # Inherit conversation_id and parent_pid from replaced instance if not explicitly provided
        $inheritedConv = $ConversationId
        $inheritedParent = $ParentPid
        if ($ReplacePid -gt 0 -and $reg.instances) {
            $matched = @($reg.instances | Where-Object { $_.pid -eq $ReplacePid })
            if ($matched.Count -gt 0) {
                if (-not $inheritedConv -and $matched[0].conversation_id) {
                    $inheritedConv = $matched[0].conversation_id
                }
                if ($null -eq $inheritedParent -and $matched[0].parent_pid) {
                    $inheritedParent = $matched[0].parent_pid
                }
            }
        }

        $inst = [PSCustomObject]@{
            pid             = $ProcessId
            profile         = $PROFILE
            type            = $ProcessType
            started         = $startIso
            conversation_id = $inheritedConv
            parent_pid      = $inheritedParent
        }
        $filter = if ($ReplacePid -gt 0) {
            @($reg.instances | Where-Object { $_.pid -ne $ReplacePid -and $_.pid -ne $ProcessId })
        } else {
            @($reg.instances | Where-Object { $_.pid -ne $ProcessId })
        }
        $reg.instances = $filter + @($inst)
        Save-ActiveInstancesRegistry $reg
    }
}

function Set-GlobalProfile {
    param([string]$PROFILE)

    Validate-Name $PROFILE
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalProfFile = "$BASE\.global_profile"
    $globalCred     = "$BASE\.global_credentials.json"
    $localCred      = "$BASE\$PROFILE\.credentials.json"
    $oldGlobal      = Get-GlobalProfile

    Invoke-WithVaultMutex {
        # Symmetrical demotion & promotion
        if ($oldGlobal -and $oldGlobal -eq $PROFILE) {
            # Idempotent re-affirmation; reconcile orphaned local credentials
            if (Test-Path $localCred) {
                if (!(Test-CredentialFileValid $globalCred) -and (Test-CredentialFileValid $localCred)) {
                    $tmpGlobal = "$globalCred.tmp"
                    Copy-Item -Path $localCred -Destination $tmpGlobal -Force -ErrorAction Stop
                    if (Test-CredentialFileValid $tmpGlobal) {
                        Move-Item -Path $tmpGlobal -Destination $globalCred -Force -ErrorAction Stop
                        Remove-Item $localCred -Force -ErrorAction SilentlyContinue
                        Write-Host "Promoted orphaned local credential to valid global credential for profile '$PROFILE'."
                    } else {
                        Remove-Item $tmpGlobal -Force -ErrorAction SilentlyContinue
                    }
                } elseif (Test-CredentialFileValid $globalCred) {
                    Remove-Item $localCred -Force -ErrorAction SilentlyContinue
                    Write-Host "Reconciled and removed redundant local credential file for global profile '$PROFILE'."
                } else {
                    Write-Warning "Both global and local credential files for '$PROFILE' are invalid; skipping deletion to prevent data loss."
                }
            }

            # Synchronize vault and resting ownership if 0 instances running
            $reg = Get-ActiveInstancesRegistry
            if (-not $reg.instances -or $reg.instances.Count -eq 0) {
                if (Test-CredentialFileValid $globalCred) {
                    try {
                        $gJson = Get-Content $globalCred -Raw | ConvertFrom-Json
                        if ($gJson.blob) {
                            [MultigravityCredVault]::ImportCredential($credTarget, $gJson.userName, $gJson.blob) | Out-Null
                            $reg.active_vault_profile = $PROFILE
                            Set-Content -Path "$BASE\.active_profile" -Value $PROFILE -Encoding UTF8
                            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                        }
                    } catch {}
                }
                Save-ActiveInstancesRegistry $reg
            }
        } else {
            # Demote old global profile if distinct
            if ($oldGlobal -and $oldGlobal -ne $PROFILE) {
                $oldGlobalDir = "$BASE\$oldGlobal"
                $oldGlobalCred = "$oldGlobalDir\.credentials.json"
                if (Test-Path $globalCred) {
                    if (-not (Test-Path $oldGlobalDir)) {
                        New-Item -ItemType Directory -Path $oldGlobalDir -Force | Out-Null
                    }
                    $tmpOld = "$oldGlobalCred.tmp"
                    Copy-Item -Path $globalCred -Destination $tmpOld -Force -ErrorAction Stop
                    if (Test-CredentialFileValid $tmpOld) {
                        Move-Item -Path $tmpOld -Destination $oldGlobalCred -Force -ErrorAction Stop
                        Remove-Item $globalCred -Force -ErrorAction SilentlyContinue
                        Write-Host "Demoted global credentials to local profile '$oldGlobal'."
                    } else {
                        Remove-Item $tmpOld -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            # Promote new global profile
            if (Test-Path $localCred) {
                $tmpNew = "$globalCred.tmp"
                Copy-Item -Path $localCred -Destination $tmpNew -Force -ErrorAction Stop
                if (Test-CredentialFileValid $tmpNew) {
                    Move-Item -Path $tmpNew -Destination $globalCred -Force -ErrorAction Stop
                    Remove-Item $localCred -Force -ErrorAction SilentlyContinue
                    Write-Host "Promoted local credentials from '$PROFILE' to global credentials."
                } else {
                    Remove-Item $tmpNew -Force -ErrorAction SilentlyContinue
                }
            }

            Set-Content -Path $globalProfFile -Value $PROFILE -Encoding UTF8
            Write-Host "Set global profile name to '$PROFILE'"

            # If zero instances are running, synchronize Windows Credential Manager and resting ownership
            $reg = Get-ActiveInstancesRegistry
            if (-not $reg.instances -or $reg.instances.Count -eq 0) {
                if (Test-CredentialFileValid $globalCred) {
                    try {
                        $gJson = Get-Content $globalCred -Raw | ConvertFrom-Json
                        if ($gJson.blob) {
                            [MultigravityCredVault]::ImportCredential($credTarget, $gJson.userName, $gJson.blob) | Out-Null
                            $reg.active_vault_profile = $PROFILE
                            Set-Content -Path "$BASE\.active_profile" -Value $PROFILE -Encoding UTF8
                            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                        }
                    } catch {}
                } else {
                    [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
                    $reg.active_vault_profile = $null
                    if (Test-Path "$BASE\.active_profile") {
                        Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
                    }
                    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                }
                Save-ActiveInstancesRegistry $reg
            }
        }
    } | Out-Null

    # Synchronize shared profile junction points OUTSIDE mutex
    $reg = Get-ActiveInstancesRegistry
    $sharedRunning = @($reg.instances | Where-Object { Test-SharedProfile $_.profile })
    if ($sharedRunning.Count -gt 0) {
        Write-Warning "Cannot sync shared profiles while shared profile instances are active (PIDs: $(($sharedRunning.pid) -join ', ')). Skipping shared sync."
    } elseif (Test-Path $BASE) {
        Get-ChildItem -Path $BASE -Directory | Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" } | ForEach-Object {
            if (Test-Path "$($_.FullName)\.shared") {
                Sync-SharedProfile $_.Name
            }
        }
    }

    return $true
}

function Unset-GlobalProfile {
    param([switch]$PurgeOnly)

    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalProfFile = "$BASE\.global_profile"
    $globalCred     = "$BASE\.global_credentials.json"
    $oldGlobal      = Get-GlobalProfile

    Invoke-WithVaultMutex {
        if ($oldGlobal) {
            $oldGlobalDir = "$BASE\$oldGlobal"
            $oldGlobalCred = "$oldGlobalDir\.credentials.json"
            if (Test-Path $globalCred) {
                if ($PurgeOnly) {
                    Remove-Item $globalCred -Force -ErrorAction SilentlyContinue
                } else {
                    if (-not (Test-Path $oldGlobalDir)) {
                        New-Item -ItemType Directory -Path $oldGlobalDir -Force | Out-Null
                    }
                    $tmpOld = "$oldGlobalCred.tmp"
                    Copy-Item -Path $globalCred -Destination $tmpOld -Force -ErrorAction Stop
                    if (Test-CredentialFileValid $tmpOld) {
                        Move-Item -Path $tmpOld -Destination $oldGlobalCred -Force -ErrorAction Stop
                        Remove-Item $globalCred -Force -ErrorAction SilentlyContinue
                        Write-Host "Migrated global credentials back to local profile '$oldGlobal'."
                    } else {
                        Remove-Item $tmpOld -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        if (Test-Path $globalProfFile) {
            Remove-Item $globalProfFile -Force -ErrorAction SilentlyContinue
        }

        $reg = Get-ActiveInstancesRegistry
        if (-not $reg.instances -or $reg.instances.Count -eq 0) {
            [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
            $reg.active_vault_profile = $null
            Save-ActiveInstancesRegistry $reg
            if (Test-Path "$BASE\.active_profile") {
                Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
            }
            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
        }

        Write-Host "Unset global profile."
    } | Out-Null

    # Synchronize shared profile junction points OUTSIDE mutex
    $reg = Get-ActiveInstancesRegistry
    $sharedRunning = @($reg.instances | Where-Object { Test-SharedProfile $_.profile })
    if ($sharedRunning.Count -gt 0) {
        Write-Warning "Cannot sync shared profiles while shared profile instances are active. Skipping shared sync."
    } elseif (Test-Path $BASE) {
        Get-ChildItem -Path $BASE -Directory | Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" } | ForEach-Object {
            if (Test-Path "$($_.FullName)\.shared") {
                Sync-SharedProfile $_.Name
            }
        }
    }

    return $true
}

function Save-GlobalCredential {
    param([string]$PROFILE, [switch]$Force)
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalCred = "$BASE\.global_credentials.json"
    $currentGlobal = Get-GlobalProfile

    # If PROFILE not passed, require an active global profile
    if (-not $PROFILE -and -not $currentGlobal) {
        Write-Error "Error: No global profile is currently configured. Specify a profile name or set one with 'multigravity global <profile>'."
        Exit-Multigravity 1
    }

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        # Guard: Block only if another profile currently has LIVE running instances
        $activeVaultRunning = @($reg.instances | Where-Object { $_.profile -eq $reg.active_vault_profile -and (Test-InstanceAlive $_) })
        if ($activeVaultRunning.Count -gt 0 -and $reg.active_vault_profile -ne $PROFILE -and -not $Force) {
            Write-Error "Error: Windows Credential Manager is currently claimed by active profile '$($reg.active_vault_profile)'. Cannot save to distinct profile '$PROFILE' without -Force."
            Exit-Multigravity 1
        }

        # 1. Export vault tokens first and stage to .tmp
        $user = [string]::Empty
        $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
        if (-not $blob) {
            Write-Error "Error: No valid credential tokens in Windows Credential Manager to save as global credential."
            Exit-Multigravity 1
        }

        $tmpTarget = "$globalCred.tmp"
        $data = @{
            userName = $user
            blob     = $blob
            updated  = (Get-Date).ToString("o")
        } | ConvertTo-Json
        Set-Content -Path $tmpTarget -Value $data -Encoding UTF8

        if (-not (Test-CredentialFileValid $tmpTarget)) {
            Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue
            Write-Error "Error: Exported global credential payload failed validation check."
            Exit-Multigravity 1
        }

        # 2. If transitioning from an existing distinct global profile, demote it
        if ($PROFILE -and $currentGlobal -and $PROFILE -ne $currentGlobal) {
            $oldGlobalDir = "$BASE\$currentGlobal"
            $oldGlobalCred = "$oldGlobalDir\.credentials.json"
            if (Test-Path $globalCred) {
                if (-not (Test-Path $oldGlobalDir)) {
                    New-Item -ItemType Directory -Path $oldGlobalDir -Force | Out-Null
                }
                $tmpOld = "$oldGlobalCred.tmp"
                Copy-Item -Path $globalCred -Destination $tmpOld -Force -ErrorAction Stop
                if (Test-CredentialFileValid $tmpOld) {
                    Move-Item -Path $tmpOld -Destination $oldGlobalCred -Force -ErrorAction Stop
                    Write-Host "Demoted prior global credentials to '$currentGlobal'."
                } else {
                    Remove-Item $tmpOld -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 3. Commit staged global credential atomically
        Move-Item -Path $tmpTarget -Destination $globalCred -Force -ErrorAction Stop

        # 4. Remove redundant local credential for PROFILE if present
        if ($PROFILE) {
            $localCred = "$BASE\$PROFILE\.credentials.json"
            if (Test-Path $localCred) {
                Remove-Item $localCred -Force -ErrorAction SilentlyContinue
            }
        }

        # 5. Update .global_profile if PROFILE specified and differs
        if ($PROFILE -and $currentGlobal -ne $PROFILE) {
            Set-Content -Path "$BASE\.global_profile" -Value $PROFILE -Encoding UTF8
        }

        $label = if ($PROFILE) { $PROFILE } elseif ($currentGlobal) { $currentGlobal } else { "global" }
        Write-Host "Saved credential as global profile credential ('$label')."
    } | Out-Null

    # Synchronize shared profiles OUTSIDE mutex
    $reg = Get-ActiveInstancesRegistry
    $sharedRunning = @($reg.instances | Where-Object { Test-SharedProfile $_.profile })
    if ($sharedRunning.Count -eq 0 -and (Test-Path $BASE)) {
        Get-ChildItem -Path $BASE -Directory | Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" } | ForEach-Object {
            if (Test-Path "$($_.FullName)\.shared") {
                Sync-SharedProfile $_.Name
            }
        }
    }

    return $true
}

function Save-CredentialToProfile {
    param([string]$PROFILE, [switch]$Force)
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName

    # If PROFILE is the global profile, delegate directly
    $g = Get-GlobalProfile
    if ($g -and $g -eq $PROFILE) {
        Save-GlobalCredential $PROFILE -Force:$Force | Out-Null
        return
    }

    $profileDir = "$BASE\$PROFILE"
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    $credPath = "$profileDir\.credentials.json"

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        $activeVaultRunning = @($reg.instances | Where-Object { $_.profile -eq $reg.active_vault_profile -and (Test-InstanceAlive $_) })
        if ($activeVaultRunning.Count -gt 0 -and $reg.active_vault_profile -ne $PROFILE -and -not $Force) {
            Write-Error "Error: Windows Credential Manager is currently claimed by active profile '$($reg.active_vault_profile)'. Cannot save to '$PROFILE' without -Force."
            Exit-Multigravity 1
        }

        $user = [string]::Empty
        $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
        if ($blob) {
            $tmpTarget = "$credPath.tmp"
            $data = @{
                userName = $user
                blob     = $blob
                updated  = (Get-Date).ToString("o")
            } | ConvertTo-Json
            Set-Content -Path $tmpTarget -Value $data -Encoding UTF8

            if (Test-CredentialFileValid $tmpTarget) {
                Move-Item -Path $tmpTarget -Destination $credPath -Force
                Write-Host "Saved credential for profile '$PROFILE'"
            } else {
                Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue
                Write-Error "Error: Exported credential for '$PROFILE' failed validation check."
                Exit-Multigravity 1
            }
        } else {
            Write-Error "Error: No credentials found in Windows Credential Manager to save for profile '$PROFILE'."
            Exit-Multigravity 1
        }
    }
}

function Remove-GlobalCredential {
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalCred = "$BASE\.global_credentials.json"
    $currentGlobal = Get-GlobalProfile

    Invoke-WithVaultMutex {
        if (Test-Path $globalCred) {
            Remove-Item $globalCred -Force -ErrorAction SilentlyContinue
        }

        $reg = Get-ActiveInstancesRegistry
        if ($reg.active_vault_profile -eq $currentGlobal -or -not $reg.instances -or $reg.instances.Count -eq 0) {
            [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
            $reg.active_vault_profile = $null
            Save-ActiveInstancesRegistry $reg
            if (Test-Path "$BASE\.active_profile") {
                Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
            }
            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
        }

        Write-Host "Removed global credentials."
    }
}

function Remove-ProfileCredential {
    param([string]$PROFILE)
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $g = Get-GlobalProfile

    if ($g -and $g -eq $PROFILE) {
        Remove-GlobalCredential
        return
    }

    Invoke-WithVaultMutex {
        $credPath = "$BASE\$PROFILE\.credentials.json"
        if (Test-Path $credPath) {
            Remove-Item $credPath -Force -ErrorAction SilentlyContinue
        }

        $reg = Get-ActiveInstancesRegistry
        if ($reg.active_vault_profile -eq $PROFILE) {
            [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
            $reg.active_vault_profile = $null
            Save-ActiveInstancesRegistry $reg
            if (Test-Path "$BASE\.active_profile") {
                Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
            }
            $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
        }

        Write-Host "Removed credentials for profile '$PROFILE'"
    }
}

function Restore-GlobalCredential {
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalCred = "$BASE\.global_credentials.json"
    $globalProfile = Get-GlobalProfile

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        if (Test-CredentialFileValid $globalCred) {
            try {
                $gJson = Get-Content $globalCred -Raw | ConvertFrom-Json
                if ($gJson.blob) {
                    [MultigravityCredVault]::ImportCredential($credTarget, $gJson.userName, $gJson.blob) | Out-Null
                    $label = if ($globalProfile) { $globalProfile } else { "global" }
                    Write-Host "Restored global profile credential vault ('$label')."
                    $reg.active_vault_profile = $globalProfile
                    Save-ActiveInstancesRegistry $reg
                    if ($globalProfile) {
                        Set-Content -Path "$BASE\.active_profile" -Value $globalProfile -Encoding UTF8
                    } else {
                        if (Test-Path "$BASE\.active_profile") {
                            Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                    return
                }
            } catch {}
        }

        # Clear vault if no global credential or restoration failed
        [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
        $reg.active_vault_profile = $null
        Save-ActiveInstancesRegistry $reg
        if (Test-Path "$BASE\.active_profile") {
            Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
        }
        $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
    }
}

function Prepare-LaunchCredential {
    param(
        [string]$PROFILE,
        [int]$ProcessId = 0,
        [string]$ProcessType = "cli",
        [System.DateTime]$StartTime = [System.DateTime]::MinValue,
        [switch]$ForceSwitch,
        [string]$ConversationId = $null,
        [Nullable[int]]$ParentPid = $null
    )
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalProfile = Get-GlobalProfile
    $isGlobal = ($globalProfile -and $globalProfile -eq $PROFILE)
    $tag = if ($isGlobal) { "global profile '$PROFILE'" } else { "profile '$PROFILE'" }
    $credPath = Get-ProfileCredentialPath $PROFILE

    $hadSavedCredResult = Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        # Resolve parent PID if launched from within another active profile session
        $resolvedParentPid = if ($null -ne $ParentPid) {
            $ParentPid
        } elseif ($env:MULTIGRAVITY_ACTIVE_PID) {
            $candPid = [int]$env:MULTIGRAVITY_ACTIVE_PID
            if ($reg.instances -and (@($reg.instances | Where-Object { $_.pid -eq $candPid }).Count -gt 0)) {
                $candPid
            } else {
                $null
            }
        } else {
            $null
        }

        if (-not $resolvedParentPid -and $ProcessId -gt 0) {
            try {
                $curr = $ProcessId
                for ($depth = 0; $depth -lt 5; $depth++) {
                    $procCim = Get-CimInstance Win32_Process -Filter "ProcessId = $curr" -ErrorAction SilentlyContinue
                    if (-not $procCim -or -not $procCim.ParentProcessId) { break }
                    $pPid = [int]$procCim.ParentProcessId
                    if ($reg.instances -and (@($reg.instances | Where-Object { $_.pid -eq $pPid }).Count -gt 0)) {
                        $resolvedParentPid = $pPid
                        break
                    }
                    $curr = $pPid
                }
            } catch {}
        }

        $hadCred = $false
        # Always inject profile credentials into Windows Credential Manager for the launch window
        if (Test-CredentialFileValid $credPath) {
            try {
                $json = Get-Content $credPath -Raw | ConvertFrom-Json
                if ($json.blob) {
                    [MultigravityCredVault]::ImportCredential($credTarget, $json.userName, $json.blob) | Out-Null
                    Write-Host "Restored credential vault for $tag"
                    $hadCred = $true
                }
            } catch {
                Write-Warning "Failed to parse credentials from '$credPath': $_"
            }
        } else {
            [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
            Write-Host "Profile '$PROFILE' starting with fresh credential state (login required)."
        }
        $reg.active_vault_profile = $PROFILE

        # Update environment and active profile indicator
        Set-Content -Path "$BASE\.active_profile" -Value $PROFILE -Encoding UTF8
        $env:MULTIGRAVITY_ACTIVE_PROFILE = $PROFILE
        if ($ProcessId -gt 0) {
            $env:MULTIGRAVITY_ACTIVE_PID = $ProcessId
        }

        # Register instance in active registry only if a valid positive PID is provided
        if ($ProcessId -gt 0) {
            $startIso = if ($null -ne $StartTime -and $StartTime -ne [System.DateTime]::MinValue) {
                $StartTime.ToUniversalTime().ToString("o")
            } else {
                (Get-Date).ToUniversalTime().ToString("o")
            }
            $inst = [PSCustomObject]@{
                pid             = $ProcessId
                profile         = $PROFILE
                type            = $ProcessType
                started         = $startIso
                conversation_id = $ConversationId
                parent_pid      = $resolvedParentPid
            }
            $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $ProcessId }) + @($inst)
        }

        Save-ActiveInstancesRegistry $reg
        return [bool]$hadCred
    }

    return [bool]$hadSavedCredResult
}

function Restore-PostLaunchCredential {
    param(
        [string]$PROFILE,
        [bool]$HadSavedCred,
        [int]$ProcessId = 0
    )

    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalProfile = Get-GlobalProfile
    $isGlobal = ($globalProfile -and $globalProfile -eq $PROFILE)
    $tag = if ($isGlobal) { "Global profile '$PROFILE'" } else { "Profile '$PROFILE'" }
    $credPath = Get-ProfileCredentialPath $PROFILE

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry

        # 1. Remove this instance from registry
        if ($ProcessId -gt 0) {
            $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $ProcessId })
            Save-ActiveInstancesRegistry $reg
        }

        # 2. Vault Ownership Verification on Exit:
        # ONLY the active vault profile may inspect vault tokens!
        if ($reg.active_vault_profile -eq $PROFILE) {
            $user = [string]::Empty
            $blob = [MultigravityCredVault]::ExportCredential($credTarget, [ref]$user)
            if ($blob) {
                $shouldSave = $false
                if (-not $HadSavedCred -and -not (Test-CredentialFileValid $credPath)) {
                    # Initial login save for fresh profile
                    $shouldSave = $true
                } elseif ($HadSavedCred -and (Test-Path $credPath)) {
                    try {
                        $existing = Get-Content $credPath -Raw | ConvertFrom-Json
                        # ONLY update if username matches AND token payload has changed
                        if ($existing.userName -eq $user -and -not [MultigravityCredVault]::PayloadsEqual($existing.blob, $blob)) {
                            $shouldSave = $true
                        }
                    } catch {}
                }

                if ($shouldSave) {
                    $tmpTarget = "$credPath.tmp"
                    $data = @{
                        userName = $user
                        blob     = $blob
                        updated  = (Get-Date).ToString("o")
                    } | ConvertTo-Json
                    Set-Content -Path $tmpTarget -Value $data -Encoding UTF8
                    if (Test-CredentialFileValid $tmpTarget) {
                        Move-Item -Path $tmpTarget -Destination $credPath -Force
                        if (-not $HadSavedCred) {
                            Write-Host "Saved initial credential for $tag"
                        } else {
                            Write-Host "Updated refreshed credentials for $tag"
                        }
                    } else {
                        Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Host "$tag credential file is valid; skipping resave on exit."
                }
            } else {
                Write-Host "$tag had no credentials in vault on exit."
            }

            # 3. If no other instances of this profile are running, restore Global credentials at rest
            $remainingProfileInstances = @($reg.instances | Where-Object { $_.profile -eq $PROFILE })
            if ($remainingProfileInstances.Count -eq 0) {
                $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                $env:MULTIGRAVITY_ACTIVE_PID = $null
                $reg.active_vault_profile = $null
                Restore-GlobalCredential
                $reg = Get-ActiveInstancesRegistry
            }
        } else {
            # Vault currently holds another profile or global resting state
            if (Test-CredentialFileValid $credPath) {
                Write-Host "$tag credential file is valid; skipping resave on exit."
            } else {
                Write-Host "$tag was displaced by '$($reg.active_vault_profile)'; skipping credential save on exit."
            }

            if (-not $reg.instances -or @($reg.instances).Count -eq 0) {
                $env:MULTIGRAVITY_ACTIVE_PROFILE = $null
                $env:MULTIGRAVITY_ACTIVE_PID = $null
                if ($reg.active_vault_profile -ne $globalProfile) {
                    $reg.active_vault_profile = $null
                    Restore-GlobalCredential
                    $reg = Get-ActiveInstancesRegistry
                }
            }
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
    $isForceFlag          = ($AllArgs -contains "--force" -or $AllArgs -contains "-Force" -or $AllArgs -contains "-f")

    # Guard: Mutual exclusion for conflicting flags
    if ($isSaveFlag -and $isRemoveCredsFlag) {
        Write-Error "Error: Cannot combine credential saving and removal flags in a single command."
        Exit-Multigravity 1
    }

    $gProf = Get-GlobalProfile

    # Case 1: Saving credentials
    if ($isSaveFlag) {
        if ($isGlobalFlag -or ($gProf -and $gProf -eq $PROFILE)) {
            Save-GlobalCredential $PROFILE -Force:$isForceFlag | Out-Null
            return $true
        } else {
            Save-CredentialToProfile $PROFILE -Force:$isForceFlag
            return $true
        }
    }

    # Case 2: Removing credentials
    if ($isRemoveCredsFlag) {
        if ($isGlobalFlag -or ($gProf -and $gProf -eq $PROFILE)) {
            Remove-GlobalCredential
            return $true
        } else {
            Remove-ProfileCredential $PROFILE
            return $true
        }
    }

    # Case 3: Explicit global promotion via --global flag
    if ($isGlobalFlag) {
        Set-GlobalProfile $PROFILE
        return $true
    }

    # Routine launch without configuration flags
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
    Write-Host "  status [-r|--realtime]       Show running state, active instances (PIDs, Conversation IDs), and profile metrics (or live TUI)"
    Write-Host "  kill <profile|pid|conversation_id|--all>    Terminate running profile instances and reclaim state"
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
    Write-Host "  hooks [install|status|uninstall] Manage conversation tracking lifecycle hooks"
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

    [string[]]$cleanForward = if ($ArgsToForward) {
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
    } else { [string[]]@() }

    $targetName = if ($isGlobal) { "global profile '$PROFILE'" } else { "profile '$PROFILE'" }
    Write-Host "Launching Antigravity Desktop App for $targetName"

    if ($isShared) {
        Sync-SharedProfile $PROFILE
    }
    Ensure-MultigravityHooks -ProfileName $PROFILE

    # Register provisional reservation using current launcher process ID to close TOCTOU window
    $launcherPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $desktopProcess = $null
    $hadSavedCred = $false

    $oldUserProfile  = $env:USERPROFILE
    $oldAppData      = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA

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

    $bootGraceMs = if ($null -ne $env:MULTIGRAVITY_BOOT_GRACE_MS) {
        [int]$env:MULTIGRAVITY_BOOT_GRACE_MS
    } elseif ($env:MULTIGRAVITY_TEST_CRED_TARGET -or $env:MULTIGRAVITY_TEST_MODE) {
        0
    } else {
        2500
    }

    try {
        Invoke-WithVaultMutex {
            $hadSavedCred = Prepare-LaunchCredential -PROFILE $PROFILE -ProcessId $launcherPid -ProcessType "app-pending"
            $desktopProcess = Start-Process -FilePath $APP -ArgumentList $launchArgs -PassThru
            if ($desktopProcess) {
                Register-ActiveInstance -PROFILE $PROFILE -ProcessId $desktopProcess.Id -ProcessType "app" -StartTime $desktopProcess.StartTime -ReplacePid $launcherPid
                if ($bootGraceMs -gt 0) {
                    Start-Sleep -Milliseconds $bootGraceMs
                }
                # Option 1: Transient Launch-Swap -> restore Global Profile credentials immediately post-boot
                if (!$isGlobal) {
                    Restore-GlobalCredential | Out-Null
                }
            }
        }

        if ($desktopProcess) {
            $desktopProcess.WaitForExit()
        }
    } finally {
        if (!$isShared -and !$isGlobal) {
            $env:USERPROFILE  = $oldUserProfile
            $env:APPDATA      = $oldAppData
            $env:LOCALAPPDATA = $oldLocalAppData
        }

        $childPid = if ($desktopProcess) { $desktopProcess.Id } else { $launcherPid }
        Restore-PostLaunchCredential -PROFILE $PROFILE -HadSavedCred $hadSavedCred -ProcessId $childPid
    }
}

function Start-AsyncGlobalRestore {
    param(
        [string]$PROFILE,
        [int]$DelayMs
    )
    if ($DelayMs -le 0) { return $null }

    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $globalCred = "$BASE\.global_credentials.json"
    $globalProfile = Get-GlobalProfile
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutexName = "Local\Multigravity_Vault_Mutex_$userSid"
    $regPath = "$BASE\.active_instances.json"
    $activeProfPath = "$BASE\.active_profile"

    try {
        $asyncPs = [PowerShell]::Create()
        [void]$asyncPs.AddScript({
            param($delay, $mName, $cTarget, $gCred, $gProfile, $rPath, $aPath, $prof)
            Start-Sleep -Milliseconds $delay

            $acquired = $false
            $mutex = $null
            try {
                $mutex = New-Object System.Threading.Mutex($false, $mName)
                try {
                    $acquired = $mutex.WaitOne(10000)
                } catch [System.Threading.AbandonedMutexException] {
                    $acquired = $true
                }
                if (-not $acquired) { return }

                if (Test-Path $rPath) {
                    try {
                        $raw = [System.IO.File]::ReadAllText($rPath, [System.Text.Encoding]::UTF8)
                        if ($raw -match '"active_vault_profile"\s*:\s*"' + [regex]::Escape($prof) + '"') {
                            if (Test-Path $gCred) {
                                $gJson = [System.IO.File]::ReadAllText($gCred, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                                if ($gJson -and $gJson.blob) {
                                    [MultigravityCredVault]::ImportCredential($cTarget, $gJson.userName, $gJson.blob) | Out-Null
                                    $label = if ($gProfile) { $gProfile } else { "global" }
                                    [System.Console]::WriteLine("Restored global profile credential vault ('$label').")

                                    if ($gProfile) {
                                        [System.IO.File]::WriteAllText($aPath, $gProfile, [System.Text.Encoding]::UTF8)
                                    } else {
                                        if (Test-Path $aPath) { [System.IO.File]::Delete($aPath) }
                                    }

                                    $regObj = $raw | ConvertFrom-Json
                                    $regObj.active_vault_profile = $gProfile
                                    $newJson = $regObj | ConvertTo-Json -Depth 5
                                    [System.IO.File]::WriteAllText($rPath, $newJson, [System.Text.Encoding]::UTF8)
                                }
                            } else {
                                [MultigravityCredVault]::RemoveCredential($cTarget) | Out-Null
                                [System.Console]::WriteLine("Restored global profile credential vault (cleared).")
                                if (Test-Path $aPath) { [System.IO.File]::Delete($aPath) }
                                $regObj = $raw | ConvertFrom-Json
                                $regObj.active_vault_profile = $null
                                $newJson = $regObj | ConvertTo-Json -Depth 5
                                [System.IO.File]::WriteAllText($rPath, $newJson, [System.Text.Encoding]::UTF8)
                            }
                        }
                    } catch {}
                }
            } finally {
                if ($acquired -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
                if ($mutex) { try { $mutex.Dispose() } catch {} }
            }
        }).AddArgument($DelayMs).AddArgument($mutexName).AddArgument($credTarget).AddArgument($globalCred).AddArgument($globalProfile).AddArgument($regPath).AddArgument($activeProfPath).AddArgument($PROFILE)

        $handle = $asyncPs.BeginInvoke()
        return @{ PowerShell = $asyncPs; Handle = $handle }
    } catch {
        return $null
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
    Ensure-MultigravityHooks -ProfileName $PROFILE

    [string[]]$cleanForwardArgs = if ($ArgsToForward) {
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
            [string[]]@($res)
        } else {
            [string[]]$filtered
        }
    } else { [string[]]@() }

    $explicitConvId = $null
    if ($ArgsToForward) {
        for ($i = 0; $i -lt $ArgsToForward.Count; $i++) {
            $arg = $ArgsToForward[$i]
            if ($arg -eq "--conversation" -and ($i + 1 -lt $ArgsToForward.Count)) {
                $explicitConvId = $ArgsToForward[$i + 1]
                break
            } elseif ($arg -match '^--conversation=(.+)$') {
                $explicitConvId = $Matches[1]
                break
            }
        }
    }

    $currentProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $hadSavedCred = Prepare-LaunchCredential -PROFILE $PROFILE -ProcessId $currentProc.Id -ProcessType "cli" -StartTime $currentProc.StartTime -ForceSwitch:$forceSwitch -ConversationId $explicitConvId

    $bootGraceMs = if ($null -ne $env:MULTIGRAVITY_BOOT_GRACE_MS) {
        [int]$env:MULTIGRAVITY_BOOT_GRACE_MS
    } elseif ($env:MULTIGRAVITY_TEST_CRED_TARGET -or $env:MULTIGRAVITY_TEST_MODE) {
        0
    } else {
        2500
    }

    $asyncRestore = if (!$isGlobal -and $bootGraceMs -gt 0) {
        Start-AsyncGlobalRestore -PROFILE $PROFILE -DelayMs $bootGraceMs
    } else {
        $null
    }

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
        if ($asyncRestore -and $asyncRestore.PowerShell) {
            try { $asyncRestore.PowerShell.Dispose() } catch {}
        }

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
    param(
        [string]$PROFILE,
        [string]$TargetFolder = ""
    )
    $APP_NAME = "Multigravity $PROFILE"
    $baseFolder = if ($TargetFolder) { $TargetFolder } else { "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" }
    $SHORTCUT_PATH = Join-Path $baseFolder "$APP_NAME.lnk"
    
    $SCRIPT_PATH = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { (Get-Command multigravity -ErrorAction SilentlyContinue).Source }
    if ([string]::IsNullOrEmpty($SCRIPT_PATH)) { $SCRIPT_PATH = "$HOME\.local\bin\multigravity.ps1" }
    
    $WshShell = New-Object -comObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($SHORTCUT_PATH)
    $escapedScriptPath = $SCRIPT_PATH -replace "'", "''"
    
    if ($SCRIPT_PATH -match '\.cmd$') {
        $Shortcut.TargetPath = $SCRIPT_PATH
        $Shortcut.Arguments = $PROFILE
    } else {
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$escapedScriptPath' $PROFILE`""
    }

    if ($APP) {
        $Shortcut.IconLocation = "$APP, 0"
    }
    $shortcutDir = [System.IO.Path]::GetDirectoryName($SHORTCUT_PATH)
    if (!(Test-Path $shortcutDir)) {
        New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    }
    $Shortcut.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Shortcut) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($WshShell) | Out-Null

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
    Ensure-MultigravityHooks -ProfileName $name

    if ($isGlobal) {
        Set-GlobalProfile $name
    }

    if ($createShortcut) {
        Invoke-CreateShortcut $name
    }
}

function Invoke-DeleteProfile {
    param($PROFILE, [switch]$Force)
    Validate-Name $PROFILE
    $BASE = Get-BaseDir
    $credTarget = Get-TargetCredName
    $dir = "$BASE\$PROFILE"

    if (-not $Force) {
        $confirm = Read-Host "Delete profile '$PROFILE' and all its data? [y/N]"
        if ($confirm -notmatch "^[Yy]$") {
            Write-Host "Aborted."
            return
        }
    }

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        $activeInst = @($reg.instances | Where-Object { $_.profile -eq $PROFILE -and (Test-InstanceAlive $_) })
        if ($activeInst.Count -gt 0) {
            Write-Error "Error: Cannot delete profile '$PROFILE' while active instances are running (PIDs: $(($activeInst.pid) -join ', '))."
            Exit-Multigravity 1
        }

        $currentGlobal = Get-GlobalProfile
        if ($currentGlobal -and $currentGlobal -eq $PROFILE) {
            Unset-GlobalProfile -PurgeOnly
            $reg = Get-ActiveInstancesRegistry
        }

        $startMenu = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs")
        $desktop = [System.Environment]::GetFolderPath("Desktop")
        $scStart = Join-Path $startMenu "Multigravity $PROFILE.lnk"
        $scDesk = Join-Path $desktop "Multigravity $PROFILE.lnk"
        if (Test-Path $scStart) { Remove-Item $scStart -Force -ErrorAction SilentlyContinue }
        if (Test-Path $scDesk) { Remove-Item $scDesk -Force -ErrorAction SilentlyContinue }

        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
        }

        if ($reg.active_vault_profile -eq $PROFILE) {
            [MultigravityCredVault]::RemoveCredential($credTarget) | Out-Null
            $reg.active_vault_profile = $null
            Save-ActiveInstancesRegistry $reg
            Restore-GlobalCredential
        } else {
            Save-ActiveInstancesRegistry $reg
        }

        Write-Host "Successfully deleted profile '$PROFILE'."
    }
}

function Invoke-RenameProfile {
    param($OLD, $NEW)
    Validate-Name $OLD
    Validate-Name $NEW
    $BASE = Get-BaseDir

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        $activeOld = @($reg.instances | Where-Object { $_.profile -eq $OLD })
        if ($activeOld.Count -gt 0) {
            Write-Error "Error: Cannot rename profile '$OLD' while active instances are running (PIDs: $(($activeOld.pid) -join ', '))."
            Exit-Multigravity 1
        }

        $oldDir = "$BASE\$OLD"
        $newDir = "$BASE\$NEW"
        if (-not (Test-Path $oldDir)) {
            Write-Error "Error: Profile '$OLD' does not exist."
            Exit-Multigravity 1
        }
        if (-not $OLD.Equals($NEW, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $newDir)) {
            Write-Error "Error: Target profile '$NEW' already exists."
            Exit-Multigravity 1
        }

        Rename-Item -Path $oldDir -NewName $NEW -Force -ErrorAction Stop

        # Re-create canonical shortcuts only if they previously existed
        $startMenu = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs")
        $desktop = [System.Environment]::GetFolderPath("Desktop")
        $oldStart = Join-Path $startMenu "Multigravity $OLD.lnk"
        $oldDesk = Join-Path $desktop "Multigravity $OLD.lnk"

        if (Test-Path $oldStart) {
            if (-not $OLD.Equals($NEW, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item $oldStart -Force -ErrorAction SilentlyContinue
            }
            Invoke-CreateShortcut $NEW $startMenu | Out-Null
        }

        if (Test-Path $oldDesk) {
            if (-not $OLD.Equals($NEW, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item $oldDesk -Force -ErrorAction SilentlyContinue
            }
            Invoke-CreateShortcut $NEW $desktop | Out-Null
        }

        # Update registry state
        if ($reg.active_vault_profile -eq $OLD) {
            $reg.active_vault_profile = $NEW
        }
        Save-ActiveInstancesRegistry $reg

        # Update global profile reference if OLD was global
        $currentGlobal = Get-GlobalProfile
        if ($currentGlobal -and $currentGlobal -eq $OLD) {
            Set-Content -Path "$BASE\.global_profile" -Value $NEW -Encoding UTF8
        }

        Write-Host "Successfully renamed profile '$OLD' to '$NEW'."
    }
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
    $files = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
    $size = if ($files) { ($files | Measure-Object -Property Length -Sum).Sum } else { 0 }
    if (-not $size) { $size = 0 }
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

    # 3. Base Directory Writability
    if (Test-Path $BASE) {
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

    # 4. Global Profile & Credential Health
    $gProf = Get-GlobalProfile
    $globalCred = "$BASE\.global_credentials.json"
    if ($gProf) {
        $hasGlobalCred = Test-CredentialFileValid $globalCred
        $credState = if ($hasGlobalCred) { "credential saved & valid" } else { "no saved credential" }
        Write-Host "  [OK] Global Profile: $gProf ($credState)"

        if (-not (Test-Path "$BASE\$gProf")) {
            Write-Host "  [WARN] Global profile folder '$BASE\$gProf' does not exist."
            $warnings++
        }

        # Check for orphaned local credential in global profile folder
        $localCred = "$BASE\$gProf\.credentials.json"
        if (Test-Path $localCred) {
            Write-Host "  [WARN] Orphaned local credential detected at '$localCred'. Run 'multigravity $gProf --global' to reconcile."
            $warnings++
        }
    } else {
        if (Test-Path $globalCred) {
            Write-Host "  [WARN] Headless global credentials found at '$globalCred' without an active .global_profile configuration! Run 'multigravity <profile> --global' to bind."
            $warnings++
        } else {
            Write-Host "  [INFO] Global Profile: None set (run 'multigravity global <name>' or 'multigravity new <name> --global')"
        }
    }

    # 5. Shared Profiles Health Check (Read-Only)
    if (Test-Path $BASE) {
        $sharedProfiles = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" -and (Test-Path "$($_.FullName)\.shared") }
        if ($sharedProfiles) {
            foreach ($sp in $sharedProfiles) {
                Write-Host "  [OK] Shared Profile '$($sp.Name)': Configured with .shared marker"
            }
        }
    }

    # 6. Active Profile Indicator
    if (Test-Path "$BASE\.active_profile") {
        $act = (Get-Content "$BASE\.active_profile" -Raw).Trim()
        Write-Host "  [INFO] Active profile indicator: $act"
    }

    # 7. Standard Profile Credential Integrity Check
    if (Test-Path $BASE) {
        Get-ChildItem -Path $BASE -Directory | Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" } | ForEach-Object {
            $pName = $_.Name
            $pCred = Join-Path $_.FullName ".credentials.json"
            if (Test-Path $pCred) {
                if (-not (Test-CredentialFileValid $pCred)) {
                    Write-Host "  [WARN] Profile '$pName' credential file is corrupted! Re-save with 'multigravity $pName --save_credential'."
                    $warnings++
                }
            }
        }
    }

    # 8. Active Instances & Registry Concurrency Health
    $reg = Get-ActiveInstancesRegistry
    $activeCount = if ($reg.instances) { $reg.instances.Count } else { 0 }
    $vaultOwner = if ($reg.active_vault_profile) { $reg.active_vault_profile } else { "(None / Global Resting)" }
    Write-Host "  [INFO] Registry Active Vault Owner: $vaultOwner | Live Instances: $activeCount"

    # 9. Conversation Tracking Hook Health
    $installDir = if ($env:MULTIGRAVITY_INSTALL_DIR) { $env:MULTIGRAVITY_INSTALL_DIR } else { "$ROOT_USERPROFILE\.local\bin" }
    $hookCmd = Join-Path $installDir "multigravity-hook.cmd"
    $globalHooksJson = Join-Path (Join-Path (Get-SystemGeminiDir) "config") "hooks.json"
    $hookOk = $false
    if ((Test-Path $hookCmd) -and (Test-Path $globalHooksJson)) {
        try {
            $parsed = Get-Content $globalHooksJson -Raw | ConvertFrom-Json
            if ($parsed."multigravity-conversation-tracker") {
                $hookOk = $true
            }
        } catch {}
    }
    if ($hookOk) {
        Write-Host "  [OK] Conversation Tracking Hook: Configured in $globalHooksJson"
    } else {
        Write-Host "  [WARN] Conversation Tracking Hook: Not configured in $globalHooksJson. Auto-repairing..."
        try {
            Ensure-MultigravityHooks
            Write-Host "  [FIXED] Registered conversation tracking hook in $globalHooksJson"
        } catch {
            Write-Host "  [WARN] Failed to auto-register hook: $_"
            $warnings++
        }
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
        try { Ensure-MultigravityHooks -Force } catch {}
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
    `$opts = @('new', 'list', 'status', 'kill', 'rename', 'delete', 'clone', 'template', 'export', 'import', 'update', 'doctor', 'stats', 'shortcuts', 'hooks', 'completion', 'help', '--shortcut', '--realtime', '-r')
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

function Invoke-RealtimeStatusDashboard {
    param(
        [int]$MaxIterations = 0
    )

    $BASE = Get-BaseDir
    if (-not (Test-Path $BASE)) { Write-Host "No profiles found."; return }

    $isRedirected = $false
    try {
        $isRedirected = [System.Console]::IsInputRedirected
    } catch {
        $isRedirected = $true
    }

    if ($env:MULTIGRAVITY_REALTIME_MAX_ITERATIONS) {
        try {
            $envMax = [int]$env:MULTIGRAVITY_REALTIME_MAX_ITERATIONS
            if ($envMax -gt 0) { $MaxIterations = $envMax }
        } catch {}
    }

    $selectedIndex = 0
    $statusMsg = ""
    $statusMsgExpiry = [System.DateTime]::MinValue
    $running = $true
    $iterations = 0
    $refreshIntervalMs = 1500
    $sliceMs = 25
    $displayItems = [System.Collections.Generic.List[psobject]]::new()
    $profileRows = [System.Collections.Generic.List[psobject]]::new()

    $prevCursorVisible = $true
    try {
        $prevCursorVisible = [System.Console]::CursorVisible
        [System.Console]::CursorVisible = $false
    } catch {}

    $UpdateData = {
        $reg = Get-ActiveInstancesRegistry
        $instances = if ($reg -and $reg.instances) { @($reg.instances) } else { @() }

        $statusDirty = $false
        foreach ($inst in $instances) {
            $resolved = Get-ActiveConversationIdForPid $inst.pid
            if ($resolved -and ($inst.conversation_id -ne $resolved)) {
                $inst | Add-Member -NotePropertyName "conversation_id" -NotePropertyValue $resolved -Force
                $statusDirty = $true
            }
        }
        if ($statusDirty) {
            Invoke-WithVaultMutex {
                $curReg = Get-ActiveInstancesRegistry
                if ($curReg -and $curReg.instances) {
                    foreach ($ci in $curReg.instances) {
                        $m = $instances | Where-Object { $_.pid -eq $ci.pid }
                        if ($m -and $m.conversation_id) {
                            $ci | Add-Member -NotePropertyName "conversation_id" -NotePropertyValue $m.conversation_id -Force
                        }
                    }
                    Save-ActiveInstancesRegistry $curReg
                }
            }
        }

        $instByPid = @{}
        $childrenByParent = @{}
        foreach ($inst in $instances) {
            $instByPid[[int]$inst.pid] = $inst
        }
        $rootInstances = [System.Collections.Generic.List[psobject]]::new()
        foreach ($inst in $instances) {
            $pPid = if ($inst.parent_pid) { [int]$inst.parent_pid } else { 0 }
            if ($pPid -gt 0 -and ($instByPid.ContainsKey($pPid))) {
                if (-not ($childrenByParent.ContainsKey($pPid))) {
                    $childrenByParent[$pPid] = [System.Collections.Generic.List[psobject]]::new()
                }
                $childrenByParent[$pPid].Add($inst)
            } else {
                $rootInstances.Add($inst)
            }
        }

        $newDisplayItems = [System.Collections.Generic.List[psobject]]::new()
        $addDashboardItem = {
            param($itemInst, [int]$itemDepth = 0)
            $dashItem = [PSCustomObject]@{
                inst    = $itemInst
                depth   = $itemDepth
                pid     = [int]$itemInst.pid
                profile = $itemInst.profile
            }
            $newDisplayItems.Add($dashItem) | Out-Null
            $cPid = [int]$itemInst.pid
            if ($childrenByParent.ContainsKey($cPid)) {
                foreach ($child in $childrenByParent[$cPid]) {
                    & $addDashboardItem $child ($itemDepth + 1)
                }
            }
        }
        foreach ($root in $rootInstances) {
            & $addDashboardItem $root 0
        }

        $dirs = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" }
        $gProf = Get-GlobalProfile

        $newProfileRows = [System.Collections.Generic.List[psobject]]::new()
        foreach ($d in $dirs) {
            $pInsts = @($instances | Where-Object { $_.profile -eq $d.Name })
            $runningCount = if ($pInsts.Count -gt 0) { "yes ($($pInsts.Count))" } else { "no" }

            if ($runningCount -eq "no") {
                $procs = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue
                if ($procs) {
                    foreach ($proc in $procs) {
                        try {
                            $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                            $escapedName = [regex]::Escape($d.Name)
                            if ($cl -and ($cl -match "[\\/]$escapedName([\\/]|\s|$|`")" -or $cl -match "--user-data-dir[=\s]+[`"']?.*?[\\/]$escapedName([\\/]|\s|$|`")")) { $runningCount = "yes"; break }
                        } catch {}
                    }
                }
            }

            $ptype = if ($gProf -and ($d.Name -eq $gProf)) {
                if (Test-Path "$($d.FullName)\.shared") { "global (shared)" } else { "global" }
            } elseif (Test-Path "$($d.FullName)\.shared") { "shared" } else { "full" }
            $lastUsed = $d.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            $size     = Get-FolderSize $d.FullName

            $newProfileRows.Add([PSCustomObject]@{
                Name         = $d.Name
                RunningCount = $runningCount
                Type         = $ptype
                LastUsed     = $lastUsed
                Size         = $size
            }) | Out-Null
        }

        return [PSCustomObject]@{
            DisplayItems = $newDisplayItems
            ProfileRows  = $newProfileRows
        }
    }

    $RenderView = {
        try {
            [System.Console]::Clear()
        } catch {
            Write-Host ""
        }

        $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "==================================================================================================="
        Write-Host (" Multigravity Status (Realtime Mode)                                       [ {0} ]" -f $nowStr)
        Write-Host "==================================================================================================="

        Write-Host "Active Instances (Task Manager):"
        if ($displayItems.Count -gt 0) {
            Write-Host ("  {0,-4} {1,-12} {2,-14} {3,-6} {4,-38} {5,-20} {6}" -f "SEL", "PID", "PROFILE", "TYPE", "CONVERSATION ID", "STARTED", "RUNTIME")
            Write-Host ("  {0,-4} {1,-12} {2,-14} {3,-6} {4,-38} {5,-20} {6}" -f "---", "---", "-------", "----", "---------------", "-------", "-------")

            for ($i = 0; $i -lt $displayItems.Count; $i++) {
                $dItem = $displayItems[$i]
                $inst = $dItem.inst
                $depth = $dItem.depth
                $isSelected = ($i -eq $selectedIndex)
                $selMarker = if ($isSelected) { "* " } else { "  " }

                $runtimeStr = "unknown"
                $startedStr = $inst.started
                if ($inst.started) {
                    try {
                        $st = [System.DateTime]::Parse($inst.started).ToLocalTime()
                        $startedStr = $st.ToString("yyyy-MM-dd HH:mm:ss")
                        $diff = (Get-Date) - $st
                        if ($diff.TotalSeconds -ge 0) {
                            $runtimeStr = "{0:d2}:{1:d2}:{2:d2}" -f [int]$diff.TotalHours, $diff.Minutes, $diff.Seconds
                        }
                    } catch {}
                }
                $convIdStr = if ($inst.conversation_id) { $inst.conversation_id } else { "-" }
                $pidStr = if ($depth -eq 0) {
                    "$($inst.pid)"
                } else {
                    ("  " * ($depth - 1)) + "\-- " + $inst.pid
                }

                $lineStr = ("  {0,-4} {1,-12} {2,-14} {3,-6} {4,-38} {5,-20} {6}" -f $selMarker, $pidStr, $inst.profile, $inst.type, $convIdStr, $startedStr, $runtimeStr)
                if ($isSelected) {
                    Write-Host $lineStr -ForegroundColor Cyan
                } else {
                    Write-Host $lineStr
                }
            }
        } else {
            Write-Host "  (None running)"
        }
        Write-Host ""

        Write-Host "All Profiles:"
        Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f "PROFILE", "RUNNING", "TYPE", "LAST USED", "SIZE")
        Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f "-------", "-------", "----", "---------", "----")

        foreach ($p in $profileRows) {
            if ($p.RunningCount -ne "no") {
                Write-Host ("{0,-18} " -f $p.Name) -NoNewline
                Write-Host ("{0,-10} " -f $p.RunningCount) -NoNewline -ForegroundColor Green
                Write-Host ("{0,-16} {1,-20} {2}" -f $p.Type, $p.LastUsed, $p.Size)
            } else {
                Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f $p.Name, $p.RunningCount, $p.Type, $p.LastUsed, $p.Size)
            }
        }

        Write-Host ""
        Write-Host "---------------------------------------------------------------------------------------------------"
        Write-Host " Controls: [Up/Down] Select PID  |  [K] Kill Selected PID  |  [R] Refresh  |  [E/Q] Exit"
        if ($statusMsg -and ((Get-Date) -le $statusMsgExpiry)) {
            Write-Host " Status:   $statusMsg" -ForegroundColor Yellow
        } else {
            Write-Host " Status:   Monitoring active instances (auto-refresh every 1.5s)"
        }
        Write-Host "==================================================================================================="
    }

    # Initial data poll & frame render
    $data = & $UpdateData
    $displayItems = $data.DisplayItems
    $profileRows  = $data.ProfileRows
    $iterations++

    if ($displayItems.Count -eq 0) {
        $selectedIndex = -1
    } else {
        if ($selectedIndex -lt 0) { $selectedIndex = 0 }
        if ($selectedIndex -ge $displayItems.Count) { $selectedIndex = $displayItems.Count - 1 }
    }

    & $RenderView

    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($running) {
            if ($MaxIterations -gt 0 -and ($iterations -ge $MaxIterations)) {
                $running = $false
                break
            }
            if ($isRedirected) {
                $running = $false
                break
            }

            $keyAvail = $false
            try {
                $keyAvail = [System.Console]::KeyAvailable
            } catch {
                $keyAvail = $false
                $running = $false
                break
            }

            if ($keyAvail) {
                $needsRedraw = $false
                while ($true) {
                    $hasKey = $false
                    try {
                        $hasKey = [System.Console]::KeyAvailable
                    } catch {
                        $hasKey = $false
                    }
                    if (-not $hasKey) { break }

                    $key = [System.Console]::ReadKey($true)
                    switch ($key.Key) {
                        ([System.ConsoleKey]::UpArrow) {
                            if ($displayItems.Count -gt 0 -and ($selectedIndex -gt 0)) {
                                $selectedIndex--
                                $needsRedraw = $true
                            }
                        }
                        ([System.ConsoleKey]::DownArrow) {
                            if ($displayItems.Count -gt 0 -and ($selectedIndex -lt ($displayItems.Count - 1))) {
                                $selectedIndex++
                                $needsRedraw = $true
                            }
                        }
                        ([System.ConsoleKey]::Home) {
                            if ($displayItems.Count -gt 0 -and ($selectedIndex -ne 0)) {
                                $selectedIndex = 0
                                $needsRedraw = $true
                            }
                        }
                        ([System.ConsoleKey]::End) {
                            if ($displayItems.Count -gt 0 -and ($selectedIndex -ne ($displayItems.Count - 1))) {
                                $selectedIndex = $displayItems.Count - 1
                                $needsRedraw = $true
                            }
                        }
                        ([System.ConsoleKey]::K) {
                            if ($displayItems.Count -gt 0 -and ($selectedIndex -ge 0) -and ($selectedIndex -lt $displayItems.Count)) {
                                $targetItem = $displayItems[$selectedIndex]
                                $targetPid = [int]$targetItem.pid
                                $targetProfile = $targetItem.profile
                                Invoke-KillProfile "$targetPid" | Out-Null
                                $statusMsg = "[OK] Killed instance PID $targetPid (profile '$targetProfile') and all child processes."
                                $statusMsgExpiry = (Get-Date).AddSeconds(4)
                            } else {
                                $statusMsg = "[!] No active instance selected to kill."
                                $statusMsgExpiry = (Get-Date).AddSeconds(3)
                            }
                            $data = & $UpdateData
                            $displayItems = $data.DisplayItems
                            $profileRows  = $data.ProfileRows
                            $iterations++
                            if ($displayItems.Count -eq 0) {
                                $selectedIndex = -1
                            } else {
                                if ($selectedIndex -ge $displayItems.Count) { $selectedIndex = $displayItems.Count - 1 }
                                if ($selectedIndex -lt 0) { $selectedIndex = 0 }
                            }
                            $needsRedraw = $true
                        }
                        ([System.ConsoleKey]::R) {
                            $statusMsg = "[i] Refreshed."
                            $statusMsgExpiry = (Get-Date).AddSeconds(2)
                            $data = & $UpdateData
                            $displayItems = $data.DisplayItems
                            $profileRows  = $data.ProfileRows
                            $iterations++
                            if ($displayItems.Count -eq 0) {
                                $selectedIndex = -1
                            } else {
                                if ($selectedIndex -ge $displayItems.Count) { $selectedIndex = $displayItems.Count - 1 }
                                if ($selectedIndex -lt 0) { $selectedIndex = 0 }
                            }
                            $needsRedraw = $true
                        }
                        ([System.ConsoleKey]::E) {
                            $running = $false
                            break
                        }
                        ([System.ConsoleKey]::Q) {
                            $running = $false
                            break
                        }
                        ([System.ConsoleKey]::Escape) {
                            $running = $false
                            break
                        }
                    }
                    if (-not $running) { break }
                }

                if ($needsRedraw -and $running) {
                    & $RenderView
                    $timer.Restart()
                }
            } else {
                if ($timer.ElapsedMilliseconds -ge $refreshIntervalMs) {
                    $data = & $UpdateData
                    $displayItems = $data.DisplayItems
                    $profileRows  = $data.ProfileRows
                    $iterations++

                    if ($displayItems.Count -eq 0) {
                        $selectedIndex = -1
                    } else {
                        if ($selectedIndex -ge $displayItems.Count) { $selectedIndex = $displayItems.Count - 1 }
                        if ($selectedIndex -lt 0) { $selectedIndex = 0 }
                    }

                    & $RenderView
                    $timer.Restart()
                }

                Start-Sleep -Milliseconds $sliceMs
            }
        }
    } finally {
        try { [System.Console]::CursorVisible = $prevCursorVisible } catch {}
        Write-Host ""
    }
}

function Invoke-StatusProfiles {
    param(
        [switch]$RealTime
    )

    if ($RealTime) {
        Invoke-RealtimeStatusDashboard
        return
    }

    $BASE = Get-BaseDir
    if (!(Test-Path $BASE)) { Write-Host "No profiles found."; return }

    $reg = Get-ActiveInstancesRegistry
    $instances = if ($reg.instances) { @($reg.instances) } else { @() }

    Write-Host "Active Instances (Task Manager):"
    if ($instances.Count -gt 0) {
        Write-Host ("  {0,-12} {1,-14} {2,-6} {3,-38} {4,-20} {5}" -f "PID", "PROFILE", "TYPE", "CONVERSATION ID", "STARTED", "RUNTIME")
        Write-Host ("  {0,-12} {1,-14} {2,-6} {3,-38} {4,-20} {5}" -f "---", "-------", "----", "---------------", "-------", "-------")
        $script:statusDirty = $false

        $instByPid = @{}
        $childrenByParent = @{}
        foreach ($inst in $instances) {
            $instByPid[[int]$inst.pid] = $inst
        }

        $rootInstances = [System.Collections.Generic.List[psobject]]::new()
        foreach ($inst in $instances) {
            $pPid = if ($inst.parent_pid) { [int]$inst.parent_pid } else { 0 }
            if ($pPid -gt 0 -and $instByPid.ContainsKey($pPid)) {
                if (-not $childrenByParent.ContainsKey($pPid)) {
                    $childrenByParent[$pPid] = [System.Collections.Generic.List[psobject]]::new()
                }
                $childrenByParent[$pPid].Add($inst)
            } else {
                $rootInstances.Add($inst)
            }
        }

        function Format-InstanceRow {
            param($inst, [int]$depth = 0)
            $runtimeStr = "unknown"
            $startedStr = $inst.started
            if ($inst.started) {
                try {
                    $st = [System.DateTime]::Parse($inst.started).ToLocalTime()
                    $startedStr = $st.ToString("yyyy-MM-dd HH:mm:ss")
                    $diff = (Get-Date) - $st
                    if ($diff.TotalSeconds -ge 0) {
                        $runtimeStr = "{0:d2}:{1:d2}:{2:d2}" -f [int]$diff.TotalHours, $diff.Minutes, $diff.Seconds
                    }
                } catch {}
            }
            $resolved = Get-ActiveConversationIdForPid $inst.pid
            if ($resolved) {
                if ($inst.conversation_id -ne $resolved) {
                    $inst | Add-Member -NotePropertyName "conversation_id" -NotePropertyValue $resolved -Force
                    $script:statusDirty = $true
                }
                $convIdStr = $resolved
            } elseif ($inst.conversation_id) {
                $convIdStr = $inst.conversation_id
            } else {
                $convIdStr = "-"
            }

            $pidStr = if ($depth -eq 0) {
                "$($inst.pid)"
            } else {
                ("  " * ($depth - 1)) + "\-- " + $inst.pid
            }

            Write-Host ("  {0,-12} {1,-14} {2,-6} {3,-38} {4,-20} {5}" -f $pidStr, $inst.profile, $inst.type, $convIdStr, $startedStr, $runtimeStr)

            $cPid = [int]$inst.pid
            if ($childrenByParent.ContainsKey($cPid)) {
                foreach ($child in $childrenByParent[$cPid]) {
                    Format-InstanceRow $child ($depth + 1)
                }
            }
        }

        foreach ($root in $rootInstances) {
            Format-InstanceRow $root 0
        }

        if ($script:statusDirty) {
            Invoke-WithVaultMutex {
                $currentReg = Get-ActiveInstancesRegistry
                if ($currentReg.instances) {
                    foreach ($ci in $currentReg.instances) {
                        $m = $instances | Where-Object { $_.pid -eq $ci.pid }
                        if ($m -and $m.conversation_id) {
                            $ci | Add-Member -NotePropertyName "conversation_id" -NotePropertyValue $m.conversation_id -Force
                        }
                    }
                    Save-ActiveInstancesRegistry $currentReg
                }
            }
        }
    } else {
        Write-Host "  (None running)"
    }
    Write-Host ""

    Write-Host "All Profiles:"
    Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f "PROFILE", "RUNNING", "TYPE", "LAST USED", "SIZE")
    Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f "-------", "-------", "----", "---------", "----")

    $dirs = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ".templates" -and $_.Name -notlike ".*" }

    $gProf = Get-GlobalProfile

    foreach ($d in $dirs) {
        $pInsts = @($instances | Where-Object { $_.profile -eq $d.Name })
        $running = if ($pInsts.Count -gt 0) { "yes ($($pInsts.Count))" } else { "no" }

        # Fallback process check if not in registry
        if ($running -eq "no") {
            $procs = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue
            if ($procs) {
                foreach ($proc in $procs) {
                    try {
                        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                        $escapedName = [regex]::Escape($d.Name)
                        if ($cl -and ($cl -match "[\\/]$escapedName([\\/]|\s|$|`")" -or $cl -match "--user-data-dir[=\s]+[`"']?.*?[\\/]$escapedName([\\/]|\s|$|`")")) { $running = "yes"; break }
                    } catch {}
                }
            }
        }

        $ptype = if ($gProf -and $d.Name -eq $gProf) {
            if (Test-Path "$($d.FullName)\.shared") { "global (shared)" } else { "global" }
        } elseif (Test-Path "$($d.FullName)\.shared") { "shared" } else { "full" }
        $lastUsed = $d.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        $size     = Get-FolderSize $d.FullName

        if ($running -ne "no") {
            Write-Host ("{0,-18} " -f $d.Name) -NoNewline
            Write-Host ("{0,-10} " -f $running) -NoNewline -ForegroundColor Green
            Write-Host ("{0,-16} {1,-20} {2}" -f $ptype, $lastUsed, $size)
        } else {
            Write-Host ("{0,-18} {1,-10} {2,-16} {3,-20} {4}" -f $d.Name, $running, $ptype, $lastUsed, $size)
        }
    }
}

function Invoke-KillProfile {
    param(
        [string]$Target,
        [string[]]$Extra
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Error "Error: usage: multigravity kill <profile|pid|conversation_id|--all>"
        Exit-Multigravity 1
    }

    $BASE = Get-BaseDir

    Invoke-WithVaultMutex {
        $reg = Get-ActiveInstancesRegistry
        $instances = if ($reg.instances) { @($reg.instances) } else { @() }
        $killedPids = [System.Collections.Generic.List[int]]::new()

        if ($Target -eq "--all" -or $Target -eq "-a" -or $Target -eq "all") {
            # Kill all registered instances
            foreach ($inst in $instances) {
                try {
                    $p = Get-Process -Id $inst.pid -ErrorAction SilentlyContinue
                    if ($p) {
                        Stop-Process -Id $inst.pid -Force -ErrorAction SilentlyContinue
                        $killedPids.Add($inst.pid)
                    }
                } catch {}
            }

            # Also scan for any rogue Antigravity processes matching profile paths
            $allProcs = Get-Process -Name "Antigravity", "Antigravity.exe" -ErrorAction SilentlyContinue
            if ($allProcs) {
                foreach ($ap in $allProcs) {
                    if ($killedPids.Contains($ap.Id)) { continue }
                    try {
                        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($ap.Id)" -ErrorAction SilentlyContinue).CommandLine
                        if ($cl -and $cl -like "*$BASE*") {
                            Stop-Process -Id $ap.Id -Force -ErrorAction SilentlyContinue
                            $killedPids.Add($ap.Id)
                        }
                    } catch {}
                }
            }

            $reg.instances = @()
            $reg.active_vault_profile = $null
            Save-ActiveInstancesRegistry $reg
            Restore-GlobalCredential | Out-Null
            Write-Host "Killed all active profile instances ($($killedPids.Count) process(es) terminated). Restored global credential state."
            return
        }

        # Check if Target is a conversation ID (UUID)
        if ($Target -match '^[0-9a-fA-F\-]{36}$') {
            $matchedInst = $instances | Where-Object { $_.conversation_id -eq $Target }
            if ($matchedInst) {
                $targetPid = [int]$matchedInst.pid
                $targetProfile = $matchedInst.profile
                try {
                    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $targetPid" -ErrorAction SilentlyContinue
                    foreach ($ch in $children) {
                        try { Stop-Process -Id $ch.ProcessId -Force -ErrorAction SilentlyContinue; $killedPids.Add($ch.ProcessId) } catch {}
                    }
                    $childInsts = @($reg.instances | Where-Object { $_.parent_pid -eq $targetPid })
                    foreach ($ci in $childInsts) {
                        try {
                            $grandChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($ci.pid)" -ErrorAction SilentlyContinue
                            foreach ($gc in $grandChildren) {
                                try { Stop-Process -Id $gc.ProcessId -Force -ErrorAction SilentlyContinue; $killedPids.Add($gc.ProcessId) } catch {}
                            }
                            Stop-Process -Id $ci.pid -Force -ErrorAction SilentlyContinue
                            $killedPids.Add($ci.pid)
                        } catch {}
                    }
                    $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
                    if ($p) {
                        Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
                        $killedPids.Add($targetPid)
                    }
                } catch {}

                $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $targetPid -and $_.parent_pid -ne $targetPid })
                if ($reg.active_vault_profile -eq $targetProfile) {
                    $hasOther = @($reg.instances | Where-Object { $_.profile -eq $targetProfile })
                    if ($hasOther.Count -eq 0) {
                        $reg.active_vault_profile = $null
                        Restore-GlobalCredential | Out-Null
                        $reg = Get-ActiveInstancesRegistry
                    }
                }
                if ($reg.instances.Count -eq 0) {
                    $reg.active_vault_profile = $null
                    Restore-GlobalCredential | Out-Null
                    $reg = Get-ActiveInstancesRegistry
                } else {
                    Save-ActiveInstancesRegistry $reg
                }

                if ($killedPids.Count -gt 0) {
                    Write-Host "Killed instance PID $targetPid (profile '$targetProfile', conversation '$Target')."
                } else {
                    Write-Host "Instance PID $targetPid (conversation '$Target') was not running or could not be found."
                }
                return
            } else {
                Write-Host "No active instance found with conversation ID '$Target'."
                return
            }
        }

        # Check if Target is a numeric PID
        if ($Target -match '^\d+$') {
            $targetPid = [int]$Target
            $matchedInst = $instances | Where-Object { $_.pid -eq $targetPid }
            $targetProfile = if ($matchedInst) { $matchedInst.profile } else { "unknown" }

            try {
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $targetPid" -ErrorAction SilentlyContinue
                foreach ($ch in $children) {
                    try { Stop-Process -Id $ch.ProcessId -Force -ErrorAction SilentlyContinue; $killedPids.Add($ch.ProcessId) } catch {}
                }
                $childInsts = @($reg.instances | Where-Object { $_.parent_pid -eq $targetPid })
                foreach ($ci in $childInsts) {
                    try {
                        $grandChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($ci.pid)" -ErrorAction SilentlyContinue
                        foreach ($gc in $grandChildren) {
                            try { Stop-Process -Id $gc.ProcessId -Force -ErrorAction SilentlyContinue; $killedPids.Add($gc.ProcessId) } catch {}
                        }
                        Stop-Process -Id $ci.pid -Force -ErrorAction SilentlyContinue
                        $killedPids.Add($ci.pid)
                    } catch {}
                }
                $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
                if ($p) {
                    Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
                    $killedPids.Add($targetPid)
                }
            } catch {}

            $reg.instances = @($reg.instances | Where-Object { $_.pid -ne $targetPid -and $_.parent_pid -ne $targetPid })
            if ($matchedInst -and $reg.active_vault_profile -eq $matchedInst.profile) {
                $hasOther = @($reg.instances | Where-Object { $_.profile -eq $matchedInst.profile })
                if ($hasOther.Count -eq 0) {
                    $reg.active_vault_profile = $null
                    Restore-GlobalCredential | Out-Null
                    $reg = Get-ActiveInstancesRegistry
                }
            }
            if ($reg.instances.Count -eq 0) {
                $reg.active_vault_profile = $null
                Restore-GlobalCredential | Out-Null
                $reg = Get-ActiveInstancesRegistry
            } else {
                Save-ActiveInstancesRegistry $reg
            }

            if ($killedPids.Count -gt 0) {
                Write-Host "Killed instance PID $targetPid (profile '$targetProfile')."
            } else {
                Write-Host "Process PID $targetPid was not running or could not be found."
            }
            return
        }

        # Otherwise Target is a profile name
        Validate-Name $Target
        $profileInsts = @($instances | Where-Object { $_.profile -eq $Target })
        $parentPids = @($profileInsts.pid)

        foreach ($inst in $profileInsts) {
            try {
                $childInsts = @($reg.instances | Where-Object { $_.parent_pid -eq $inst.pid })
                foreach ($ci in $childInsts) {
                    try {
                        $grandChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($ci.pid)" -ErrorAction SilentlyContinue
                        foreach ($gc in $grandChildren) {
                            try { Stop-Process -Id $gc.ProcessId -Force -ErrorAction SilentlyContinue; $killedPids.Add($gc.ProcessId) } catch {}
                        }
                        Stop-Process -Id $ci.pid -Force -ErrorAction SilentlyContinue
                        $killedPids.Add($ci.pid)
                    } catch {}
                }
                $p = Get-Process -Id $inst.pid -ErrorAction SilentlyContinue
                if ($p) {
                    Stop-Process -Id $inst.pid -Force -ErrorAction SilentlyContinue
                    $killedPids.Add($inst.pid)
                }
            } catch {}
        }

        # Check for un-registered processes matching this profile name (with strict boundary)
        $allProcs = Get-Process -Name "Antigravity", "Antigravity.exe" -ErrorAction SilentlyContinue
        if ($allProcs) {
            $escapedTarget = [regex]::Escape($Target)
            foreach ($ap in $allProcs) {
                if ($killedPids.Contains($ap.Id)) { continue }
                try {
                    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($ap.Id)" -ErrorAction SilentlyContinue).CommandLine
                    if ($cl -and ($cl -match "[\\/]$escapedTarget([\\/]|\s|$|`")" -or $cl -match "--user-data-dir[=\s]+[`"']?.*?[\\/]$escapedTarget([\\/]|\s|$|`")")) {
                        Stop-Process -Id $ap.Id -Force -ErrorAction SilentlyContinue
                        $killedPids.Add($ap.Id)
                    }
                } catch {}
            }
        }

        $reg.instances = @($reg.instances | Where-Object { $_.profile -ne $Target -and (-not ($parentPids -contains $_.parent_pid)) })
        if ($reg.active_vault_profile -eq $Target) {
            $reg.active_vault_profile = $null
            Restore-GlobalCredential | Out-Null
            $reg = Get-ActiveInstancesRegistry
        }
        if ($reg.instances.Count -eq 0) {
            $reg.active_vault_profile = $null
            Restore-GlobalCredential | Out-Null
            $reg = Get-ActiveInstancesRegistry
        } else {
            Save-ActiveInstancesRegistry $reg
        }

        if ($killedPids.Count -gt 0) {
            Write-Host "Killed $($killedPids.Count) instance(s) for profile '$Target' (PIDs: $(($killedPids) -join ', '))."
        } else {
            Write-Host "No active instances found for profile '$Target'."
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
    [string[]]$forward = if ($rawTokens.Count -ge 2) { @($rawTokens | Select-Object -Skip 1) } else { @() }
    $arg1 = if ($forward.Count -ge 1) { $forward[0] } else { $null }
    $arg2 = if ($forward.Count -ge 2) { $forward[1] } else { $null }
    [string[]]$extra = if ($forward.Count -ge 3) { @($forward | Select-Object -Skip 2) } else { @() }
    [string[]]$subForward = if ($forward.Count -ge 1) { @($forward | Select-Object -Skip 1) } else { @() }

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
            $isRealTime = ($arg1 -in @("--realtime", "-r", "--live", "-l", "--watch", "-w") -or $extra -contains "--realtime" -or $extra -contains "-r")
            Invoke-StatusProfiles -RealTime:$isRealTime
        }
        "realtime" {
            Invoke-StatusProfiles -RealTime
        }
        "-r" {
            Invoke-StatusProfiles -RealTime
        }
        "--realtime" {
            Invoke-StatusProfiles -RealTime
        }
        "kill" {
            Invoke-KillProfile $arg1 $extra
        }
        "rename" {
            Invoke-RenameProfile $arg1 $arg2
        }
        "delete" {
            $forceDel = ($extra -contains "--force" -or $subForward -contains "--force" -or $arg2 -eq "--force" -or $extra -contains "-f" -or $subForward -contains "-f" -or $arg2 -eq "-f")
            Invoke-DeleteProfile $arg1 -Force:$forceDel
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
        "hooks" {
            Invoke-HooksCommand $arg1 $extra
            break
        }
        "hook" {
            Invoke-HooksCommand $arg1 $extra
            break
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
