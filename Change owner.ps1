#requires -Version 5.1
<#
.SYNOPSIS
    Manages ownership of credentials shared via Keeper teams or shared folders.
    Supports interactive and automated (scheduled) runs via a config file,
    including multi-team/multi-folder selection and different automation modes.
    Includes interactive log level selection and login check/guidance.
.DESCRIPTION
    Allows interactive selection of one or more Teams, or one or more Shared Folders.
    Alternatively, can run in an automated mode using a configuration file.
    The config file supports different run modes:
    - "Teams": Dynamically discovers shared folders for the configured team(s) on each run.
    - "SharedFolders": Processes a specific pre-configured list of shared folders.
    - "ProcessSpecificFoldersForTeams": Processes a pre-configured list of shared folders
      that were previously identified for specific teams.

    IMPORTANT: 
    1. If an active Keeper session is not detected, the script launches the Keeper shell so you can log in and then continue.
    2. This script attempts to use JSON output (--format json) from Keeper CLI commands.
       If JSON fails, it falls back to text parsing which can be fragile.
    3. Out-GridView requires a graphical environment (WPF). If not available, the script
       will fall back to a console-based menu for interactive selections.
    4. The process of identifying shared folders for teams involves fetching details for each
       shared folder in the vault, which can be time-consuming in large environments.
.NOTES
    Author: AI Assistant (Incorporating User Audit Feedback)
    Version: 2.25 (interactive login shell and persistent login option)
    Prerequisites: Keeper Commander CLI (keeper-commander.exe) installed, configured, and logged in.
                   Appropriate Keeper administrative/Share Admin permissions.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param (
    [Switch]$RunAutomated,

    [string]$ConfigFilePath,

    [Switch]$NoRecursive
)

Set-StrictMode -Version Latest

# --- Initial Parameter Validation & Global Setup ---
if ($RunAutomated -and ([string]::IsNullOrWhiteSpace($ConfigFilePath))) {
    Write-Error "-ConfigFilePath is mandatory when -RunAutomated is specified. Please provide a valid path."
    Exit 1
}

$Global:KeeperExecutablePath = $null
try {
    $Global:KeeperExecutablePath = (Get-Command keeper-commander.exe -ErrorAction Stop).Source
    Write-Verbose "Using Keeper Commander executable at: $($Global:KeeperExecutablePath)"
}
catch {
    Write-Error "keeper-commander.exe not found in PATH. Please ensure Keeper Commander CLI is installed and accessible."
    Exit 1
}

$originalVerbosePreference = $VerbosePreference
$VerbosePreference = if ($RunAutomated) { "SilentlyContinue" } else { $originalVerbosePreference }
$useRecursive = $true
if ($NoRecursive) { $useRecursive = $false }
$Global:transferActionFailures = 0
$scriptConfigFileVersion = "2.25"

# --- Helper Functions ---
Function Invoke-KeeperCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandArguments, 
        [Parameter(Mandatory = $false)]
        [bool]$AttemptJson = $true
    )
    try {
        $argumentsToExecute = $CommandArguments
        if ($AttemptJson -and $CommandArguments -notmatch '--format\s+json') {
            if ($CommandArguments -match '^\s*folder-info\s+([a-zA-Z0-9_-]{22}(\s+[a-zA-Z0-9_-]{22})*)') { 
                $verb = "folder-info"
                $uidsAndOtherArgs = $CommandArguments.Substring($verb.Length).TrimStart()
                $argumentsToExecute = "$verb --format json $uidsAndOtherArgs"
            } elseif ($CommandArguments -match '^\s*get\s+([a-zA-Z0-9_-]{22}(\s+[a-zA-Z0-9_-]{22})*)') { 
                 $verb = "get"
                 $uidsAndOtherArgs = $CommandArguments.Substring($verb.Length).TrimStart()
                 $argumentsToExecute = "$verb --format json $uidsAndOtherArgs"
            } else {
                $argumentsToExecute = "$CommandArguments --format json"
            }
        }
        
        Write-Verbose "Executing Keeper Command: $($Global:KeeperExecutablePath) $argumentsToExecute"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $Global:KeeperExecutablePath
        $processInfo.Arguments = $argumentsToExecute
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null
        
        $outputLinesList = New-Object System.Collections.Generic.List[string]
        while (-not $process.StandardOutput.EndOfStream) {
            $outputLinesList.Add($process.StandardOutput.ReadLine())
        }
        $errorOutput = $process.StandardError.ReadToEnd()
        
        $process.WaitForExit()
        $Global:KeeperCliExitCode = $process.ExitCode 
        if ($Global:KeeperCliExitCode -ne 0 -and $errorOutput -match "argument --format: expected one argument" -and $AttemptJson) {
            Write-Verbose "Retrying with --format=json syntax"
            $argumentsToExecute = $argumentsToExecute -replace "--format json", "--format=json"
            $outputLinesList = New-Object System.Collections.Generic.List[string]
            $processInfo.Arguments = $argumentsToExecute
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $process.Start() | Out-Null
            while (-not $process.StandardOutput.EndOfStream) { $outputLinesList.Add($process.StandardOutput.ReadLine()) }
            $errorOutput = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $Global:KeeperCliExitCode = $process.ExitCode
        }
        
        $outputLinesArray = $outputLinesList.ToArray()
        $rawOutputString = $outputLinesArray -join [Environment]::NewLine
        Write-Verbose "Raw output string from '$($Global:KeeperExecutablePath) $argumentsToExecute':`n$rawOutputString" 

        if ($errorOutput) {
            Write-Warning "Keeper command STDERR for '$($Global:KeeperExecutablePath) $argumentsToExecute':`n$errorOutput"
        }

        if ($Global:KeeperCliExitCode -ne 0) {
            Write-Error "Keeper command failed: $($Global:KeeperExecutablePath) $argumentsToExecute`nError code: $($Global:KeeperCliExitCode)`nOutput: $rawOutputString`nErrorStream: $errorOutput"
            return $null 
        }

        if ([string]::IsNullOrWhiteSpace($rawOutputString)) {
            Write-Verbose "Command '$($Global:KeeperExecutablePath) $argumentsToExecute' returned empty output."
            return [System.Collections.ArrayList]::new() 
        }

        if ($AttemptJson) {
            try {
                return ($rawOutputString | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                Write-Warning "Failed to parse output as JSON for command: $($Global:KeeperExecutablePath) $argumentsToExecute. Error: $($_.Exception.Message). Returning raw text lines."
                return $outputLinesArray 
            }
        } else {
            return $outputLinesArray 
        }
    }
    catch {
        Write-Error "Generic failure in Invoke-KeeperCommand for: $($Global:KeeperExecutablePath) $argumentsToExecute`n$($_.Exception.Message)"
        $Global:KeeperCliExitCode = -1 
        return $null
    }
}

