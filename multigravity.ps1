<#
.SYNOPSIS
Run multiple Antigravity profiles at the same time.
#>

param (
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$cmd,
    
    [Parameter(Position = 1, Mandatory = $false)]
    [string]$arg1,

    [Parameter(Position = 2, Mandatory = $false)]
    [string]$arg2,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$BASE = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$env:USERPROFILE\.config\multigravity\profiles" }

function Find-Antigravity {
    $paths = @(
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
        "$env:LOCALAPPDATA\Programs\Antigravity\bin\agy.cmd",
        "$env:LOCALAPPDATA\Programs\Antigravity\bin\agy.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\bin\agy.cmd",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\bin\agy.exe",
        "$env:LOCALAPPDATA\Programs\Antigravity CLI\agy.exe",
        "$env:PROGRAMFILES\Antigravity\bin\agy.cmd",
        "$env:PROGRAMFILES\Antigravity\bin\agy.exe",
        "$env:PROGRAMFILES\Antigravity CLI\bin\agy.cmd",
        "$env:PROGRAMFILES\Antigravity CLI\bin\agy.exe",
        "${env:ProgramFiles(x86)}\Antigravity\bin\agy.cmd",
        "${env:ProgramFiles(x86)}\Antigravity\bin\agy.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    
    # Try to find in PATH
    $cmdObj = Get-Command agy.cmd, agy.exe, agy -ErrorAction SilentlyContinue
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
    return "$env:APPDATA\Antigravity"
}

function Get-SystemExtensionsDir {
    return "$env:USERPROFILE\.antigravity\extensions"
}

function Get-SystemGeminiDir {
    return "$env:USERPROFILE\.gemini"
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

$TARGET_CRED_NAME = "gemini:antigravity"

function Get-GlobalProfile {
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
    if ([string]::IsNullOrWhiteSpace($PROFILE)) {
        Write-Error "Error: profile name required"
        exit 1
    }
    if ($PROFILE -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-]*$") {
        Write-Error "Error: profile name must start with alphanumeric and contain only letters, numbers, or hyphens"
        exit 1
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
    if ($PROFILE) {
        Set-GlobalProfile $PROFILE
    }
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }
    $user = $null
    $blob = [MultigravityCredVault]::ExportCredential($TARGET_CRED_NAME, [ref]$user)
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
        Write-Host "No active credential found in Windows Credential Manager under '$TARGET_CRED_NAME'."
        return $false
    }
}

function Remove-GlobalCredential {
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
    $g = Get-GlobalProfile
    if ($g -and $g -eq $PROFILE) {
        Save-GlobalCredential $PROFILE | Out-Null
        return $true
    }
    $profileDir = "$BASE\$PROFILE"
    if (!(Test-Path $profileDir)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        exit 1
    }
    $user = $null
    $blob = [MultigravityCredVault]::ExportCredential($TARGET_CRED_NAME, [ref]$user)
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
        Write-Host "No active credential found in Windows Credential Manager under '$TARGET_CRED_NAME'."
        return $false
    }
}

