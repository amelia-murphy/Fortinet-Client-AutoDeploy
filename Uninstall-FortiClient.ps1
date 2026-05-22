<#
.SYNOPSIS
    Silently uninstalls FortiClient VPN and removes deployment artifacts.
#>

[CmdletBinding()]
param()

$WorkingDir = 'C:\ProgramData\CompanyName\FortiClientDeploy'
$LogFile    = Join-Path $WorkingDir ("uninstall-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null

function Write-Log { param($m); $l="[$((Get-Date).ToString('s'))] $m"; Add-Content $LogFile $l; Write-Host $l }

Write-Log 'Locating FortiClient uninstall entries...'
$keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$found = foreach ($k in $keys) {
    Get-ItemProperty $k -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'FortiClient*' }
}

if (-not $found) { Write-Log 'No FortiClient installation found.'; exit 0 }

foreach ($pkg in $found) {
    Write-Log "Uninstalling $($pkg.DisplayName) $($pkg.DisplayVersion)"
    if ($pkg.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        $args = @('/x', $pkg.PSChildName, '/qn', '/norestart')
        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
        Write-Log "msiexec exit code: $($p.ExitCode)"
    } else {
        Write-Log "Non-MSI uninstall string: $($pkg.UninstallString) — skipping automated removal." 
    }
}

# Clean up marker files so a re-install can proceed
Get-ChildItem $WorkingDir -Filter 'installed-*.flag' -ErrorAction SilentlyContinue | Remove-Item -Force
Write-Log 'Cleanup complete.'
