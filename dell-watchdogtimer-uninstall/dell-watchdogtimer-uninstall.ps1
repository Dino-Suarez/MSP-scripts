$appName = 'Dell Watchdog Timer'
$allowForcedCleanup = $true
$workDir = "$($ENV:SystemDrive)\temp" # Where to export logs
$issFile = Join-Path $workDir 'DellWDT_uninstall.iss'
$isLog   = Join-Path $workDir 'DellWDT_uninstall_is.log'

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-WatchdogEntries {
    Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "$appName*" }
}

if ($false -eq (Test-Path $workDir)) {
    New-Item -ItemType Directory -Path $workDir | Out-Null
}

$entries = @(Get-WatchdogEntries)
if ($entries.Count -eq 0) {
    Write-Output "$appName is not installed. Nothing to do."
    exit 0
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

# Anything left? Fall back to manual cleanup.
$remaining = @(Get-WatchdogEntries)
if ($remaining.Count -gt 0 -and $allowForcedCleanup) {
    Write-Output "Silent uninstall did not remove the entry. Performing manual cleanup."

    Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -like '*WDTKernel.sys*' } |
        ForEach-Object {
            Write-Output "Removing driver service: $($_.Name)"
            Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
            & sc.exe delete $_.Name | Out-Null
        }

    $sys = "$env:SystemRoot\System32\drivers\WDTKernel.sys"
    if (Test-Path $sys) {
        Remove-Item $sys -Force -ErrorAction SilentlyContinue
        if (Test-Path $sys) { Write-Output "$sys is locked; it should clear after a reboot." }
        else { Write-Output "Removed $sys" }
    }

    foreach ($r in $remaining) {
        Remove-Item -Path $r.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed stale uninstall entry $($r.PSChildName)"
    }
}

# Final verification
$failed = $false
if (@(Get-WatchdogEntries).Count -gt 0) {
    Write-Output "$appName still appears in the installed programs list."
    $failed = $true
} else {
    Write-Output "$appName is no longer listed."
}

if (Test-Path "$env:SystemRoot\System32\drivers\WDTKernel.sys") {
    Write-Output "Note: WDTKernel.sys still exists (may clear after a reboot)."
} else {
    Write-Output "WDTKernel.sys is not present."
}

if ($failed) { exit 1 } else { exit 0 }