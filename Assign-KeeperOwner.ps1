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

function Run-Keeper-Clean ($cmd, $retryCount = 2) {    
    Write-Host "Executing: $KeeperExe $cmd" -ForegroundColor Yellow
    
    for ($i = 0; $i -le $retryCount; $i++) {
        try {
            # Redirect stderr to null to suppress communication errors, keep stdout
            $output = & $KeeperExe $cmd 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[SUCCESS] Command completed successfully" -ForegroundColor Green
                if ($output) {
                    # Only show relevant output, filter out error messages
                    $cleanOutput = $output | Where-Object { 
                        $_ -notmatch "Communication Error" -and 
                        $_ -notmatch "Invalid recordKey" -and
                        $_ -notmatch "App Store" -and
                        $_ -notmatch "keepersecurity.com/support" -and
                        $_ -notmatch "RemoteException" -and
                        $_ -match "\S"  # Not empty/whitespace
                    }
                    if ($cleanOutput) {
                        Write-Host "Output:" -ForegroundColor Cyan
                        $cleanOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
                    }
                }
                return $true
            }
            else {
                if ($i -lt $retryCount) {
                    Write-Host "[RETRY] Command failed (exit code$($LASTEXITCODE)), retrying... ($($i+1)/$($retryCount+1))" -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
                else {
                    Write-Host "[FAILED] Command failed after $($retryCount+1) attempts (exit code $LASTEXITCODE)" -ForegroundColor Red
                    return $false
                }
            }
        }
        catch {
            if ($i -lt $retryCount) {
                Write-Host "[RETRY] Exception occurred, retrying... ($($i+1)/$($retryCount+1))" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
            else {
                Write-Host "[ERROR] Exception after $($retryCount+1) attempts - $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }
    }
    return $false
}

Write-Host "=== Starting Keeper Ownership Transfer Script ===" -ForegroundColor Magenta
Write-Host "Target User: $UserEmail" -ForegroundColor Cyan
Write-Host "Folders to Process: $($FolderUIDs.Count)" -ForegroundColor Cyan

foreach ($sf in $FolderUIDs) {
    Write-Host "`n[FOLDER] Processing folder: $sf" -ForegroundColor Green
    Write-Host "=" * 60 -ForegroundColor Gray

    # 1. Grant shared-folder admin rights
    Write-Host "[STEP 1] Granting admin rights..." -ForegroundColor Blue
    $shareFolderCmd = "share-folder --action=grant --email=$UserEmail --manage-users=on --manage-records=on $sf"
    
    if ($DryRun) {
        Write-Host "[DRY RUN] Would execute: $KeeperExe $shareFolderCmd" -ForegroundColor Cyan
        $step1Success = $true
    } else {
        $step1Success = Run-Keeper-Clean $shareFolderCmd
    }

    # 2. Transfer record ownership recursively
    Write-Host "[STEP 2] Transferring record ownership..." -ForegroundColor Blue
    
    if ($DryRun) {
        $shareRecordCmd = "share-record --dry-run --action=owner --email=$UserEmail --recursive --force $sf"
    } else {
        $shareRecordCmd = "share-record --action=owner --email=$UserEmail --recursive --force $sf"
    }
    
    $step2Success = Run-Keeper-Clean $shareRecordCmd

    # Summary for this folder
    if ($step1Success -and $step2Success) {
        Write-Host "[SUCCESS] Folder $sf - ALL OPERATIONS COMPLETED SUCCESSFULLY" -ForegroundColor Green
    } elseif ($step1Success) {
        Write-Host "[PARTIAL] Folder $sf - Admin rights granted, but record transfer had issues" -ForegroundColor Yellow
    } elseif ($step2Success) {
        Write-Host "[PARTIAL] Folder $sf - Records transferred, but admin rights grant had issues" -ForegroundColor Yellow
    } else {
        Write-Host "[FAILED] Folder $sf - BOTH OPERATIONS FAILED" -ForegroundColor Red
    }
}

Write-Host "`n=== Script execution completed ===" -ForegroundColor Magenta