Function Invoke-KeeperActionCommand {
    [CmdletBinding(SupportsShouldProcess=$true)] 
    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandArguments 
    )
    try {
        Write-Verbose "Executing Keeper Action Command: $($Global:KeeperExecutablePath) $CommandArguments"
        
        if ($PSCmdlet.ShouldProcess("Keeper target (via command: $CommandArguments)", "Execute ownership transfer")) {
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $Global:KeeperExecutablePath
            $processInfo.Arguments = $CommandArguments
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $process.Start() | Out-Null
            
            $output = $process.StandardOutput.ReadToEnd()
            $errorOutput = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $exitCode = $process.ExitCode

            Write-Verbose "Action command STDOUT: $output"
            if ($errorOutput) {
                Write-Warning "Action command STDERR for '$($Global:KeeperExecutablePath) $CommandArguments':`n$errorOutput"
            }

            if ($exitCode -ne 0) {
                Write-Error "Keeper action command failed: $($Global:KeeperExecutablePath) $CommandArguments`nError code: $exitCode`nSTDOUT: $output`nSTDERR: $errorOutput"
                return $false 
            }
            Write-Host "Keeper action command successful: $($Global:KeeperExecutablePath) $CommandArguments" -ForegroundColor Green
            return $true 
        } else {
            Write-Warning "Ownership transfer skipped due to -WhatIf or user declining confirmation."
            return $false 
        }
    }
    catch {
        Write-Error "Generic failure in Invoke-KeeperActionCommand for: $($Global:KeeperExecutablePath) $CommandArguments`n$($_.Exception.Message)"
        return $false 
    }
}

Function Test-KeeperSession {
    [OutputType([bool])]
    param()
    $who = Invoke-KeeperCommand "whoami" -AttemptJson:$false
    if ($who -and ($who | Out-String) -match "User:") { return $true }
    if ($Global:KeeperCliExitCode -eq 0 -and $who) { return $true }
    $paths = @()
    if ($env:KEEPER_CONFIG_PATH) { $paths += $env:KEEPER_CONFIG_PATH }
    if ($env:USERPROFILE) { $paths += Join-Path $env:USERPROFILE ".keeper\config.json" }
    if ($env:HOME) { $paths += (Join-Path $env:HOME ".keeper/config.json") }
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try { $cfg = Get-Content $p -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($cfg.session_token) { return $true }
        }
    }
    return $false
}
Function Invoke-KeeperLoginShell {
    Write-Host "`nLaunching Keeper shell. Log in if needed, then type 'quit' to return." -ForegroundColor Cyan
    & $Global:KeeperExecutablePath shell
}


