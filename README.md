# forticlient-vpn-deploy

Automated deployment of FortiClient VPN to Windows endpoints (workgroup / Intune / SCCM).

---

## 📌 Current release targets

| Setting | Value |
|---|---|
| **FortiClient VPN version** | **7.0.9** |
| **Installer filename** | `FortiClientVPN-7.0.9-x64.msi` |

> ⚠️ **Heads-up for maintainers:** FortiClient 7.0.x reached end-of-support in early 2025. Plan a bump to 7.2.x LTS. To upgrade, change the two constants at the top of `scripts/Install-FortiClient.ps1` (`$FortiClientVersion`, `$DistributionServer`) and update this table.

---

## What this does

1. A one-shot scheduled task is registered on the endpoint (runs as SYSTEM at boot, 2-min delay).
2. On first boot after registration, the task pulls `FortiClientVPN-7.0.9-x64.msi` from `\\SCCM\Software\FortiClient\` and installs it silently.
3. A marker file under `C:\ProgramData\CompanyName\FortiClientDeploy\` prevents reinstall on every boot.
4. If a `vpn-profile.xml` is published alongside the MSI, it's imported via `FCConfig.exe`.

The install script is **idempotent** — safe to run repeatedly, exits in milliseconds once the marker is present.

---

## Repo layout

```
forticlient-vpn-deploy/
├── README.md
├── .gitignore
├── scripts/
│   ├── Install-FortiClient.ps1     ← main installer (runs as SYSTEM)
│   ├── Register-ScheduledTask.ps1  ← one-time setup per endpoint
│   └── Uninstall-FortiClient.ps1   ← cleanup
├── config/
│   └── vpn-profile.xml.example     ← template; do NOT commit the real one
└── docs/
    ├── Intune-Deployment.md
    └── Troubleshooting.md
```

---

## Prerequisites

- Endpoint can reach `\\SCCm\Software\FortiClient\` over SMB (port 445).
- The SYSTEM account on the endpoint has read access to that share. Typically this means granting `Domain Computers` or `Authenticated Users` read on the share/NTFS ACL. **In a workgroup environment**, SYSTEM presents as the computer account anonymously — you may need to allow guest/anonymous read on the share, or pre-stage credentials with `cmdkey`. See `docs/Troubleshooting.md`.
- Endpoint has PowerShell 5.1+ (default on Windows 10/11).
- `FortiClientVPN-7.0.9-x64.msi` is staged at `\\SCCM\Software\FortiClient\`.
- *(Recommended)* A `FortiClientVPN-7.0.9-x64.msi.sha256` file alongside the MSI for integrity verification.

---

## Deployment paths

### Option A — Intune (recommended for workgroup endpoints)

Upload `Register-ScheduledTask.ps1` and `Install-FortiClient.ps1` as a **Platform script** (Devices → Scripts → Add → Windows 10/11). Run as SYSTEM, 64-bit PowerShell. The script registers the task; install fires on next boot.

See `docs/Intune-Deployment.md`.

### Option B — SCCM / ConfigMgr

Create a **Package** with these scripts and a **Program** that runs:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-ScheduledTask.ps1
```
Deploy to your collection. Detection method: presence of `C:\ProgramData\CompanyName\FortiClientDeploy\installed-7.0.9.flag`.

### Option C — Manual (testing / one-off)

```powershell
# On the endpoint, as admin:
git clone https://github.com/<your-org>/forticlient-vpn-deploy.git
cd forticlient-vpn-deploy\scripts
.\Register-ScheduledTask.ps1

# To install immediately without rebooting:
Start-ScheduledTask -TaskName 'Deploy-FortiClientVPN'
```

---

## Verifying a deployment

On the endpoint:

```powershell
# Did the task fire?
Get-ScheduledTaskInfo -TaskName 'Deploy-FortiClientVPN'

# Is the marker present?
Test-Path 'C:\ProgramData\CompanyName\FortiClientDeploy\installed-7.0.9.flag'

# Is FortiClient installed?
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object DisplayName -like 'FortiClient*' |
    Select-Object DisplayName, DisplayVersion

# Logs
Get-ChildItem 'C:\ProgramData\CompanyName\FortiClientDeploy\Logs\'
```

---

## Bumping the version

1. Stage the new MSI on `\\SCCM\Software\FortiClient\` (e.g. `FortiClientVPN-7.2.4-x64.msi`).
2. Drop a matching `.sha256` file next to it.
3. In `scripts/Install-FortiClient.ps1`, update:
   ```powershell
   $FortiClientVersion = '7.2.4'
   ```
4. Update the release-targets table at the top of this README.
5. Commit, PR, merge. Endpoints will reinstall automatically because the marker filename includes the version (`installed-7.2.4.flag` won't exist yet).

---

## Security notes

- **Never commit real VPN profile XML** — it may contain gateway addresses, pre-shared keys, or certificates. Use `config/vpn-profile.xml.example` as a template and stage the real file on the distribution server.
- **Never commit the MSI itself** — large binary, doesn't belong in git. Stage on the distribution server.
- This repo is for **scripts and documentation only**.

---

## Contact

Maintained by IT / Endpoint Engineering. File issues in this repo.
