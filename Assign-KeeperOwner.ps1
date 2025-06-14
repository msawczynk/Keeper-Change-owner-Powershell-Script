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
    if ($DryRun) { $cmd += ' --dry-run' }
    & $KeeperExe $cmd 2>&1 | Tee-Object -Variable output
    if ($LASTEXITCODE) {
        throw "Keeper command failed: $($output -join ' ')" 
    }
}

foreach ($sf in $FolderUIDs) {

    # 1. Grant shared-folder admin rights
    Run-Keeper @"
share-folder --action grant `
    --email $UserEmail `
    --manage-users on --manage-records on -- $sf
"@

    # 2. Transfer record ownership recursively
    Run-Keeper @"
share-record --action owner `
    --email $UserEmail --recursive --force -- $sf
"@
}
