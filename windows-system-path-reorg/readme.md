# Windows PATH hardening
Reads the raw PATH from the registry, checks the NTFS ACL of each entry, and reorders so that system-critical directories come before user-writable ones. Always processes the machine PATH, every loaded user hive, .DEFAULT, and every offline user profile (NTUSER.DAT is mounted temporarily, then unloaded).

# Datto RMM
This script was written for Datto RMM. Configure the below 'variables' in the component config so your technicians can determine behavior at runtime. These are all Boolean type:
- Apply
    - false = report only (dry run); recommended default value
    - true  = back up and write registry
- KeepDuplicates
    - false = remove duplicate entries
    - true  = do not remove duplicate entries; recommended default value
- RemoveMissing
    - false = do not remove entries that do not exist on disk
    - true  = remove entries whose directory does not exist on disk; recommended default value. See safeguards below
If you're not using Datto RMM, replace the `Get-DattoBool` function calls on lines 29-31 with the values that define the behavior you want.

# RemoveMissing safeguards
Only entries that are definitively absent are removed: the path must be a local drive path whose volume is present. UNC paths and drive letters that do not exist for the SYSTEM account (e.g. a user's mapped network drive) are reported as "unverifiable" and kept. Unresolvable entries (relative paths, bad variables) are also kept. If removal would leave a PATH completely empty, that PATH is left unchanged.

# Backup location
Edit `$BackupRoot` on line 36 to set the location. A timestamped subfolder is created under it for each run that writes changes.

# Tiers
- 0  Protected directories under %SystemRoot%
- 1  Other protected directories (Program Files, etc.)
- 2  Missing, unresolvable, or unreadable-ACL entries
- 3  Directories writable by non-admin principals (or owned by one)
Original order is preserved within each tier.

# Exit codes
- 0  Completed (including dry run) with no errors
- 1  Fatal error, or at least one target failed

# Other notes
- Deny ACEs are not evaluated; access is approximated from Allow ACEs
- A user PATH needing no change prints just "Already in a secure order;" The machine PATH always prints the full analysis
- Logged-on users will see a changed user PATH after their next login
- Per-user %VARIABLES% are expanded with the TARGET user's values