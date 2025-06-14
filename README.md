# Automating Shared‑Folder Ownership Transfers with **Keeper Commander**

> **Audience** – Windows system admins & power users who manage Keeper Security vaults and are comfortable with basic PowerShell and Task Scheduler.

---

## 1. Why You’d Do This  

Shared folders don’t have an explicit “owner” flag.  
If you need a **single account to own everything in specific shared folders**—in order to meet off‑boarding, auditing, or compliance rules—you must:

1. **Make that account a *shared‑folder admin*** (can manage users & records).  
2. **Transfer record ownership** for every item inside, recursively.

Doing this manually is error‑prone; running it daily via an approved service account keeps the environment continuously correct.

---

## 2. Prerequisites  

| Requirement | Notes |
|-------------|-------|
| **Keeper Commander 17.0+** | Confirm with `keeper --version`. |
| **Service account in Keeper** | e.g. `svc_keeper@example.com` with *Keeper Administrator* role. |
| **Windows Server 2016+ / Windows 10+** | Host for Task Scheduler. |
| **Persistent‑login token (30‑day)** | See § 8 to set it up once; automation is then password‑less. |
| (Optional) **Enterprise SSO or stored TOTP** | Only needed if you refuse persistent‑login. |

---

## 3. Solution Architecture  

```text
┌────────────┐    daily @ 02:15     ┌─────────────────────┐
│ TaskScheduler ──────────────────▶ │ PowerShell wrapper  │
└────────────┘                      │  (Assign‑KeeperOwner.ps1)
                                    │  • share-folder
                                    │  • share-record
                                    └─────────┬───────────┘
                                              │ REST API
                                              ▼
                                    ┌─────────────────────┐
                                    │  Keeper Commander   │
                                    └─────────────────────┘
```

*Two CLI calls per folder → idempotent ownership state.*

---

## 4. The Script  

Save as **`C:\\Scripts\\Assign‑KeeperOwner.ps1`**

```powershell
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
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `--action grant` | Grants user rights on folder. |
| `--manage-users on` & `--manage-records on` | Makes target user *shared‑folder admin*. |
| `--action owner` | Sets target as record owner. |
| `--recursive --force` | Recurse into sub‑folders, take over existing ownership conflicts. |
| `--dry-run` | Simulate changes—no vault modifications. |

The script is **idempotent**: re‑running when rights already exist simply returns *no change*.

---

## 5. Scheduling the Job  

Run once (elevated PowerShell) on the host:

```powershell
$trigger = New-ScheduledTaskTrigger -Daily -At 02:15
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument '-NoLogo -NonInteractive -ExecutionPolicy Bypass -File "C:\\Scripts\\Assign-KeeperOwner.ps1"'
Register-ScheduledTask -TaskName 'Keeper-FolderOwner' `
    -Trigger $trigger -Action $action `
    -User 'DOMAIN\\svc_keeper' -RunLevel Highest
```

> **Tip** – select *“Run whether user is logged on or not”* and store the service‑account password once.

---

## 6. Testing  

1. **Dry run**:  

   ```powershell
   .\Assign-KeeperOwner.ps1 -UserEmail 'jane.doe@example.com' `
       -FolderUIDs 'abc123...' -DryRun
   ```

   Confirm output.  
2. Remove `-DryRun`, re‑execute.  
3. Verify in **Admin Console → Reporting → Record Ownership** or via:

   ```powershell
   keeper list --records --owned
   ```

---

## 7. Troubleshooting & Edge Cases  

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `device not approved` | Service account never opened Commander interactive shell. | Log on once, run `keeper shell`, approve device code. |
| `illegal request: record already owned` | Another user manually set a different owner. | Script will override next run (expected). |
| Task hangs forever | MFA prompt waiting for input. | Use persistent‑login (§ 8) or embed stored TOTP. |
| New sub‑folders not covered | Added after last run. | Next nightly pass picks them up automatically. |

---

## 8. Persistent‑Login: Set‑Up & Automatic Refresh  

> **Goal** – one interactive session, never store a master password, and the token silently renews.

### 8.1 One‑Time Interactive Boot‑Strap  

```powershell
keeper shell
# In the commander prompt:
this-device register
this-device persistent-login on
this-device timeout 30d          # optional (default 30d)
this-device ip-auto-approve on   # optional
quit                             # DO NOT run "logout"
```

`config.json` now holds the device keys & 30‑day refresh token (per‑machine).

### 8.2 How Auto‑Refresh Works  

* Every non‑interactive Commander run touches the API.  
* If the token is < 30 days old, Commander extends its expiry back to 30 days.  
* Your daily schedule therefore **keeps the token alive forever**.

### 8.3 Optional Safety Ping  

Create `C:\\Scripts\\Keeper‑Ping.ps1`:

```powershell
& 'keeper-commander.exe' whoami --config 'C:\\Users\\svc_keeper\\.keeper\\config.json'
```

Schedule it monthly (1 st at 00:30) to refresh even if main job fails.

### 8.4 Golden Rules  

| Do | Don’t |
|----|-------|
| Back up `config.json` securely. | **Never** call `keeper logout` in scripts. |
| Keep hostname & SID unchanged. | Copy the token file to another machine (it will invalidate). |
| Rotate token via `persistent-login off/on` when policy demands. | Store master passwords in plaintext. |

---

## 9. Frequently Asked Questions  

**Q. Does this break if the user already has some rights?**  
No. Commander merges and upgrades privileges; it won’t downgrade existing access.

**Q. What if the user gets deleted?**  
The nightly job will error. Pause or remove the task before de‑provisioning, or point to a new account.

**Q. Why not embed the master password instead?**  
Because someone will eventually cat the script or commit it to Git. The persistent‑login token is device‑bound and short‑lived.

**Q. Can this run from a container that restarts daily?**  
Yes, but then use env‑driven password injection or Secret Manager; the token file vanishes with the container filesystem.

---

## 10. Change History  

| Date | Revision | Notes |
|------|----------|-------|
| 2025‑06‑14 | v1.1 | Added persistent‑login setup & auto‑refresh steps. |
| 2025‑06‑14 | v1.0 | Initial public version. |

---

**Two Keeper commands, one scheduled task, self‑refreshing token – that’s it.**
