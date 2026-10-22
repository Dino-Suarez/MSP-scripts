$appName = 'Dell Watchdog Timer'
$allowForcedCleanup = $true
$workDir = "$($ENV:SystemDrive)\netxus\temp"
$issFile = Join-Path $workDir 'DellWDT_uninstall.iss'
$isLog   = Join-Path $workDir 'DellWDT_uninstall_is.log'
$driverFile = Join-Path $env:SystemRoot 'System32\drivers\WDTKernel.sys'

$script:rebootPending = $false

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# P/Invoke used to schedule deletion of a locked file at next boot
$moveFileExSig = @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@

function Get-WatchdogEntries {
    Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "$appName*" }
}

function Remove-WatchdogDriver {
    # 1. Find every driver service whose image path is WDTKernel.sys
    $names = @()
    $names += Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -like '*WDTKernel.sys*' } |
        Select-Object -ExpandProperty Name
    $names += Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath -like '*WDTKernel.sys*' } |
        Select-Object -ExpandProperty PSChildName
    $names = @($names | Where-Object { $_ } | Sort-Object -Unique)

    # 2. Disable, stop and delete each service
    foreach ($n in $names) {
        Write-Output "Found driver service: $n"
        & sc.exe config $n start= disabled | Out-Null   # make sure it can't load again after a reboot
        & sc.exe stop $n | Out-Null

        $q = ''
        for ($i = 0; $i -lt 10; $i++) {
            $q = & sc.exe query $n 2>&1 | Out-String
            if ($q -match 'STOPPED' -or $q -match '1060') { break }
            Start-Sleep -Seconds 1
        }
        if ($q -match 'RUNNING|STOP_PENDING') {
            Write-Output "Driver '$n' is still loaded and cannot be unloaded at runtime; a reboot is required."
            $script:rebootPending = $true
        }

        Write-Output "Removing driver service: $n"
        & sc.exe delete $n | Out-Null
    }

    # 3. Remove the file, or schedule removal at next boot if it is locked
    if (Test-Path -LiteralPath $driverFile) {
        Remove-Item -LiteralPath $driverFile -Force -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $driverFile) {
            Write-Output "$driverFile is locked. Scheduling deletion at next reboot."
            if (-not ('Win32.NativeMethods' -as [type])) {
                Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition $moveFileExSig
            }
            # MOVEFILE_DELAY_UNTIL_REBOOT = 0x4, null destination = delete
            if ([Win32.NativeMethods]::MoveFileEx($driverFile, $null, 4)) {
                $script:rebootPending = $true
            } else {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Output "Failed to schedule deletion (Win32 error $err)."
            }
        } else {
            Write-Output "Removed $driverFile"
        }
    }
}

if ($false -eq (Test-Path $workDir)) {
    New-Item -ItemType Directory -Path $workDir | Out-Null
}

$entries = @(Get-WatchdogEntries)
if ($entries.Count -eq 0) {
    Write-Output "$appName is not listed as installed. Skipping uninstall and checking for leftover driver."
}

foreach ($app in $entries) {
    Write-Output "Found: $($app.DisplayName) $($app.DisplayVersion) [$($app.PSChildName)]"

    # Pull the setup.exe path out of the UninstallString
    $setupExe = $null
    if ($app.UninstallString -match '^\s*"([^"]+\.exe)"') { $setupExe = $Matches[1] }
    elseif ($app.UninstallString -match '^\s*(\S+\.exe)') { $setupExe = $Matches[1] }

    if ($setupExe -and (Test-Path $setupExe) -and $app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
        $g = $app.PSChildName

        # Build the silent-uninstall response file
        $iss = @"
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwrittenReadOnly=NoToAll
[$g-DlgOrder]
Dlg0=$g-SdWelcomeMaint-0
Count=3
Dlg1=$g-MessageBox-0
Dlg2=$g-SdFinishReboot-0
[$g-SdWelcomeMaint-0]
Result=303
[$g-MessageBox-0]
Result=6
[Application]
Name=$appName
Version=$($app.DisplayVersion)
Company=Dell
Lang=0009
[$g-SdFinishReboot-0]
Result=1
BootOption=0
"@
        Set-Content -Path $issFile -Value $iss -Encoding ASCII
        Remove-Item $isLog -Force -ErrorAction SilentlyContinue

        Write-Output "Running InstallShield silent uninstall: $setupExe"
        $argList = "-runfromtemp -l0x0409 -removeonly -s -f1`"$issFile`" -f2`"$isLog`""
        $p = Start-Process -FilePath $setupExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
        Write-Output "setup.exe exit code: $($p.ExitCode)"

        # -runfromtemp can hand off to a child process, so wait for the entry to disappear
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline -and
               (@(Get-WatchdogEntries) | Where-Object { $_.PSChildName -eq $app.PSChildName })) {
            Start-Sleep -Seconds 3
        }

        if (Test-Path $isLog) {
            $rc = (Get-Content $isLog | Select-String '^ResultCode=').Line
            Write-Output "InstallShield log: $rc   (0 = success)"
        }
    }
    else {
        Write-Output "setup.exe not found at '$setupExe' (orphaned install)."
    }
}

# Anything left in the installed programs list? Remove the stale entries.
$remaining = @(Get-WatchdogEntries)
if ($remaining.Count -gt 0 -and $allowForcedCleanup) {
    Write-Output "Silent uninstall did not remove the entry. Performing manual cleanup."
    foreach ($r in $remaining) {
        Remove-Item -Path $r.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed stale uninstall entry $($r.PSChildName)"
    }
}

# Always check for the driver, whether or not the app was detected
if ($allowForcedCleanup) {
    Remove-WatchdogDriver
}

# Final verification
$failed = $false
if (@(Get-WatchdogEntries).Count -gt 0) {
    Write-Output "$appName still appears in the installed programs list."
    $failed = $true
} else {
    Write-Output "$appName is no longer listed."
}

if (Test-Path -LiteralPath $driverFile) {
    if ($script:rebootPending) {
        Write-Output "WDTKernel.sys is still on disk but is scheduled for deletion. REBOOT REQUIRED to complete removal."
    } else {
        Write-Output "WDTKernel.sys still exists and could not be removed or scheduled for removal."
        $failed = $true
    }
} else {
    Write-Output "WDTKernel.sys is not present."
}

if ($failed) { exit 1 } else { exit 0 }