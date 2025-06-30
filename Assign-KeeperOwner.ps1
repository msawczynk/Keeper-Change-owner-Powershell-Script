<#
.SYNOPSIS
    Grants a designated user admin rights to one or more shared folders
    and transfers ownership of all records inside.

.EXAMPLE
    .\Assign-KeeperOwner.ps1 -UserEmail 'jane.doe@example.com' `
        -FolderUIDs '-FHdesR_GSERHUwBg4vTXw','9SCeW43ldKU3pTic3cYxKQ'
#>

param(
    [Parameter(Mandatory=$true)]
    [string]   $UserEmail,

    [Parameter(Mandatory=$true)]
    [string[]] $FolderUIDs,

    [string]   $KeeperExe = 'keeper-commander.exe',

    [switch]   $DryRun
)

function Run-Keeper ($cmd) {    
    Write-Host "Executing: $KeeperExe $cmd" -ForegroundColor Yellow
    
    try {
        & $KeeperExe $cmd 2>&1 | Tee-Object -Variable output
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Keeper command returned exit code $LASTEXITCODE but continuing..."
            Write-Host "Command output: $($output -join ' ')" -ForegroundColor Red
            # Don't throw - just warn and continue
            return $false
        }
        return $true
    }
    catch {
        Write-Warning "Error executing Keeper command: $($_.Exception.Message)"
        return $false
    }
}

foreach ($sf in $FolderUIDs) {

    Write-Host "`nProcessing folder: $sf" -ForegroundColor Green

    # 1. Grant shared-folder admin rights (using working command format)
    $shareFolderCmd = "share-folder --action=grant --email=$UserEmail --manage-users=on --manage-records=on $sf"
    if ($DryRun) {
        Write-Host "DRY RUN: Would execute: $KeeperExe $shareFolderCmd" -ForegroundColor Cyan
    } else {
        Run-Keeper $shareFolderCmd
    }

    # 2. Transfer record ownership recursively (supports --dry-run)
    if ($DryRun) {
        $shareRecordCmd = "share-record --dry-run --action=owner --email=$UserEmail --recursive --force $sf"
        Run-Keeper $shareRecordCmd
    } else {
        $shareRecordCmd = "share-record --action=owner --email=$UserEmail --recursive --force $sf"
        Run-Keeper $shareRecordCmd
    }
}
