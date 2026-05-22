<#
.SYNOPSIS
    Silently installs FortiClient VPN on Windows endpoints.

.DESCRIPTION
    Fetches the FortiClient VPN MSI from the internal distribution server,
    verifies it, and performs a silent install. Idempotent: exits cleanly
    if the target version is already installed.

    Designed to be invoked by a SYSTEM-context scheduled task on first boot.
    Do NOT run as a per-user logon script — MSI installs require admin rights
    and only need to happen once per machine.

.NOTES
    -----------------------------------------------------------------
    Project:     forticlient-vpn-deploy
    Maintainer:  IT / Endpoint Engineering
    -----------------------------------------------------------------
    DEPLOYMENT TARGETS FOR THIS RELEASE
    -----------------------------------------------------------------
    FortiClient VPN version : 7.0.9
    Distribution server     : 10.10.8.200
    -----------------------------------------------------------------
    To bump the version or change the server, edit the variables in
    the CONFIGURATION block below. Keep README.md in sync.
    -----------------------------------------------------------------
#>

[CmdletBinding()]
param(
    [switch]$Force  # Reinstall even if marker indicates success
)

# =================================================================
# CONFIGURATION  -- update these when bumping the release
# =================================================================
$FortiClientVersion   = '7.0.9'
$DistributionServer   = '10.10.8.200'
$InstallerShare       = "\\$DistributionServer\Software\FortiClient"
$InstallerFileName    = "FortiClientVPN-$FortiClientVersion-x64.msi"
$InstallerSourcePath  = Join-Path $InstallerShare $InstallerFileName

# Optional pre-configured VPN profile (set to $null to skip)
$VpnProfileSource     = Join-Path $InstallerShare 'vpn-profile.xml'

# Local paths
$WorkingDir           = 'C:\ProgramData\CompanyName\FortiClientDeploy'
$LogDir               = Join-Path $WorkingDir 'Logs'
$MarkerFile           = Join-Path $WorkingDir "installed-$FortiClientVersion.flag"
$LocalInstaller       = Join-Path $WorkingDir $InstallerFileName

# =================================================================
# LOGGING
# =================================================================
$null = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

Write-Log "=== FortiClient VPN deployment started ==="
Write-Log "Target version: $FortiClientVersion"
Write-Log "Distribution server: $DistributionServer"
Write-Log "Log file: $LogFile"

# =================================================================
# PRE-FLIGHT CHECKS
# =================================================================

# 1. Must be elevated (SYSTEM or admin)
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Script is not running with administrator privileges. Aborting.' 'ERROR'
    exit 1
}

# 2. Marker file (fast path — skip if already done)
if ((Test-Path $MarkerFile) -and -not $Force) {
    Write-Log "Marker file present: $MarkerFile. FortiClient $FortiClientVersion already deployed. Exiting." 'INFO'
    exit 0
}

# 3. Registry check — is FortiClient already installed at the target version?
function Get-InstalledFortiClient {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'FortiClient*' } |
            Select-Object DisplayName, DisplayVersion, UninstallString
    }
}

$existing = Get-InstalledFortiClient
if ($existing -and -not $Force) {
    foreach ($pkg in $existing) {
        Write-Log "Found existing install: $($pkg.DisplayName) version $($pkg.DisplayVersion)"
        if ($pkg.DisplayVersion -eq $FortiClientVersion) {
            Write-Log "Target version already installed. Writing marker and exiting." 'INFO'
            New-Item -ItemType File -Path $MarkerFile -Force | Out-Null
            exit 0
        }
    }
    Write-Log "Different FortiClient version present. Continuing with install of $FortiClientVersion." 'WARN'
}

# =================================================================
# FETCH INSTALLER
# =================================================================
Write-Log "Copying installer from $InstallerSourcePath"

if (-not (Test-Path $InstallerSourcePath)) {
    Write-Log "Installer not found at $InstallerSourcePath. Check share permissions and that the file exists on $DistributionServer." 'ERROR'
    exit 2
}

try {
    Copy-Item -Path $InstallerSourcePath -Destination $LocalInstaller -Force -ErrorAction Stop
    Write-Log "Installer copied to $LocalInstaller"
}
catch {
    Write-Log "Failed to copy installer: $_" 'ERROR'
    exit 2
}

# Optional: SHA256 verification — drop a hash file alongside the MSI on the server
$HashFileSource = "$InstallerSourcePath.sha256"
if (Test-Path $HashFileSource) {
    $expected = (Get-Content $HashFileSource -Raw).Trim().Split()[0]
    $actual   = (Get-FileHash -Path $LocalInstaller -Algorithm SHA256).Hash
    if ($expected -ieq $actual) {
        Write-Log "SHA256 verified: $actual"
    } else {
        Write-Log "SHA256 mismatch! Expected $expected, got $actual. Aborting." 'ERROR'
        Remove-Item $LocalInstaller -Force -ErrorAction SilentlyContinue
        exit 3
    }
} else {
    Write-Log "No SHA256 file found alongside installer — skipping hash verification." 'WARN'
}

# =================================================================
# INSTALL
# =================================================================
$msiLog = Join-Path $LogDir ("msi-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$msiArgs = @(
    '/i', "`"$LocalInstaller`""
    '/qn'
    '/norestart'
    'REBOOT=ReallySuppress'
    '/L*v', "`"$msiLog`""
)

Write-Log "Running: msiexec.exe $($msiArgs -join ' ')"
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow

# MSI exit codes: 0 = success, 3010 = success but reboot required
switch ($proc.ExitCode) {
    0     { Write-Log 'Install completed successfully (exit 0).' }
    3010  { Write-Log 'Install completed; reboot required (exit 3010).' 'WARN' }
    1603  { Write-Log 'Fatal error during install (exit 1603). Check MSI log: '"$msiLog"'.' 'ERROR'; exit $proc.ExitCode }
    1618  { Write-Log 'Another install is in progress (exit 1618). Will retry on next trigger.' 'WARN'; exit $proc.ExitCode }
    default { Write-Log "msiexec returned non-zero exit code: $($proc.ExitCode). See $msiLog." 'ERROR'; exit $proc.ExitCode }
}

# =================================================================
# OPTIONAL: import VPN profile
# =================================================================
if ($VpnProfileSource -and (Test-Path $VpnProfileSource)) {
    Write-Log "VPN profile found at $VpnProfileSource — importing"
    try {
        $localProfile = Join-Path $WorkingDir 'vpn-profile.xml'
        Copy-Item $VpnProfileSource $localProfile -Force
        # FortiClient imports via FCConfig.exe — path varies by version
        $fcConfig = "${env:ProgramFiles}\Fortinet\FortiClient\FCConfig.exe"
        if (Test-Path $fcConfig) {
            & $fcConfig -m all -f $localProfile -o import -i 1 2>&1 | Out-File -FilePath $LogFile -Append
            Write-Log 'VPN profile imported.'
        } else {
            Write-Log "FCConfig.exe not found at $fcConfig — skipping profile import." 'WARN'
        }
    } catch {
        Write-Log "Profile import failed: $_" 'WARN'
    }
}

# =================================================================
# FINALIZE
# =================================================================
New-Item -ItemType File -Path $MarkerFile -Force | Out-Null
Write-Log "Marker written: $MarkerFile"
Write-Log '=== FortiClient VPN deployment completed ==='
exit 0