Function Select-FromConsoleMenu {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$Items, 
        [Parameter(Mandatory=$true)]
        [string]$Title,
        [Parameter(Mandatory=$false)]
        [ValidateSet('Single','Multiple')]
        [string]$SelectionMode = 'Single'
    )
    Write-Host "`n--- $Title ---" -ForegroundColor Yellow
    if ($null -eq $Items -or @($Items).Count -eq 0) { 
        Write-Warning "No items available for selection."
        return $null
    }

    for ($i = 0; $i -lt @($Items).Count; $i++) { 
        Write-Host ("[{0}] {1} (UID: {2})" -f ($i + 1), $Items[$i].Name, $Items[$i].UID)
    }

    $selectedObjects = [System.Collections.Generic.List[PSCustomObject]]::new()
    $promptMessage = if ($SelectionMode -eq 'Multiple') { "Enter number(s) separated by comma (e.g., 1,3,5), or 'all', or 'none':" } else { "Enter number, or 'none':" }
    
    while ($true) {
        $userInput = Read-Host -Prompt $promptMessage
        if ($userInput -ieq 'none') { return $null }
        if ($SelectionMode -eq 'Multiple' -and $userInput -ieq 'all') {
            return $Items 
        }
        if ($SelectionMode -eq 'Single' -and $userInput -ieq 'all') {
            Write-Warning "'all' is not a valid option for single selection. Please pick one number."
            continue 
        }

        $indices = $userInput -split ',' | ForEach-Object { $_.Trim() }
        $validSelection = $true
        $tempSelectedObjects = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($indexStr in $indices) {
            if ($indexStr -match "^\d+$") {
                $choiceIndex = [int]$indexStr - 1 
                if ($choiceIndex -ge 0 -and $choiceIndex -lt @($Items).Count) { 
                    $tempSelectedObjects.Add($Items[$choiceIndex])
                    if ($SelectionMode -eq 'Single') { break } 
                } else {
                    Write-Warning "Invalid selection: '$indexStr'. Please enter a valid number from the list."
                    $validSelection = $false; break
                }
            } else {
                Write-Warning "Invalid input: '$indexStr'. Please enter numbers only."
                $validSelection = $false; break
            }
        }

        if ($validSelection -and @($tempSelectedObjects).Count -gt 0) {
            if ($SelectionMode -eq 'Single') {
                return $tempSelectedObjects[0] 
            } else {
                return $tempSelectedObjects 
            }
        } elseif ($validSelection -and $SelectionMode -eq 'Single') { 
             Write-Warning "No valid selection made."
        }
    }
}

Function Get-KeeperTeamsList {
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    $teamsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    Write-Verbose "Attempting to fetch teams with 'enterprise-info --teams'."
    $commandOutput = Invoke-KeeperCommand "enterprise-info --teams"
    
    if ($commandOutput -is [string[]]) { 
        Write-Warning "Parsing 'enterprise-info --teams' output as text because JSON failed or was not returned."
        $headerLinesToSkip = 2 
        $dataLines = $commandOutput | Select-Object -Skip $headerLinesToSkip
        foreach ($line in $dataLines) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith("---")) { continue }
            $parts = $line -split '\s{2,}' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
            if (@($parts).Count -ge 2) { 
                $teamUid = $parts[0].Trim()
                $nameCandidateParts = New-Object System.Collections.Generic.List[string]; $nameCandidateParts.Add($parts[1].Trim()) 
                for ($i = 2; $i -lt @($parts).Count; $i++) { 
                    if ((@($parts).Count - $i) -le 3) { 
                        if (($parts[$i] -match "^[RWS\s-]{0,5}$" -and $parts[$i].Length -le 5) -or $parts[$i].Contains('\') -or ($i -eq (@($parts).Count - 1) -and $parts[$i] -match "^\d+$") -or ($i -eq (@($parts).Count - 2) -and $parts[$i+1] -match "^\d+$") -or ($i -eq (@($parts).Count - 3) -and $parts[$i+2] -match "^\d+$")) { 
                            break 
                        }
                    }
                    $nameCandidateParts.Add($parts[$i].Trim())
                }
                $teamName = ($nameCandidateParts -join " ").Trim()
                if ($teamUid -and $teamName) { $teamsList.Add([PSCustomObject]@{ Name = $teamName; UID  = $teamUid }) } 
                else { Write-Warning "Could not parse team UID and Name from line: $line" }
            } else { Write-Warning "Could not parse line into enough parts: $line" }
        }
    } elseif ($commandOutput -is [System.Array]) { 
        Write-Verbose "JSON array output received for 'enterprise-info --teams'."
        $commandOutput | ForEach-Object { 
            $n = $null; $u = $null
            if ($_.PSObject.Properties['name']) { $n = $_.name }
            if ($_.PSObject.Properties['team_uid']) { $u = $_.team_uid }
            if ($n -and $u) {$teamsList.Add([PSCustomObject]@{ Name = $n; UID = $u })}
            else { Write-Warning "Skipping team entry from JSON due to missing 'name' or 'team_uid': $($_.PSObject.Properties | Out-String)"}
        }
    } elseif ($commandOutput) { 
        Write-Verbose "Single JSON object output received for 'enterprise-info --teams'."
        $n = $null; $u = $null
        if ($commandOutput.PSObject.Properties['name']) { $n = $commandOutput.name }
        if ($commandOutput.PSObject.Properties['team_uid']) { $u = $commandOutput.team_uid }
        if ($n -and $u) {$teamsList.Add([PSCustomObject]@{ Name = $n; UID = $u })}
        else { Write-Warning "Skipping single team entry from JSON due to missing 'name' or 'team_uid': $($commandOutput | Out-String)"}
    }

    if (@($teamsList).Count -eq 0) { 
        Write-Warning "No teams from 'enterprise-info --teams'. Trying 'list-team' as fallback."
        $commandOutputLt = Invoke-KeeperCommand "list-team"
        if ($commandOutputLt -is [string[]]) {
            Write-Warning "Parsing 'list-team' output as text."
            foreach ($line in $commandOutputLt) { if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith("---") -or -not ($line -match "\S")) { continue }; $parts = $line.Trim() -split '\s+', 2; if (@($parts).Count -eq 2) { $teamsList.Add([PSCustomObject]@{ UID = $parts[0].Trim(); Name = $parts[1].Trim() }) } else { Write-Warning "Could not parse 'list-team' line: $line" }}
        } elseif ($commandOutputLt -is [System.Array]) {
            $commandOutputLt | ForEach-Object { 
                $n = $null; $u = $null
                if ($_.PSObject.Properties['name']) { $n = $_.name } elseif ($_.PSObject.Properties['team_name']) { $n = $_.team_name }
                if ($_.PSObject.Properties['team_uid']) { $u = $_.team_uid } elseif ($_.PSObject.Properties['uid']) { $u = $_.uid }
                if ($n -and $u) {$teamsList.Add([PSCustomObject]@{ Name = $n; UID  = $u })} 
                else { Write-Warning "Skipping list-team entry from JSON due to missing name or UID: $($_.PSObject.Properties | Out-String)"}
            }
        } elseif ($commandOutputLt) {
             $n = $null; $u = $null
             if ($commandOutputLt.PSObject.Properties['name']) { $n = $commandOutputLt.name } elseif ($commandOutputLt.PSObject.Properties['team_name']) { $n = $commandOutputLt.team_name }
             if ($commandOutputLt.PSObject.Properties['team_uid']) { $u = $commandOutputLt.team_uid } elseif ($commandOutputLt.PSObject.Properties['uid']) { $u = $commandOutputLt.uid }
             if ($n -and $u) {$teamsList.Add([PSCustomObject]@{ Name = $n; UID  = $u })}
             else { Write-Warning "Skipping single list-team entry from JSON due to missing name or UID: $($commandOutputLt | Out-String)"}
        }
    }
    return $teamsList
}