function Remove-ProfileCredential {
    param($PROFILE)
    $g = Get-GlobalProfile
    if ($g -and $g -eq $PROFILE) {
        Remove-GlobalCredential
        return
    }
    $profileDir = "$BASE\$PROFILE"
    if (!(Test-Path $profileDir)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        exit 1
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
    $globalCredPath = "$BASE\.global_credentials.json"
    if (Test-Path $globalCredPath) {
        try {
            $json = Get-Content $globalCredPath -Raw | ConvertFrom-Json
            if ($json.blob) {
                [MultigravityCredVault]::ImportCredential($TARGET_CRED_NAME, $json.userName, $json.blob) | Out-Null
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
    [MultigravityCredVault]::RemoveCredential($TARGET_CRED_NAME) | Out-Null
    Write-Host "Cleared credential vault (no global credential to restore)."
    Remove-Item "$BASE\.active_profile" -Force -ErrorAction SilentlyContinue
}

function Prepare-LaunchCredential {
    param($PROFILE)
    $profileDir = "$BASE\$PROFILE"
    $credPath   = "$profileDir\.credentials.json"
    
    if (!(Test-Path $BASE)) {
        New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    }
    Set-Content -Path "$BASE\.active_profile" -Value $PROFILE -Encoding UTF8

    $hadSavedCred = Test-Path $credPath

    if ($hadSavedCred) {
        try {
            $json = Get-Content $credPath -Raw | ConvertFrom-Json
            if ($json.blob) {
                [MultigravityCredVault]::ImportCredential($TARGET_CRED_NAME, $json.userName, $json.blob) | Out-Null
                Write-Host "Restored credential vault for profile '$PROFILE'"
            }
        } catch {
            Write-Host "Warning: Could not parse stored credential for profile '$PROFILE'"
        }
    } else {
        [MultigravityCredVault]::RemoveCredential($TARGET_CRED_NAME) | Out-Null
        Write-Host "Profile '$PROFILE' starting with fresh credential state (login required)."
    }

    return $hadSavedCred
}

function Restore-PostLaunchCredential {
    param($PROFILE, [bool]$HadSavedCred)
    $globalProfile = Get-GlobalProfile
    $isGlobal = ($globalProfile -and $globalProfile -eq $PROFILE)

    if ($isGlobal) {
        Save-GlobalCredential $PROFILE | Out-Null
    } else {
        if (!$HadSavedCred) {
            $user = $null
            $blob = [MultigravityCredVault]::ExportCredential($TARGET_CRED_NAME, [ref]$user)
            if ($blob) {
                $credPath = "$BASE\$PROFILE\.credentials.json"
                $data = @{
                    userName = $user
                    blob     = $blob
                    updated  = (Get-Date).ToString("o")
                } | ConvertTo-Json
                Set-Content -Path $credPath -Value $data -Encoding UTF8
                Write-Host "Saved new credential for profile '$PROFILE'"
            }
        }
        Restore-GlobalCredential
    }
}

function Test-SharedProfile {
    param($name)
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
        exit 1
    }
    if ($name -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-]*$") {
        Write-Error "Error: profile name must start with alphanumeric and contain only letters, numbers, or hyphens"
        exit 1
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
        } catch {}
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
                Write-Warning "Failed to link '$f' for shared profile '$name'. Shared profiles require Administrator privileges or Developer Mode on Windows."
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
    $authExclusions = @("state.vscdb", "state.vscdb.backup", "storage.json", "secrets.json")
    $items = Get-ChildItem -Path $sysGlobalStorage -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        if ($authExclusions -contains $item.Name) { continue }
        $destItem = "$profGlobalStorage\$($item.Name)"
        if ($item.PSIsContainer) {
            if (!(New-SharedDirJunction -src $item.FullName -dest $destItem)) {
                Write-Warning "Failed to create junction for '$($item.Name)' in shared profile '$name'."
            }
        } else {
            if (!(New-SharedFileLink -src $item.FullName -dest $destItem)) {
                Write-Warning "Failed to link '$($item.Name)' for shared profile '$name'. Shared profiles require Administrator privileges or Developer Mode on Windows."
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
        exit 1
    }

    $gProf = Get-GlobalProfile
    $isGlobal = ($gProf -and $gProf -eq $PROFILE)

    if ($isGlobal) {
        Write-Host "Launching Antigravity Desktop App for global profile '$PROFILE'"
        Restore-GlobalCredential
        try {
            $launchArgs = if ($ArgsToForward) {
                $ArgsToForward | Where-Object { $_ -ne "--global" -and $_ -ne "--save" -and $_ -ne "--remove_credentials" -and $_ -ne "--remove-credentials" -and $_ -ne "--remove-credential" }
            } else { @() }
            if ($launchArgs) {
                Start-Process -FilePath $APP -ArgumentList $launchArgs -Wait
            } else {
                Start-Process -FilePath $APP -Wait
            }
        } finally {
            Save-GlobalCredential $PROFILE | Out-Null
        }
        return
    }

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        exit 1
    }

    Write-Host "Launching Antigravity Desktop App for profile '$PROFILE'"
    
    if (Test-SharedProfile $PROFILE) {
        Sync-SharedProfile $PROFILE
    }

    $hadSavedCred = Prepare-LaunchCredential $PROFILE

    $oldUserProfile  = $env:USERPROFILE
    $oldAppData      = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA

    try {
        $env:USERPROFILE  = $PROFILE_DIR
        $env:APPDATA      = "$PROFILE_DIR\AppData\Roaming"
        $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"
        
        $userDataDir = "$PROFILE_DIR\AppData\Roaming\Antigravity"
        $extDir = "$PROFILE_DIR\.antigravity\extensions"

        $launchArgs = @(
            "--user-data-dir", $userDataDir,
            "--extensions-dir", $extDir,
            "--password-store=basic"
        )

        if ($ArgsToForward) {
            $launchArgs += ($ArgsToForward | Where-Object { $_ -ne "--global" -and $_ -ne "--save" -and $_ -ne "--remove_credentials" -and $_ -ne "--remove-credentials" -and $_ -ne "--remove-credential" })
        }

        Start-Process -FilePath $APP -ArgumentList $launchArgs -Wait
    } finally {
        $env:USERPROFILE  = $oldUserProfile
        $env:APPDATA      = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData

        Restore-PostLaunchCredential -PROFILE $PROFILE -HadSavedCred $hadSavedCred
    }
}

function Invoke-LaunchCLIProfile {
    param($PROFILE, $ArgsToForward)

    if (Process-ProfileCredentialFlags $PROFILE $ArgsToForward) {
        return
    }

    if ([string]::IsNullOrEmpty($CLI_APP) -or !(Test-Path $CLI_APP)) {
        Write-Error "Error: Antigravity CLI (agy) not found"
        exit 1
    }

    $gProf = Get-GlobalProfile
    $isGlobal = ($gProf -and $gProf -eq $PROFILE)

    if ($isGlobal) {
        Write-Host "Launching Antigravity CLI for global profile '$PROFILE'"
        Restore-GlobalCredential
        try {
            $cleanForwardArgs = if ($ArgsToForward) {
                $ArgsToForward | Where-Object { $_ -ne "--global" -and $_ -ne "--save" -and $_ -ne "--remove_credentials" -and $_ -ne "--remove-credentials" -and $_ -ne "--remove-credential" }
            } else { $null }

            if ($cleanForwardArgs) {
                & $CLI_APP @cleanForwardArgs
            } else {
                & $CLI_APP
            }
        } finally {
            Save-GlobalCredential $PROFILE | Out-Null
        }
        return
    }

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        exit 1
    }

    Write-Host "Launching Antigravity CLI for profile '$PROFILE'"
    
    if (Test-SharedProfile $PROFILE) {
        Sync-SharedProfile $PROFILE
    }

    $hadSavedCred = Prepare-LaunchCredential $PROFILE

    $oldUserProfile  = $env:USERPROFILE
    $oldAppData      = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA

    try {
        $env:USERPROFILE  = $PROFILE_DIR
        $env:APPDATA      = "$PROFILE_DIR\AppData\Roaming"
        $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"

        $cleanForwardArgs = if ($ArgsToForward) {
            $ArgsToForward | Where-Object { $_ -ne "--global" -and $_ -ne "--save" -and $_ -ne "--remove_credentials" -and $_ -ne "--remove-credentials" -and $_ -ne "--remove-credential" }
        } else { $null }

        if ($cleanForwardArgs) {
            & $CLI_APP @cleanForwardArgs
        } else {
            & $CLI_APP
        }
    } finally {
        $env:USERPROFILE  = $oldUserProfile
        $env:APPDATA      = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData

        Restore-PostLaunchCredential -PROFILE $PROFILE -HadSavedCred $hadSavedCred
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
        exit 1
    }

    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (Test-Path $profileDir) {
        Write-Error "Error: profile '$name' already exists"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $BASE | Out-Null

    if ($fromTpl) {
        $tplPath = "$(Get-TemplatesDir)\$fromTpl"
        if (!(Test-Path $tplPath)) {
            Write-Error "Error: template '$fromTpl' not found. Run: multigravity template list"
            exit 1
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
        exit 1
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
        exit 1
    }
    if (Test-Path $NEW_DIR) {
        Write-Error "Error: profile '$NEW' already exists"
        exit 1
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
        exit 1
    }
    if (Test-Path $DEST_DIR) {
        Write-Error "Error: destination profile '$DEST' already exists"
        exit 1
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
                Write-Host "  [OK] Shared Profile '$($sp.Name)': Extensions & settings synced"
            }
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
        exit 1
    }

    Write-Host "Updating multigravity from $script_url ..."
    try {
        $result = Invoke-WebRequest -Uri $script_url -UseBasicParsing -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($result.Content) -or $result.Content.Length -lt 500) {
            Write-Error "Error: downloaded update payload is invalid or empty"
            exit 1
        }
        [System.IO.File]::WriteAllText($target, $result.Content, [System.Text.Encoding]::UTF8)
        Write-Host "Successfully updated multigravity!"
    } catch {
        Write-Error "Error: failed to download update: $_"
        exit 1
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
                Write-Error "Error: usage: multigravity template save <profile> <name>"; exit 1
            }
            Validate-Name $a; Validate-Name $b
            $srcDir  = "$BASE\$a"
            $tplDir  = Get-TemplatesDir
            $tplPath = "$tplDir\$b"
            if (!(Test-Path $srcDir))  { Write-Error "Error: profile '$a' does not exist"; exit 1 }
            if (Test-Path $tplPath)    { Write-Error "Error: template '$b' already exists"; exit 1 }
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
            if ([string]::IsNullOrWhiteSpace($a)) { Write-Error "Error: template name required"; exit 1 }
            Validate-Name $a
            $tplPath = "$(Get-TemplatesDir)\$a"
            if (!(Test-Path $tplPath)) { Write-Error "Error: template '$a' does not exist"; exit 1 }
            Remove-Item -Recurse -Force $tplPath
            Write-Host "Deleted template '$a'"
        }
        default {
            Write-Error "Error: usage: multigravity template <save|list|delete>"; exit 1
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
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Error "Error: profile name required"; exit 1 }
    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (!(Test-Path $profileDir)) { Write-Error "Error: profile '$name' does not exist"; exit 1 }

    if ([string]::IsNullOrWhiteSpace($outPath)) { $outPath = ".\$name.zip" }

    Write-Host "Exporting '$name' to $outPath ..."
    Compress-Archive -Path $profileDir -DestinationPath $outPath -Force
    Write-Host "Done."
}

