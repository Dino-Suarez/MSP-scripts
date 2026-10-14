# ---- Re-launch in 64-bit PowerShell if the agent started a 32-bit process ----
# (A 32-bit process would have C:\Windows\System32 silently redirected to SysWOW64,
#  which corrupts the ACL checks.)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePs = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if ((Test-Path -LiteralPath $sysnativePs) -and $PSCommandPath) {
        Write-Host 'Running in 32-bit PowerShell; relaunching in 64-bit.'
        & $sysnativePs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
    Write-Host 'WARNING: 32-bit PowerShell and could not relaunch; System32 paths may be redirected.'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------- Datto variable input
function Get-DattoVar {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}
function Get-DattoBool {
    param([string]$Name)
    return ((Get-DattoVar -Name $Name -Default 'false') -match '^(true|1|yes|y|on)$')
}

$Apply          = Get-DattoBool 'Apply'
$KeepDuplicates = Get-DattoBool 'KeepDuplicates'
$RemoveMissing  = Get-DattoBool 'RemoveMissing'

# ------------------------------------------------------------- CONFIGURATION
# Edit this value before deploying the component. Each run that writes changes
# creates a timestamped subfolder here containing one backup file per PATH value.
$BackupRoot      = "$($ENV:SystemDrive)\temp"
$BackupDirectory = Join-Path $BackupRoot ('PATH_Backup_{0:yyyyMMdd-HHmmss}' -f (Get-Date))

# ------------------------------------------------------------------ constants
$HKLM = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
$HKU  = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64')

$MachineSubKey  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$ProfileListKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$UserSidPattern = '^S-1-(5-21|12-1)-[\d-]+$'

$script:UsedBackupNames = @{}   # backup file names already used this run
$script:HiveCounter     = 0     # generates SID-free temporary hive mount names

$TrustedSids = @(
    'S-1-5-18'        # NT AUTHORITY\SYSTEM
    'S-1-5-32-544'    # BUILTIN\Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
    'S-1-3-0'         # CREATOR OWNER
)

$DangerousRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
    [System.Security.AccessControl.FileSystemRights]::AppendData -bor
    [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [System.Security.AccessControl.FileSystemRights]::Delete -bor
    [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [System.Security.AccessControl.FileSystemRights]::TakeOwnership

# ------------------------------------------------------------------- helpers
function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Expand-WithVars {
    # Expands %NAME% using $Vars first (target-user values), then the machine environment.
    param([string]$Text, [hashtable]$Vars)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $n = $m.Groups[1].Value
        if ($Vars.ContainsKey($n)) { $Vars[$n] } else { $m.Value }
    }.GetNewClosure()
    $step = [regex]::Replace($Text, '%([^%]+)%', $evaluator)
    [Environment]::ExpandEnvironmentVariables($step)
}

function Resolve-PathEntry {
    param([string]$Raw, [hashtable]$Vars)
    try {
        $expanded = Expand-WithVars -Text $Raw.Trim().Trim('"') -Vars $Vars
        if (-not [IO.Path]::IsPathRooted($expanded)) { return $null }
        $full = [IO.Path]::GetFullPath($expanded)
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        return $full
    } catch { return $null }
}

function Get-DirectoryRisk {
    param([string]$Directory)

    $result = [pscustomobject]@{
        Exists   = $false
        AclKnown = $false
        Writable = $false
        Reasons  = [System.Collections.Generic.List[string]]::new()
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $result }
    $result.Exists = $true

    try {
        $acl = Get-Acl -LiteralPath $Directory
        $result.AclKnown = $true
    } catch {
        $result.Reasons.Add("ACL unreadable: $($_.Exception.Message)")
        return $result
    }

    try {
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        if ($owner.Value -notin $TrustedSids) {
            $result.Writable = $true
            $result.Reasons.Add("Owner is untrusted: $(Get-PrincipalName $owner)")
        }
    } catch { }

    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        # InheritOnly ACEs apply to children only, not to the directory itself
        if ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($ace.IdentityReference.Value -in $TrustedSids) { continue }

        $hit = $ace.FileSystemRights -band $DangerousRights
        if ($hit) {
            $name = Get-PrincipalName $ace.IdentityReference
            $result.Writable = $true
            $result.Reasons.Add("$name : $hit")
        }
    }
    return $result
}

# NOTE: SIDs are used internally (registry keys, trust checks) but are never written to output.
function Get-PrincipalName {
    param([Security.Principal.SecurityIdentifier]$Sid)
    try { return $Sid.Translate([Security.Principal.NTAccount]).Value }
    catch { return '(unresolved account)' }
}

