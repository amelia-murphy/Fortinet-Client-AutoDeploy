<#
.SYNOPSIS
    Registers a one-shot scheduled task that runs Install-FortiClient.ps1 at boot under SYSTEM.

.DESCRIPTION
    Run this ONCE on each target machine (via Intune script, SCCM package, or
    manual provisioning). It creates a scheduled task named
    "Deploy-FortiClientVPN" that triggers at next boot, runs as SYSTEM, and
    invokes the main install script. The install script is idempotent — once
    the marker file is written, subsequent runs exit immediately.
#>

[CmdletBinding()]
param(
    [string]$InstallScriptPath = "$PSScriptRoot\Install-FortiClient.ps1",
    [string]$TaskName          = 'Deploy-FortiClientVPN'
)

# Must be admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Must run as administrator.'
    exit 1
}

if (-not (Test-Path $InstallScriptPath)) {
    Write-Error "Install script not found: $InstallScriptPath"
    exit 1
}

# Stage the install script to a stable local path so the task survives
# even if the source folder is deleted
$stagingDir = 'C:\ProgramData\CompanyName\FortiClientDeploy'
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
$stagedScript = Join-Path $stagingDir 'Install-FortiClient.ps1'
Copy-Item -Path $InstallScriptPath -Destination $stagedScript -Force

Write-Host "Staged install script at: $stagedScript"

# Remove existing task if present
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task: $TaskName"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$stagedScript`""

# Trigger: at startup, with a 2-minute delay so networking is up
$trigger   = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT2M'

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'One-shot deployment of FortiClient VPN. Idempotent; safe to re-trigger.'

Write-Host "Scheduled task '$TaskName' registered. Will fire 2 minutes after next boot."
Write-Host "To run it now without rebooting:  Start-ScheduledTask -TaskName '$TaskName'"