Function Get-KeeperSharedFoldersList {
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    $sfList = [System.Collections.Generic.List[PSCustomObject]]::new()
    Write-Verbose "Attempting to fetch all shared folders with 'lsf'."
    $commandOutput = Invoke-KeeperCommand "lsf"
    if ($commandOutput -is [string[]]) { 
        Write-Warning "Parsing 'lsf' output as text."
        $headerLinesToSkip = 2; $dataLines = $commandOutput | Select-Object -Skip $headerLinesToSkip
        foreach ($line in $dataLines) { if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith("---")) { continue }; $parts = $line.Trim() -split '\s{2,}', 2; if (@($parts).Count -eq 2) { $sfList.Add([PSCustomObject]@{ UID = $parts[0].Trim(); Name = $parts[1].Trim() }) } else { Write-Warning "Could not parse 'lsf' line: $line" }}
    } elseif ($commandOutput -is [System.Array]) { 
        $commandOutput | ForEach-Object { 
            $n = $null; $u = $null
            if ($_.PSObject.Properties['name']) { $n = $_.name } elseif ($_.PSObject.Properties['folder_name']) { $n = $_.folder_name }
            if ($_.PSObject.Properties['shared_folder_uid']) { $u = $_.shared_folder_uid }
            if ($n -and $u) {$sfList.Add([PSCustomObject]@{ Name = $n; UID = $u })}
            else { Write-Warning "Skipping shared folder entry from JSON due to missing name or UID: $($_.PSObject.Properties | Out-String)"}
        }
    } elseif ($commandOutput) { 
         $n = $null; $u = $null
         if ($commandOutput.PSObject.Properties['name']) { $n = $commandOutput.name } elseif ($commandOutput.PSObject.Properties['folder_name']) { $n = $commandOutput.folder_name }
         if ($commandOutput.PSObject.Properties['shared_folder_uid']) { $u = $commandOutput.shared_folder_uid }
         if ($n -and $u) {$sfList.Add([PSCustomObject]@{ Name = $n; UID = $u })}
         else { Write-Warning "Skipping single shared folder entry from JSON due to missing name or UID: $($commandOutput | Out-String)"}
    }
    return $sfList
}