function Get-AccountLabel {
    param([string]$Sid, [string]$ProfilePath)
    try {
        return ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value
    } catch {
        if ($ProfilePath) { return "(unresolved account; profile folder '$(Split-Path -Path $ProfilePath -Leaf)')" }
        return '(unresolved account)'
    }
}

function Get-UserBackupName {
    # Backup file name derived from the profile folder (not the SID); unique within a run.
    param([string]$ProfilePath)
    $leaf = if ($ProfilePath) { Split-Path -Path $ProfilePath -Leaf } else { 'unknown' }
    $leaf = $leaf -replace '[^\w.\-]', '_'
    $name = "User-$leaf.txt"
    $n = 1
    while ($script:UsedBackupNames.ContainsKey($name.ToLowerInvariant())) { $n++; $name = "User-$leaf-$n.txt" }
    $script:UsedBackupNames[$name.ToLowerInvariant()] = $true
    return $name
}

function Get-ProfileMap {
    # SID -> profile directory, from the ProfileList registry key.
    $map = @{}
    $pl = $HKLM.OpenSubKey($ProfileListKey)
    if (-not $pl) { return $map }
    try {
        foreach ($sid in $pl.GetSubKeyNames()) {
            if ($sid -notmatch $UserSidPattern) { continue }
            $sk = $pl.OpenSubKey($sid)
            try {
                $p = $sk.GetValue('ProfileImagePath', $null)
                if ($p) { $map[$sid] = [Environment]::ExpandEnvironmentVariables($p) }
            } finally { $sk.Close() }
        }
    } finally { $pl.Close() }
    return $map
}

function Get-UserVars {
    param([string]$ProfilePath, [Microsoft.Win32.RegistryKey]$EnvKey)
    $v = @{}
    if ($ProfilePath) {
        $v['USERPROFILE']  = $ProfilePath
        $v['APPDATA']      = Join-Path $ProfilePath 'AppData\Roaming'
        $v['LOCALAPPDATA'] = Join-Path $ProfilePath 'AppData\Local'
        $v['TEMP']         = Join-Path $ProfilePath 'AppData\Local\Temp'
        $v['TMP']          = $v['TEMP']
        $v['HOMEDRIVE']    = Split-Path $ProfilePath -Qualifier
        $v['HOMEPATH']     = $ProfilePath.Substring($v['HOMEDRIVE'].Length)
    }
    foreach ($name in $EnvKey.GetValueNames()) {
        if ($name -ieq 'Path' -or -not $name) { continue }
        $kind = $EnvKey.GetValueKind($name)
        if ($kind -in 'String', 'ExpandString') {
            $v[$name] = [string]$EnvKey.GetValue($name, '', 'DoNotExpandEnvironmentNames')
        }
    }
    return $v
}

function Send-EnvironmentChange {
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $r = [UIntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero,
        'Environment', 0x2, 5000, [ref]$r)
}

function Mount-UserHive {
    param([string]$Label, [string]$ProfilePath)
    $hive = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) { return $null }
    $script:HiveCounter++
    $name = "PathAudit_$($script:HiveCounter)"
    $null = & reg.exe load "HKU\$name" $hive 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: could not load hive for $Label ($hive); skipping."
        return $null
    }
    return $name
}

function Dismount-UserHive {
    param([string]$Name)
    for ($i = 0; $i -lt 5; $i++) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $null = & reg.exe unload "HKU\$Name" 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    Write-Host "WARNING: failed to unload HKU\$Name. Run 'reg unload HKU\$Name' manually."
}

