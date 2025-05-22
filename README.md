Keeper Credential Ownership Transfer PowerShell Script
Version: 2.24 (as per the script this README is based on)

Overview
This PowerShell script automates the process of transferring ownership of all credentials within specified Keeper Shared Folders or those accessible via Keeper Teams to a designated Keeper user. It is designed for administrators who need to manage credential ownership in bulk, for instance, during employee off-boarding or role changes.

The script supports:

Interactive Mode: For on-demand use with guided prompts.

Automated Mode: Using a JSON configuration file, suitable for scheduled tasks.

Multi-selection: Allows targeting multiple Teams or multiple Shared Folders in a single interactive session.

Flexible Configuration: Different run modes for automated tasks, including dynamic discovery of a team's shared folders or processing predefined lists.

Recursive Control: Option to control whether ownership transfer is recursive to sub-folders and their records.

Prerequisites
PowerShell: Version 5.1 or higher.

Keeper Commander CLI:

keeper-commander.exe must be installed.

The script attempts to locate it via Get-Command. Ensure it's in your system's PATH or provide the full path if necessary by modifying the $Global:KeeperExecutablePath variable at the beginning of the script.

Keeper Account Permissions: The Keeper user account executing the script (or whose session is active) requires:

Administrative rights or "Share Admin" privileges to list teams and shared folders.

Permissions to view details (including user/team permissions) of shared folders.

The ability to transfer ownership of records.

Authenticated Keeper Session (for interactive use):

Before running interactively, log in to Keeper Commander in the same PowerShell window:

Open PowerShell.

Run keeper-commander.exe shell.

Log in with your master password and 2FA.

Type exit to leave the Keeper shell (the session remains active for that window).

Then, run this script.

The script includes a basic login check using keeper-commander.exe whoami.

Persistent Login for Scheduled Tasks: For automated/scheduled runs, Keeper Commander must be configured for non-interactive login. See "Persistent Login for Automation" section below.

Graphical Environment (Optional for Interactive Mode):

Out-GridView is used for GUI-based item selection. If not available (e.g., headless server, PowerShell Core without GUI modules), the script gracefully falls back to a console-based menu.

Features
Interactive & Automated Modes: Flexible execution options.

Log Detail Control: Choose between "Normal" and "Verbose" logging in interactive mode.

Login Verification: Basic check for an active Keeper Commander session in interactive mode.

Multi-Team & Multi-Shared Folder Selection: Select multiple targets in one interactive session.

New Owner Email Validation:

Syntactic check using .NET MailAddress class.

Attempt to verify user existence in Keeper via user-info --email.

Recursive Transfer Control:

-NoRecursive command-line switch.

NoRecursive: $true/$false option in the configuration file.

Interactive prompt to choose recursive behavior.

Configuration File Management:

Save parameters from an interactive run to a JSON file.

Supports RunMode:

Teams: Dynamically discovers folders for specified teams each run.

SharedFolders: Processes a predefined list of shared folders.

ProcessSpecificFoldersForTeams: Processes a saved list of folders previously identified for specific teams.

Includes ScriptConfigVersion in the config for compatibility awareness.

Error Handling: Reports Keeper CLI errors and tracks failed transfer actions, exiting with specific codes.

Progress Indicators: Write-Progress used for potentially long operations like folder scanning and bulk transfers.

Performance: When processing teams, shared folder details are fetched once and cached for the duration of that script run to reduce redundant API calls.

Script Parameters
.\keeper_ownership_transfer.ps1
    [-RunAutomated]
    [-ConfigFilePath <String>]
    [-NoRecursive]
    [-WhatIf]
    [-Confirm]
    [-Verbose]

-RunAutomated: (Switch) If present, the script runs non-interactively and requires -ConfigFilePath.

-ConfigFilePath <String>: (String) Full path to the JSON configuration file. Mandatory if -RunAutomated is used.

-NoRecursive: (Switch) If present, ownership transfer will NOT be recursive (omits --recursive from share-record command). Defaults to recursive.

-WhatIf: (Switch) Shows what actions would be taken without actually performing them.

-Confirm: (Switch) Prompts for confirmation before performing actions that change data.

-Verbose: (Switch) Overrides the script's internal log level selection and enables detailed verbose output.

How to Use
1. Interactive Mode
Login to Keeper: Open PowerShell, run keeper-commander.exe shell, log in, then exit the shell.