function Invoke-ImportProfile {
    param($archivePath, $name, [string[]]$extraArgs)

    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        Write-Error "Error: usage: multigravity import <archive.zip> [name]"; exit 1
    }
    if (!(Test-Path $archivePath)) {
        Write-Error "Error: file not found: $archivePath"; exit 1
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($archivePath)
    }
    Validate-Name $name

    $dest = "$BASE\$name"
    if (Test-Path $dest) {
        Write-Error "Error: profile '$name' already exists - choose a different name or delete it first"
        exit 1
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

switch ($cmd) {
    "new" {
        $extra = @()
        if ($arg2)       { $extra += $arg2 }
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-NewProfile $arg1 $extra
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
        $extra = @()
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-CloneProfile $arg1 $arg2 $extra
    }
    "template" {
        Invoke-TemplateCmd $arg1 $arg2 ($ForwardArgs | Select-Object -First 1)
    }
    "export" {
        Invoke-ExportProfile $arg1 $arg2
    }
    "import" {
        $extra = @()
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-ImportProfile $arg1 $arg2 $extra
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
        $extra = @()
        if ($arg2)       { $extra += $arg2 }
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-ShortcutsCmd $arg1 $extra
    }
    "shortcut" {
        $extra = @()
        if ($arg2)       { $extra += $arg2 }
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-ShortcutsCmd $arg1 $extra
    }
    "completion" {
        if ($arg1) {
            Invoke-GenerateCompletion $arg1
        } else {
            Invoke-HelpCompletion
        }
    }
    "app" {
        $AllArgs = @()
        if ($arg2)       { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchProfile $arg1 $AllArgs
    }
    "desktop" {
        $AllArgs = @()
        if ($arg2)       { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchProfile $arg1 $AllArgs
    }
    "cli" {
        $AllArgs = @()
        if ($arg2)       { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchCLIProfile $arg1 $AllArgs
    }
    "agy" {
        $AllArgs = @()
        if ($arg2)       { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchCLIProfile $arg1 $AllArgs
    }
    "help"   { Write-Usage }
    "--help" { Write-Usage }
    "-h"     { Write-Usage }
    "" {
        Write-Usage
        exit 1
    }
    default {
        $AllArgs = @()
        if ($arg1)       { $AllArgs += $arg1 }
        if ($arg2)       { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }

        if ($AllArgs -contains "--cli" -or $AllArgs -contains "--agy") {
            $filteredArgs = $AllArgs | Where-Object { $_ -ne "--cli" -and $_ -ne "--agy" }
            Invoke-LaunchCLIProfile $cmd $filteredArgs
        } else {
            Invoke-LaunchProfile $cmd $AllArgs
        }
    }
}