# ----------------------------------------------------- per-target processing
function Invoke-PathOptimization {
    param(
        [string]$Label,
        [Microsoft.Win32.RegistryKey]$Root,
        [string]$SubKey,
        [string]$BackupName,
        [string]$ProfilePath,     # $null for the machine PATH
        [switch]$IsUser           # user PATH: suppress detail output when nothing changes
    )

    $summary = [pscustomobject]@{ Target = $Label; Entries = 0; Status = 'No change' }

    try { $key = $Root.OpenSubKey($SubKey, $Apply) }
    catch { $summary.Status = "Error: $($_.Exception.Message)"; return $summary }
    if (-not $key) { $summary.Status = 'No Environment key'; return $summary }

    try {
        if ($key.GetValueNames() -inotcontains 'Path') {
            Write-Host "`n=== $Label ===`nNo Path value; skipped."
            $summary.Status = 'No Path value'
            return $summary
        }

        $originalRaw = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $valueKind   = $key.GetValueKind('Path')
        $vars        = if ($ProfilePath) { Get-UserVars -ProfilePath $ProfilePath -EnvKey $key } else { @{} }

        $entries = @($originalRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $summary.Entries = $entries.Count
        Write-Host "`n=== $Label  ($($entries.Count) entries) ==="
        if ($entries.Count -eq 0) { $summary.Status = 'Empty'; return $summary }

        $sysRoot = Resolve-PathEntry '%SystemRoot%' @{}
        $seen  = @{}
        $items = [System.Collections.Generic.List[object]]::new()
        $index = 0

        foreach ($raw in $entries) {
            $resolved = Resolve-PathEntry -Raw $raw -Vars $vars
            $dupe = $false
            if ($resolved) {
                $k = $resolved.ToLowerInvariant()
                if ($seen.ContainsKey($k)) { $dupe = $true } else { $seen[$k] = $true }
            }

            if ($dupe -and -not $KeepDuplicates) {
                $items.Add([pscustomobject]@{ Index = $index++; Raw = $raw; Tier = -1
                    Status = 'DUPLICATE (removed)'; Reasons = '' })
                continue
            }

            $removable = $false

            if (-not $resolved) {
                $tier = 2; $status = 'UNRESOLVABLE'; $reasons = 'Could not normalize path'
            } else {
                $risk = Get-DirectoryRisk -Directory $resolved
                $reasons = ($risk.Reasons -join '; ')
                if (-not $risk.Exists) {
                    $tier = 2
                    # Only call it definitively missing for a local path on a volume that is present.
                    # UNC paths and absent drive letters (e.g. a user's mapped drive, invisible to
                    # SYSTEM) cannot be verified, so they are never removed.
                    $volRoot = [IO.Path]::GetPathRoot($resolved)   # not $root: collides with the [RegistryKey]$Root parameter
                    if ($resolved -notmatch '^\\\\' -and $volRoot -and (Test-Path -LiteralPath $volRoot)) {
                        $status = 'MISSING'; $removable = $true
                    } else {
                        $status = 'MISSING (unverifiable)'
                        $reasons = 'Network path or unavailable volume; kept'
                    }
                }
                elseif (-not $risk.AclKnown) { $tier = 2; $status = 'ACL-UNREADABLE' }
                elseif ($risk.Writable)      { $tier = 3; $status = 'USER-WRITABLE' }
                elseif ($resolved -eq $sysRoot -or $resolved.StartsWith($sysRoot + '\', 'OrdinalIgnoreCase')) {
                    $tier = 0; $status = 'SYSTEM'
                }
                else                         { $tier = 1; $status = 'PROTECTED' }
            }
            if ($RemoveMissing -and $removable) {
                $tier = -1; $status = 'MISSING (removed)'
            }
            $items.Add([pscustomobject]@{ Index = $index++; Raw = $raw; Tier = $tier
                Status = $status; Reasons = $reasons })
        }

        $sorted  = @($items | Where-Object { $_.Tier -ge 0 } | Sort-Object Tier, Index)
        $newPath = ($sorted | ForEach-Object { $_.Raw }) -join ';'
        $changed = -not ($newPath -ceq ($entries -join ';'))

        # User PATH that needs no change: the one-line statement is all that is shown.
        if ($IsUser -and -not $changed) {
            Write-Host 'Already in a secure order.'
            return $summary
        }

        # Plain Write-Host lines (no Format-Table) so the RMM console never truncates columns.
        Write-Host 'Analysis (original order):'
        foreach ($i in $items) {
            $t = if ($i.Tier -ge 0) { "T$($i.Tier)" } else { '--' }
            $line = '  {0,3}. [{1}] {2,-22} {3}' -f ($i.Index + 1), $t, $i.Status, $i.Raw
            if ($i.Reasons) { $line += "   <- $($i.Reasons)" }
            Write-Host $line
        }

        Write-Host 'Proposed order:'
        $n = 1
        foreach ($s in $sorted) { Write-Host ('  {0,3}. [T{1}] {2}' -f $n++, $s.Tier, $s.Raw) }

        # Never write an empty PATH.
        if ($sorted.Count -eq 0) {
            Write-Host 'WARNING: every entry would be removed; leaving this PATH unchanged.'
            $summary.Status = 'Skipped (would empty PATH)'
            return $summary
        }

        if ($newPath.Length -gt 2047) {
            Write-Host "WARNING: new PATH for '$Label' is $($newPath.Length) chars; some legacy software truncates at 2047."
        }
        if (-not $changed) {
            Write-Host 'Already in a secure order.'
            return $summary
        }

        if (-not $Apply) {
            Write-Host 'DRY RUN: this PATH would be reordered.'
            $summary.Status = 'Would change (dry run)'
            return $summary
        }

        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        $backupFile = Join-Path $BackupDirectory $BackupName
        Set-Content -LiteralPath $backupFile -Value $originalRaw -Encoding UTF8
        Write-Host "Backup saved: $backupFile"

        $key.SetValue('Path', $newPath, $valueKind)   # preserves value type and %VARS%
        Write-Host 'PATH updated.'
        $summary.Status = 'UPDATED'
        return $summary
    }
    catch {
        Write-Host "ERROR on '$Label': $($_.Exception.Message)"
        $summary.Status = "Error: $($_.Exception.Message)"
        return $summary
    }
    finally { $key.Close() }
}

# ----------------------------------------------------------------------- main
try {
    Write-Host "Host: $env:COMPUTERNAME   Mode: $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
    Write-Host "KeepDuplicates=$KeepDuplicates  RemoveMissing=$RemoveMissing"
    if ($Apply) { Write-Host "Backups: $BackupDirectory" }

    $elevated = Test-IsElevated
    if (-not $elevated) {
        Write-Host 'ERROR: component must run elevated (Datto normally runs as SYSTEM).'
        exit 1
    }

    $results = [System.Collections.Generic.List[object]]::new()

    # Machine PATH
    $results.Add((Invoke-PathOptimization -Label 'Machine PATH' -Root $HKLM `
        -SubKey $MachineSubKey -BackupName 'Machine.txt' -ProfilePath $null))

    $profiles  = Get-ProfileMap
    $loaded    = @($HKU.GetSubKeyNames())
    $loadedSid = @($loaded | Where-Object { $_ -match $UserSidPattern })

    # 1) Loaded hives (currently logged-on users)
    foreach ($sid in $loadedSid) {
        $pp = if ($profiles.ContainsKey($sid)) { $profiles[$sid] } else { $null }
        $label = Get-AccountLabel -Sid $sid -ProfilePath $pp
        $results.Add((Invoke-PathOptimization -Label "User PATH: $label [loaded]" `
            -Root $HKU -SubKey "$sid\Environment" -BackupName (Get-UserBackupName -ProfilePath $pp) `
            -ProfilePath $pp -IsUser))
    }

    # 2) .DEFAULT (SYSTEM account environment); reported only if it has a Path value
    if ($loaded -contains '.DEFAULT') {
        $sysProfile = Join-Path $env:SystemRoot 'System32\config\systemprofile'
        $results.Add((Invoke-PathOptimization -Label 'User PATH: .DEFAULT (SYSTEM account)' `
            -Root $HKU -SubKey '.DEFAULT\Environment' -BackupName (Get-UserBackupName -ProfilePath $sysProfile) `
            -ProfilePath $sysProfile -IsUser))
    }

    # 3) Offline profiles: mount NTUSER.DAT temporarily, then always unload
    foreach ($sid in ($profiles.Keys | Where-Object { $_ -notin $loadedSid } | Sort-Object)) {
        $label = Get-AccountLabel -Sid $sid -ProfilePath $profiles[$sid]
        $mount = Mount-UserHive -Label $label -ProfilePath $profiles[$sid]
        if (-not $mount) { continue }
        try {
            $results.Add((Invoke-PathOptimization -Label "User PATH: $label [offline]" `
                -Root $HKU -SubKey "$mount\Environment" `
                -BackupName (Get-UserBackupName -ProfilePath $profiles[$sid]) `
                -ProfilePath $profiles[$sid] -IsUser))
        } finally {
            Dismount-UserHive -Name $mount
        }
    }

    # ------------------------------------------------------------ summary
    Write-Host "`n=== Summary ==="
    foreach ($r in $results) {
        Write-Host ('  {0,-70} {1,3} entries  {2}' -f $r.Target, $r.Entries, $r.Status)
    }

    $updated = @($results | Where-Object { $_.Status -eq 'UPDATED' }).Count
    $pending = @($results | Where-Object { $_.Status -like 'Would change*' }).Count
    $errors  = @($results | Where-Object { $_.Status -like 'Error*' }).Count

    if ($updated -gt 0) {
        Send-EnvironmentChange
        Write-Host 'Environment change broadcast. Logged-on users must sign out/in for user PATH changes.'
    }
    if (-not $Apply -and $pending -gt 0) {
        Write-Host "Dry run only: $pending PATH value(s) would change. Set Apply=true to write."
    }

    if ($errors -gt 0) { Write-Host "$errors target(s) reported errors."; exit 1 }
    exit 0
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}