Run Script: In the same PowerShell window:

.\keeper_ownership_transfer.ps1

(Or use the full path to the script).

Follow Prompts:

Select log detail level.

Confirm login status.

Choose "Teams" or "Shared Folders".

Select target item(s) from the GUI or console menu.

Enter the new owner's email.

Choose recursive behavior.

Optionally save parameters to a JSON config file.

Confirm the transfer operation.

Review & Verify: Check script output and verify changes in your Keeper Vault.

2. Automated Mode (for Scheduled Tasks)
Generate Configuration File:

Run the script interactively once.

When prompted, save the parameters to a .json file (e.g., C:\Scripts\KeeperTransferConfig_TeamX.json).

Choose the desired "Save Team Configuration As" mode if you selected teams.

Set up Windows Task Scheduler:

Program/script: powershell.exe

Add arguments (optional):

-ExecutionPolicy Bypass -File "C:\Path\To\Your\keeper_ownership_transfer.ps1" -RunAutomated -ConfigFilePath "C:\Path\To\Your\Config.json"

(Optionally add -NoRecursive if needed).

Run As: Use a dedicated service account for which Keeper Commander persistent login is configured (see below).

Monitor: Check Task Scheduler history and script logs (if implemented separately).

Configuration File Example (keeper_transfer_config.json)
{
  "NewOwnerEmail": "new.owner@example.com",
  "LogDetail": "SilentlyContinue",
  "ScriptConfigVersion": "2.24",
  "NoRecursive": false,
  "SelectedTeams": [
    {
      "Name": "Sales Team",
      "UID": "teamUID1_xxxxxxxxxxxx"
    }
  ],
  "RunMode": "Teams"
}

Or for specific folders:

{
  "NewOwnerEmail": "new.owner@example.com",
  "LogDetail": "Verbose",
  "ScriptConfigVersion": "2.24",
  "NoRecursive": true,
  "SelectedSharedFolders": [
    {
      "Name": "Project Alpha Folder",
      "UID": "sfUID_alpha_xxxxxxxx"
    },
    {
      "Name": "Archived Projects",
      "UID": "sfUID_archive_xxxxxx"
    }
  ],
  "RunMode": "SharedFolders" 
}

Persistent Login for Automation
For scheduled/automated runs, Keeper Commander needs to authenticate non-interactively. The script offers to display this information at the end of an interactive session. Key methods:

Device Approval (Recommended):

Log in interactively once as the user account the task will run under (keeper-commander.exe shell).

Approve the device via Keeper's 2FA mechanism. This allows non-interactive commands for an extended period.

config.json with 2FA Seed (TOTP):

If the Keeper account uses TOTP 2FA, during an interactive keeper-commander.exe shell login, when prompted for the 2FA code, type setup.

This stores the 2FA secret seed in Commander's config.json (typically C:\Users\<User>\.keeper\config.json). Commander can then generate its own codes.

Secure this config.json file with strict file system permissions.

Session Resumption:

An interactive login via shell usually stores session tokens in config.json, which subsequent commands can use until expiry.

Security Note: Avoid storing your master password directly. Prioritize Device Approval and 2FA Seed methods.

Error Handling
The script tracks failures during ownership transfer actions ($Global:transferActionFailures).

Exits with code 0 on full success.

Exits with code 2 if one or more transfer actions failed.

May exit with other non-zero codes if critical Keeper CLI commands fail during data gathering.

Always review script output and verify changes in Keeper.

Known Limitations / Performance
Text Parsing: If Keeper Commander fails to return JSON for list commands (enterprise-info --teams, lsf), the script falls back to text parsing, which can be less reliable if the CLI output format changes.

Team Folder Discovery: When RunMode is "Teams", the script fetches a list of all shared folders and then gets details for each one individually (folder-info <UID>) to check team permissions. This is done once per run and details are cached in memory for that run. However, in environments with thousands of shared folders, this initial data gathering can be time-consuming.

Batch folder-info: The script currently calls folder-info for each shared folder individually when building the cache for team processing, as batching multiple UIDs with folder-info (like folder-info UID1 UID2...) is not a universally supported feature across all Keeper Commander versions for returning a single JSON array.

Contributing
Feel free to fork this repository, make improvements, and submit pull requests.

License
Specify your preferred license here (e.g., MIT, Apache 2.0). If unsure, MIT is a common permissive license.