Function Get-AssociatedSharedFoldersForTeams {
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$SelectedTeams, 
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$AllSharedFoldersFromLsf 
    )
    $associatedFolders = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (@($SelectedTeams).Count -eq 0 -or @($AllSharedFoldersFromLsf).Count -eq 0) {
        Write-Verbose "Get-AssociatedSharedFoldersForTeams: No teams or no shared folders provided to scan."
        return $associatedFolders
    }
    
    Write-Host "Fetching details for $(@($AllSharedFoldersFromLsf).Count) shared folder(s) individually to check team permissions. This may take a moment..." -ForegroundColor Yellow
    
    $totalFoldersToScan = @($AllSharedFoldersFromLsf).Count
    $foldersScannedOverall = 0 # For overall progress across all teams

    foreach ($teamToScan in $SelectedTeams) {
        Write-Verbose "Scanning for folders associated with team: $($teamToScan.Name) (UID: $($teamToScan.UID))"
        # Reset per-team scan count if you want progress per team, or use foldersScannedOverall for total
        # For simplicity, using foldersScannedOverall for total progress
        foreach ($sfSummaryInLoop in $AllSharedFoldersFromLsf) {
            $foldersScannedOverall++ 
            # Corrected Write-Progress status string
            $statusMsg = "Team '{0}': Checking folder {1} of {2} ('{3}')" -f $teamToScan.Name, $foldersScannedOverall, $totalFoldersToScan, $sfSummaryInLoop.Name
            Write-Progress -Activity "Scanning Shared Folders for Team Associations" -Status $statusMsg -PercentComplete (($foldersScannedOverall / ($totalFoldersToScan * @($SelectedTeams).Count)) * 100) # Approximate overall progress

            $sfUidCurrent = $sfSummaryInLoop.UID
            $sfNameCurrent = $sfSummaryInLoop.Name
            if (-not $sfUidCurrent) { Write-Warning "Skipping a shared folder summary without UID: $($sfSummaryInLoop | Out-String)"; continue }

            Write-Verbose "  Checking permissions for shared folder: '$sfNameCurrent' (UID: $sfUidCurrent) against team '$($teamToScan.Name)'"
            $sfDetailsCurrent = Invoke-KeeperCommand "folder-info $sfUidCurrent" 
            
            if ($null -eq $sfDetailsCurrent) {
                Write-Warning "Failed to get details for shared folder '$sfNameCurrent' (UID: $sfUidCurrent)."
                $Global:transferActionFailures++ 
                continue
            }
            if ($sfDetailsCurrent -is [string[]]) { 
                 Write-Warning "Received text output instead of JSON for 'folder-info $sfUidCurrent'. Cannot process team permissions for this folder. STDERR might contain more info."
                 $Global:transferActionFailures++ 
                 continue
            }

            Write-Verbose "  Details for '$sfNameCurrent' (UID: $sfUidCurrent): $($sfDetailsCurrent | ConvertTo-Json -Depth 5 -Compress)"
            if ($sfDetailsCurrent.PSObject.Properties['teams'] -and $sfDetailsCurrent.teams -is [System.Array]) {
                foreach ($teamPermissionEntryCurrent in $sfDetailsCurrent.teams) {
                    $entryTeamUidCurrent = $null; $entryTeamNameCurrent = $null
                    if ($teamPermissionEntryCurrent.PSObject.Properties['team_uid']) { $entryTeamUidCurrent = $teamPermissionEntryCurrent.team_uid } 
                    elseif ($teamPermissionEntryCurrent.PSObject.Properties['uid']) { $entryTeamUidCurrent = $teamPermissionEntryCurrent.uid }
                    if ($teamPermissionEntryCurrent.PSObject.Properties['name']) { $entryTeamNameCurrent = $teamPermissionEntryCurrent.name }
                    
                    if (($entryTeamUidCurrent -and ($entryTeamUidCurrent -eq $teamToScan.UID)) -or `
                        ($entryTeamNameCurrent -and ($entryTeamNameCurrent -eq $teamToScan.Name))) {
                        if (-not ($associatedFolders | Where-Object {$_.UID -eq $sfUidCurrent})) { 
                            $associatedFolders.Add([PSCustomObject]@{ Name = $sfNameCurrent; UID = $sfUidCurrent }) 
                            Write-Verbose "    Added folder '$sfNameCurrent' for processing (associated with team '$($teamToScan.Name)')." 
                        }
                        break 
                    }
                } 
            } else {
                 Write-Verbose "  Folder '$sfNameCurrent' details do not have a 'teams' array property, or it's not an array, or it's empty."
            }
        } 
    } 
    Write-Progress -Activity "Scanning Shared Folders" -Completed
    return $associatedFolders | Select-Object -Unique -Property UID, Name 
}


# --- Main Script Logic ---
$runModeToExecute = $null
$selectedTeamsToProcess = [System.Collections.Generic.List[PSCustomObject]]::new() 
$sharedFoldersToProcess = [System.Collections.Generic.List[PSCustomObject]]::new() 
$newOwnerEmailToUse = $null

$choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Confirm the action."
$choiceNo = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Cancel the action."
$yesNoOptions = [System.Management.Automation.Host.ChoiceDescription[]]($choiceYes, $choiceNo)
$outGridViewCommand = Get-Command Out-GridView -ErrorAction SilentlyContinue

try { 
    if ($RunAutomated) {
        Write-Host "Running in Automated mode." -ForegroundColor Yellow
        try {
            $config = Get-Content $ConfigFilePath | ConvertFrom-Json -ErrorAction Stop
            $runModeToExecute = $config.RunMode; $newOwnerEmailToUse = $config.NewOwnerEmail
            if ($config.PSObject.Properties['LogDetail'] -and $config.LogDetail -eq "Verbose") { $VerbosePreference = "Continue" } else { $VerbosePreference = "SilentlyContinue" }
            if ($config.PSObject.Properties['ScriptConfigVersion'] -and $config.ScriptConfigVersion -ne $scriptConfigFileVersion) {
                Write-Warning "Configuration file version ($($config.ScriptConfigVersion)) does not match script version ($scriptConfigFileVersion). Compatibility issues may occur."
            } elseif (-not $config.PSObject.Properties['ScriptConfigVersion']){
                Write-Warning "Configuration file is missing version information. It might be from an older script version."
            }

            if ($config.PSObject.Properties['SelectedTeams']) { $config.SelectedTeams | ForEach-Object { $selectedTeamsToProcess.Add($_) } }
            if ($config.PSObject.Properties['SelectedSharedFolders']) { $config.SelectedSharedFolders | ForEach-Object { $sharedFoldersToProcess.Add($_) } }
            if ($config.PSObject.Properties['NoRecursive']) { $useRecursive = -not [bool]$config.NoRecursive }
            if ($NoRecursive) { $useRecursive = $false }
            if (-not $runModeToExecute -or -not $newOwnerEmailToUse) { Write-Error "Config file '$ConfigFilePath' is missing 'RunMode' or 'NewOwnerEmail'. Exiting."; Exit 1 }
            Write-Host "Parameters loaded from config file '$ConfigFilePath':" -ForegroundColor Green; Write-Host "  Run Mode: $runModeToExecute"
            if (@($selectedTeamsToProcess).Count -gt 0) { Write-Host "  Selected Team(s) (for context):"; $selectedTeamsToProcess | ForEach-Object { Write-Host "    - $($_.Name) (UID: $($_.UID))" } }
            if (@($sharedFoldersToProcess).Count -gt 0 -and ($runModeToExecute -eq "SharedFolders" -or $runModeToExecute -eq "ProcessSpecificFoldersForTeams")) { Write-Host "  Shared Folder(s) to Process:"; $sharedFoldersToProcess | ForEach-Object { Write-Host "    - $($_.Name) (UID: $($_.UID))" } }
            Write-Host "  New Owner: $newOwnerEmailToUse"
            Write-Host "  Recursive: $useRecursive"
        } catch { Write-Error "Failed to load or parse config file '$ConfigFilePath'. Error: $($_.Exception.Message). Exiting."; Exit 1 }
    } else { # Interactive Mode
        Write-Host "Running in Interactive mode." -ForegroundColor Yellow
        $logChoiceTitle = "Log Detail Level"; $logChoiceMsg = "Select log level:"; $logOptions = [System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Normal"; New-Object System.Management.Automation.Host.ChoiceDescription "&Verbose"); $logChosenIndex = $Host.UI.PromptForChoice($logChoiceTitle, $logChoiceMsg, $logOptions, 0); if ($logChosenIndex -eq 1) { $VerbosePreference = "Continue" } else { $VerbosePreference = "SilentlyContinue" }; Write-Host "Log detail: $($VerbosePreference)." -ForegroundColor Magenta
        Write-Host "`nLaunching Keeper shell to verify login." -ForegroundColor Yellow
        Write-Host "If prompted, log in. Type 'quit' to return here." -ForegroundColor Yellow
        Invoke-KeeperLoginShell
        $sessionOk = Test-KeeperSession
        if (-not $sessionOk) { Write-Error "Keeper login not verified. Exiting."; Exit 1 }
        Write-Host "Keeper login verified." -ForegroundColor Green
        $persistChoice = $Host.UI.PromptForChoice("Persistent Login", "Enable persistent login for this account?", $yesNoOptions, 1)
        if ($persistChoice -eq 0) {
            Write-Host "`nLaunching Keeper shell to configure persistent login. Follow prompts and type 'quit' when finished." -ForegroundColor Cyan
            Invoke-KeeperLoginShell
        }

        $interactiveListType = ""; $choiceOptionsList = [System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Teams"; New-Object System.Management.Automation.Host.ChoiceDescription "&Shared Folders"); $choiceTitleList = "Selection Type"; $choiceMessageList = "Work with Teams or Shared Folders?"; $chosenIndexList = $Host.UI.PromptForChoice($choiceTitleList, $choiceMessageList, $choiceOptionsList, 0); if ($chosenIndexList -eq 0) { $interactiveListType = "Teams"; $runModeToExecute = "Teams" } elseif ($chosenIndexList -eq 1) { $interactiveListType = "SharedFolders"; $runModeToExecute = "SharedFolders" } else { Write-Error "Invalid choice. Exiting."; Exit 1 }

        $itemsAvailableForSelection = if ($interactiveListType -eq "Teams") { Get-KeeperTeamsList } else { Get-KeeperSharedFoldersList }
        if (@($itemsAvailableForSelection).Count -eq 0) { Write-Error "No $interactiveListType found. Exiting."; Exit 1 }
        
        Write-Host "`nAvailable $($interactiveListType):"
        $cleanItemsForGridView = $itemsAvailableForSelection | Where-Object { $_ -ne $null -and $_.PSObject.Properties['UID'] -and $_.UID -ne "NO_UID" -and -not [string]::IsNullOrWhiteSpace($_.UID) -and $_.PSObject.Properties['Name'] -and $_.Name -ne "Unknown" -and -not [string]::IsNullOrWhiteSpace($_.Name) }
        if (@($cleanItemsForGridView).Count -eq 0) { Write-Error "No valid items to display for selection. Exiting."; Exit 1 }
        Write-Verbose "DEBUG: Piping $(@($cleanItemsForGridView).Count) items to selection."

        $selectedItemsFromGrid = $null
        if ($outGridViewCommand) { 
            Write-Verbose "Using Out-GridView."; $selectedItemsFromGrid = $cleanItemsForGridView | Out-GridView -Title "Select $($interactiveListType.TrimEnd('s')) (Ctrl+Click for multiple)" -OutputMode Multiple
        } else { 
            Write-Warning "Out-GridView N/A. Using console menu."; $selectedItemsFromGrid = Select-FromConsoleMenu -Items $cleanItemsForGridView -Title "Select $($interactiveListType)" -SelectionMode Multiple
        }
        if (-not $selectedItemsFromGrid) { Write-Error "No item(s) selected. Exiting."; Exit 1 }

        if ($interactiveListType -eq "Teams") { $selectedItemsFromGrid | ForEach-Object { $selectedTeamsToProcess.Add($_) }; Write-Host "Selected Team(s):" -ForegroundColor Green; $selectedTeamsToProcess | ForEach-Object { Write-Host "  - $($_.Name) (UID: $($_.UID))" } }
        else { $selectedItemsFromGrid | ForEach-Object { $sharedFoldersToProcess.Add($_) }; Write-Host "Selected Shared Folder(s):" -ForegroundColor Green; $sharedFoldersToProcess | ForEach-Object { Write-Host "  - $($_.Name) (UID: $($_.UID))" } }
        
        $emailIsValid = $false
        while (-not $emailIsValid) {
            $newOwnerEmailToUse = Read-Host -Prompt "`nEnter email for new owner"
            try { 
                [void][System.Net.Mail.MailAddress]::new($newOwnerEmailToUse) 
                $emailIsValid = $true 
                Write-Verbose "Attempting to verify new owner email '$newOwnerEmailToUse' with Keeper..."
                $userInfo = Invoke-KeeperCommand "user-info --email ""$newOwnerEmailToUse"""
                if ($Global:KeeperCliExitCode -ne 0 -or $null -eq $userInfo -or ($userInfo -is [System.Array] -and @($userInfo).Count -eq 0)) { 
                    Write-Warning "Could not verify email '$newOwnerEmailToUse' as an existing Keeper user or command failed."
                    $emailConfirmOptions = [System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Proceed with this email"; New-Object System.Management.Automation.Host.ChoiceDescription "&Re-enter email"; New-Object System.Management.Automation.Host.ChoiceDescription "&Exit script")
                    $emailConfirmIndex = $Host.UI.PromptForChoice("New Owner Email Verification", "Email not verified as Keeper user. Proceed?", $emailConfirmOptions, 1)
                    if ($emailConfirmIndex -eq 1) { $emailIsValid = $false } 
                    elseif ($emailConfirmIndex -eq 2) { Write-Host "Exiting script."; Exit 0 }
                } else {
                    Write-Host "Email '$newOwnerEmailToUse' appears to be a valid Keeper user." -ForegroundColor Green
                }
            } catch { 
                Write-Warning "Invalid email format: '$newOwnerEmailToUse'. Please try again."
                $emailIsValid = $false
            }
        }
        Write-Host "Transfer to: $newOwnerEmailToUse" -ForegroundColor Yellow

        $recChoiceIndex = $Host.UI.PromptForChoice("Recursive Transfer", "Transfer recursively to sub-folders and records?", $yesNoOptions, 0)
        $useRecursive = ($recChoiceIndex -eq 0)
        if ($NoRecursive) { $useRecursive = $false }

        $saveParamsChoiceIndex = $Host.UI.PromptForChoice("Save Parameters", "Save for automated runs?", $yesNoOptions, 1)
        if ($saveParamsChoiceIndex -eq 0) { 
            $configToSave = @{ NewOwnerEmail = $newOwnerEmailToUse; LogDetail = $VerbosePreference.ToString(); ScriptConfigVersion = $scriptConfigFileVersion; NoRecursive = (-not $useRecursive) }
            $saveMode = $runModeToExecute
            if ($interactiveListType -eq "Teams") {
                $configToSave.Add("SelectedTeams", $selectedTeamsToProcess)
                $saveTeamModeChoiceTitle = "Save Team Config As"; $saveTeamModeMessage = "Save for dynamic discovery or current folders?"; $saveTeamModeOptions = [System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Dynamic Discovery"; New-Object System.Management.Automation.Host.ChoiceDescription "&Specific Folders Now")
                $saveTeamModeIndex = $Host.UI.PromptForChoice($saveTeamModeChoiceTitle, $saveTeamModeMessage, $saveTeamModeOptions, 0)
                if ($saveTeamModeIndex -eq 1) { 
                    $saveMode = "ProcessSpecificFoldersForTeams"; Write-Host "Discovering folders for teams to save..." -ForegroundColor Yellow
                    $allSfsForSave = Get-KeeperSharedFoldersList
                    $discoveredFoldersForSaving = Get-AssociatedSharedFoldersForTeams -SelectedTeams $selectedTeamsToProcess -AllSharedFoldersFromLsf $allSfsForSave 
                    $configToSave.Add("SelectedSharedFolders", $discoveredFoldersForSaving); Write-Host "Discovered $(@($discoveredFoldersForSaving).Count) folders for selected team(s) to save." -ForegroundColor Green
                }
            } else { $configToSave.Add("SelectedSharedFolders", $sharedFoldersToProcess) }
            $configToSave.Add("RunMode", $saveMode)
            $defaultConfigPath = Join-Path $PSScriptRoot "keeper_transfer_config.json"; $chosenConfigPath = Read-Host -Prompt "Path to save config (default: $defaultConfigPath)"
            if ([string]::IsNullOrWhiteSpace($chosenConfigPath)) { $chosenConfigPath = $defaultConfigPath }
            try { $configToSave | ConvertTo-Json -Depth 5 | Set-Content -Path $chosenConfigPath -ErrorAction Stop; Write-Host "Parameters saved to '$chosenConfigPath'" -ForegroundColor Green } 
            catch { Write-Error "Failed to save config: $($_.Exception.Message)" }
        } 
        
        $confirmTitleInteractive = "Confirm Ownership Transfer"; $confirmMessageInteractive = "ABSOLUTELY SURE to proceed?"; $confirmResultIndexInteractive = $Host.UI.PromptForChoice($confirmTitleInteractive, $confirmMessageInteractive, $yesNoOptions, 1); if ($confirmResultIndexInteractive -ne 0) { Write-Host "Operation cancelled. Exiting."; Exit 0 }
    } 

    # --- Step 5: Perform the ownership transfer ---
    $finalFoldersToProcess = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($runModeToExecute -eq "Teams") { 
        Write-Host "`nDynamically identifying shared folders for Team(s):" -ForegroundColor Yellow
        $selectedTeamsToProcess | ForEach-Object { Write-Host "  - $($_.Name) (UID: $($_.UID))" }
        $allCurrentSharedFolders = Get-KeeperSharedFoldersList
        if (@($allCurrentSharedFolders).Count -gt 0) {
            $finalFoldersToProcess = Get-AssociatedSharedFoldersForTeams -SelectedTeams $selectedTeamsToProcess -AllSharedFoldersFromLsf $allCurrentSharedFolders 
        } else {
            Write-Warning "No shared folders found in the vault to scan for team associations."
        }
    } elseif ($runModeToExecute -eq "ProcessSpecificFoldersForTeams" -or $runModeToExecute -eq "SharedFolders") { 
        $sharedFoldersToProcess | ForEach-Object { $finalFoldersToProcess.Add($_) } 
    }

    if (@($finalFoldersToProcess).Count -eq 0) { Write-Warning "No shared folders identified for processing. Nothing to do."; Exit 0 } 
    
    if ($useRecursive) {
        Write-Warning "`nIMPORTANT: The '--recursive' flag used by 'share-record' will affect ALL records and sub-folders within the targeted shared folders."
    } else {
        Write-Warning "`nNOTE: Ownership transfer will NOT be recursive."
    }
    Write-Host "Will attempt ownership transfer for the following Shared Folder(s) to '$($newOwnerEmailToUse)':" -ForegroundColor Yellow
    $finalFoldersToProcess | Select-Object -Unique -Property UID, Name | ForEach-Object { Write-Host "  - $($_.Name) (UID: $($_.UID))" }

    if ($PSCmdlet.ShouldProcess("Selected Folders (total: $(@($finalFoldersToProcess).Count))", "Transfer Record Ownership to '$newOwnerEmailToUse'")) {
        $totalToProcessLoop = @($finalFoldersToProcess | Select-Object -Unique -Property UID).Count # Use a different name for the loop's total
        $processedCountLoop = 0 
        ForEach ($folder in ($finalFoldersToProcess | Select-Object -Unique -Property UID, Name)) { 
            $processedCountLoop++
            # Corrected Write-Progress status string using -f format operator
            $statusMsgLoop = "Processing folder {0} of {1}: {2}" -f $processedCountLoop, $totalToProcessLoop, $folder.Name
            Write-Progress -Activity "Transferring Ownership" -Status $statusMsgLoop -PercentComplete (($processedCountLoop / $totalToProcessLoop) * 100)
            Write-Host "`nAttempting ownership transfer for Shared Folder '$($folder.Name)' (UID: $($folder.UID)) to '$newOwnerEmailToUse'..." -ForegroundColor Yellow
            $recArg = if ($useRecursive) { "--recursive" } else { "" }
            $transferCmd = "share-record --action owner --email ""$newOwnerEmailToUse"" $recArg -- ""$($folder.UID)"""
            if (-not (Invoke-KeeperActionCommand $transferCmd)) {
                $Global:transferActionFailures++
                Write-Warning "Ownership transfer FAILED for folder: $($folder.Name) (UID: $($folder.UID))"
            }
        }
        Write-Progress -Activity "Transferring Ownership" -Completed
    } else { Write-Warning "Ownership transfer skipped due to -WhatIf or user declining confirmation." }

} catch {
    Write-Error "An unhandled error occurred: $($_.Exception.ToString())"
    Exit 1 
}
finally {
    if ($VerbosePreference -ne $originalVerbosePreference) {
        Write-Verbose "Restoring original VerbosePreference: $originalVerbosePreference"
        $VerbosePreference = $originalVerbosePreference 
    }

} 

Write-Host "`n-----------------------------------------------------" -ForegroundColor Cyan
Write-Host "Script finished." -ForegroundColor Cyan
if ($Global:transferActionFailures -gt 0) {
    Write-Warning "$($Global:transferActionFailures) ownership transfer action(s) reported failure(s). Please review logs."
    Write-Host "Exiting with error code 2 due to partial failure." -ForegroundColor Yellow
    Exit 2
} else {
    Write-Host "All attempted ownership transfers reported success (if any were performed and not skipped by -WhatIf)." -ForegroundColor Green
}
Write-Host "Please verify the ownership changes in Keeper." -ForegroundColor Yellow
Write-Host "-----------------------------------------------------" -ForegroundColor Cyan

$lastExit = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
if ($Global:transferActionFailures -eq 0 -and ($lastExit -eq 0 -or $null -eq $lastExit)) {
    Exit 0
} elseif ($null -ne $lastExit -and $lastExit -ne 0) {
    Exit $lastExit
}
