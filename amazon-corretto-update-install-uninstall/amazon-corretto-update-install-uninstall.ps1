# Registry locations to check for installed software
$Global:X64_REGISTRY_LOCATION = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'
$Global:X86_REGISTRY_LOCATION = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\'

# Details for Amazon Corretto - https://docs.aws.amazon.com/corretto/latest/corretto-8-ug/windows-install.html
$Global:INSTALLED_CORRETTO_DISPLAY_NAME = 'Amazon Corretto'
$Global:CORRETTO_URL_FORMAT = "https://corretto.aws/downloads/latest/amazon-corretto-{0}-{1}-windows-{2}.msi"

# Details for C++ redistributables - Only required for Corretto 8 (1.8.x)
$Global:INSTALLED_CPP_REDIST_DISPLAY_NAME = "Microsoft Visual C\+\+ \d{4}(-\d{4})? Redistributable .*x\d{2}"
[System.version]$Global:CPP_MINIMUM_VERSION = '12.0.30501.0' # https://www.microsoft.com/en-us/download/details.aspx?id=40784
$Global:CPP_URL_FORMAT = "https://download.microsoft.com/download/c/c/2/cc2df5f8-4454-44b4-802d-5ea68d086676/vcredist_{0}.exe"

# Details for Java
$Global:INSTALLED_JAVA_DISPLAY_NAME = "^Java.+(Development)?.*\d+(Update)?.+\d+"

# Where to save downloaded files
$Global:SavePath = "$($ENV:SystemDrive)\Temp"

# Runtime preferences - these must be configured in the Datto component config
$RequestedAction = $env:Action              # Selection - Update/Install/Uninstall
$RequestedVersion = $env:Version            # Selection - 8/11/17/21/22/25/26
$RequestedArchitecture = $env:Architecture  # Selection - x64/x86/x64 and x86
$RequestedEdition = $env:Edition            # Selection - jdk/jre
$RequestedRemoveJava = $env:RemoveJava      # Boolean - $true/$false

