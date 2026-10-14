# Dell Watchdog Timer Uninstall
This script will try to uninstall WDT via InstallShield using details found in the registry. If that fails, it will manually rip out the service, driver, and registry entry. Then it verifies whether any artifacts are left behind, as the .sys file is what the Tenable plugin alerts on.

Update `$workDir` on line 3 to configure where you want to create your *DellWDT_uninstall.iss* and *DellWDT_uninstall_is.log* files.

This script was written for Datto RMM but there are no 'variables' to configure in the component config. Just paste it in and let 'er rip.