Function Find-InstalledSoftware() {
    #Return installed instances of the search string on this PC
    param (
        $SearchString
    )
    try {
        #Check for software in both registry locations
        $Packages = Get-ItemProperty "$X64_REGISTRY_LOCATION*","$X86_REGISTRY_LOCATION*" |`
                            where-object -property displayname -Match $SearchString
    } catch {
        Write-host 'Failed to query the registry.'
        Write-host $_
        exit 1
    }

    # Iterate through instances of the software and report them for the admin's review
    if ($null -eq $Packages) {
        write-host 'Found no instances installed.'
    } else {
        # The data type is different depending on the number of items found
        if ($($Packages.getType().BaseType).tostring() -eq 'System.Object') {
            write-host 'Found one instance installed:'
        } elseif ($($Packages.getType().BaseType).tostring() -eq 'System.Array') {
            write-host "Found $($Packages.Count) instances installed:"
        }
        foreach ($Package in $Packages) {
            Write-host " - $($Package.displayname); version $($Package.displayversion)"
        }
    }

    # Return whatever was found
    return $Packages
}
Function New-SavePath {
    # Create the target save directory if it doesn't already exist
    if ( -not (Test-Path -Path $SavePath)) {
        try {
            New-Item -ItemType Directory -Path $SavePath | out-null
        } catch {
            write-host "Failed to create destination folder $SavePath."
            write-host $_
            exit 1
        }
        
    }
}
Function Install-CppRedistributable() {
    param (
        $arch
    )
    $CppDownloadURL = $CPP_URL_FORMAT -f $arch
    $CppArgs = '/install /quiet /norestart'
    New-SavePath

    $FileDestination = "$SavePath\vcredist_$arch.exe"

    if (Test-Path -Path $FileDestination) {
        remove-item $FileDestination
    }

    try {
        # Download the install package
        Write-host "Downloading C++ redistributable $arch..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12'
        Invoke-WebRequest -URI $CppDownloadURL -OutFile $FileDestination
    } catch {
        Write-host 'Failed to download the required C++ redistributable from microsoft.com.'
        write-host $_
        exit 1
    }

    try {
        write-host ' - Installing...'
        start-process -FilePath $FileDestination -ArgumentList $CppArgs -wait
        write-host ' - Package successfully installed.'
    } catch {
        Write-host 'Failed to install the required C++ redistributable.'
        write-host $_
        exit 1
    }
}
Function Uninstall-Software() {
    param (
        $name
    )

    $InstalledSoftware = Find-InstalledSoftware $name

    if ($null -eq $InstalledSoftware) {
        write-host 'No action needed.'
    } else {
        $UninstallFailure = $false
        foreach ($Instance in $InstalledSoftware) {
            try {
                write-host "Uninstalling $($Instance.displayname)..."
                start-process msiexec.exe -argumentlist "/quiet /norestart /x$($Instance.pschildname)" -wait
                write-host ' - Done.'
            } catch {
                write-host " - Failed to uninstall."
                $UninstallFailure = $true
            }
        }

        return $UninstallFailure
    }

    # Get installed version(s) once more to display updated list to the admin
    $InstalledSoftware = Find-InstalledSoftware $name
}
Function Install-Corretto() {
    param (
        $vers,
        $arch,
        $ed
    )
    $CorrettoDownloadURL = $CORRETTO_URL_FORMAT -f $vers,$arch,$ed
    $CorrettoArgs = '/qn /norestart'
    New-SavePath

    $FileDestination = "$SavePath\corretto_$($vers)_$($arch)_$($ed).msi"

    if (Test-Path -Path $FileDestination) {
        remove-item $FileDestination
    }

    try {
        # Download the install package
        Write-host "Downloading Amazon Corretto $vers $arch $($ed.ToUpper())..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12'
        Invoke-WebRequest -URI $CorrettoDownloadURL -OutFile $FileDestination
    } catch {
        Write-host 'Failed to download Amazon Corretto from corretto.aws.'
        write-host $_
        exit 1
    }

    try {
        write-host ' - Installing...'
        start-process -FilePath $FileDestination -ArgumentList $CorrettoArgs -wait
        write-host ' - Corretto successfully installed.'
    } catch {
        Write-host 'Failed to install Amazon Corretto.'
        write-host $_
        exit 1
    }
}

if ($RequestedRemoveJava -eq $true) {
    write-host 'Job configured to uninstall Java.'
    $FailureDetected = Uninstall-Software $INSTALLED_JAVA_DISPLAY_NAME
    if ($FailureDetected) {
        write-host 'Please remove Java manually.'
    }
}

if ($RequestedAction -eq 'Update') {
    write-host 'Job configured to update existing Amazon Corretto installs.'

    # Fetch the list of Corretto products installed
    $InstalledCorretto = Find-InstalledSoftware $INSTALLED_CORRETTO_DISPLAY_NAME

    if ($null -eq $InstalledCorretto) {
        write-host 'No action needed.'
    } else {
        # Determine the version, architecture, and edition for each instance
        foreach ($Instance in $InstalledCorretto) {
            if ($Instance.VersionMajor -eq 1) {
                $Version = '8'
            } else {
                $Version = $Instance.VersionMajor.tostring()
            }
            if (($Instance.displayname -match 'x86') -or ($Instance.PSParentPath -match 'Wow6432Node')) {
                $Architecture = 'x86'
            } else {
                $Architecture = 'x64'
            }
            if ($Instance.displayname -match 'JRE') {
                $Edition = 'JRE'
            } else {
                $Edition = 'JDK'
            }

            # Grab the latest package matching those parameters
            Install-Corretto $Version $Architecture $Edition
        }

        # Get installed version(s) once more to display updated list to the admin
        $InstalledCorretto = Find-InstalledSoftware $INSTALLED_CORRETTO_DISPLAY_NAME
    }
} elseif ($RequestedAction -eq 'Install') {
    # Verify we have all the information we need (we should if the Datto component was configured correctly)
    if (($null -eq $RequestedVersion) -or ($null -eq $RequestedArchitecture) -or ($null -eq $RequestedEdition)) {
        write-host 'Job configured to install Amazon Corretto, but not enough detail to proceed.'
        write-host 'Please provide target Corretto version, architecture, and edition next time.'
        exit 1
    }

    # Announce what was requested and verify it's valid (the JRE edition is only available for v8)
    write-host "Job configured to install Amazon Corretto $RequestedVersion $RequestedArchitecture $($RequestedEdition.ToUpper())."
    $Version = $RequestedVersion
    $Architecture = $RequestedArchitecture
    if (($RequestedVersion -ne '8') -and ($RequestedEdition -eq 'jre')) {
        write-host ' - JRE only valid for v8; installing JDK instead.'
        $Edition = 'jdk'
    } else {
        $Edition = $RequestedEdition
    }

    # If version 8 is requested, we'll need to determine whether we already have the required C++ distributable installed
    if ($Version -eq '8') {
        $CppPrerequisiteMet = $false

        write-host " - Version 8 requires minimum C++ redistributable version $CPP_MINIMUM_VERSION."
        $InstalledCpp = Find-InstalledSoftware $INSTALLED_CPP_REDIST_DISPLAY_NAME

        # If C++ redistributables are installed, check each one
        if ($InstalledCpp) {
            if (($Architecture -eq 'x86') -or ($Architecture -eq 'x64')) {
                foreach ($cpp in $InstalledCpp) {
                    if (($cpp.displayversion -ge $CPP_MINIMUM_VERSION) -and (($cpp.uninstallstring -match $Architecture) -or ($cpp.displayname -match $Architecture))) {
                        # We found a version greater or equal to the minimum version, matching the architecture requested
                        write-host 'C++ prerequisite already met.'
                        $CppPrerequisiteMet = $true
                        break
                    }
                }
            } else { # Both architectures were requested
                $x86PrerequisiteMet = $false
                $x64PrerequisiteMet = $false
                foreach ($cpp in $InstalledCpp) {
                    if (($cpp.displayversion -ge $CPP_MINIMUM_VERSION) -and (($cpp.uninstallstring -match 'x86') -or ($cpp.displayname -match 'x86'))) {
                        $x86PrerequisiteMet = $true
                    } elseif (($cpp.displayversion -ge $CPP_MINIMUM_VERSION) -and (($cpp.uninstallstring -match 'x64') -or ($cpp.displayname -match 'x64'))) {
                        $x64PrerequisiteMet = $true
                    }
                    if ($x86PrerequisiteMet -and $x64PrerequisiteMet) {
                        write-host 'C++ prerequisite already met.'
                        $CppPrerequisiteMet = $true
                        break
                    }
                }
            }
        }

        # If no sufficient C++ redistributable is installed, go get it
        if (-not $CppPrerequisiteMet) {
            if (($Architecture -eq 'x86') -or ($Architecture -eq 'x64')) {
                Install-CppRedistributable $Architecture
            } else { # Both architectures were requested
                if (-not $x86PrerequisiteMet) {Install-CppRedistributable 'x86'}
                if (-not $x64PrerequisiteMet) {Install-CppRedistributable 'x64'}
            }
        }
    }

    # We now have our prereqs sorted out, time to download/install Corretto
    if (($Architecture -eq 'x86') -or ($Architecture -eq 'x64')) {
        Install-Corretto $Version $Architecture $Edition
    } else { # Both architectures were requested
        Install-Corretto $Version 'x86' $Edition
        Install-Corretto $Version 'x64' $Edition
    }

    # Get installed version(s) once more to display updated list to the admin
    $InstalledCorretto = Find-InstalledSoftware $INSTALLED_CORRETTO_DISPLAY_NAME
} elseif ($RequestedAction -eq 'Uninstall') {
    write-host 'Job configured to uninstall Amazon Corretto.'
    $FailureDetected = Uninstall-Software $INSTALLED_CORRETTO_DISPLAY_NAME
    if ($FailureDetected) {exit 1}
}
