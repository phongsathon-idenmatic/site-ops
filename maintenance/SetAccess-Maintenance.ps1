<#
.SYNOPSIS
Controls external access, retaining SSH over LAN. Status is read-only.
.PARAMETER State
Enabled starts the configured external paths (Cloudflare tunnel, Tailscale); Disabled stops them;
LAN SSH stays. Status reports without changing state.
.PARAMETER ConfigPath
Site config; defaults to site.psd1 beside this script in the installed bin directory.
.PARAMETER Reason
Reason recorded with identity and SSH origin in the access audit log.
.PARAMETER AuthKey
Tailscale-only SecureString required if enabling a logged-out node.
.PARAMETER Force
Allow disabling from a tailnet or loopback (Cloudflare) SSH client, cutting that session.
.EXAMPLE
.\SetAccess-Maintenance.ps1 -State Status
.EXAMPLE
.\SetAccess-Maintenance.ps1 -State Disabled -Reason 'Site accepted'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Enabled', 'Disabled', 'Status')][string]$State,
    [string]$ConfigPath,
    [string]$Reason = '',
    [Security.SecureString]$AuthKey,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\MaintenanceCommon.ps1')
try {
    if ($State -eq 'Status') {
        Write-Host '==> External maintenance access status'
        $desired = Get-DesiredState
        $config = $null
        $site = $ConfigPath
        if (-not $site) { $site = Join-Path $PSScriptRoot 'site.psd1' }
        if (Test-Path -LiteralPath $site) { $config = Read-SiteConfig $site $PSScriptRoot }
        $service = $null
        $cloudService = $null
        if ($config.UseTailscale) { $service = Get-Service Tailscale -ErrorAction SilentlyContinue }
        if ($config.UseCloudflare) { $cloudService = Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue }
        $status = [ordered]@{ Desired = $desired.externalAccess; ChangedAt = $desired.changedAt
            ChangedBy = $desired.changedBy; Reason = $desired.reason
            ServiceStatus = $service.Status; StartupType = $service.StartType
            CloudflareServiceStatus = $cloudService.Status; CloudflareStartupType = $cloudService.StartType }
        if ($config.UseCloudflare) { $status.CloudflareHostname = $config.CloudflareHostname }
        [pscustomobject]$status
        exit 0
    }
    Assert-Platform
    $config = Read-SiteConfig $ConfigPath $PSScriptRoot
    $tailnetSession = $env:SSH_CLIENT -like '100.*' -or $env:SSH_CLIENT -like 'fd7a:115c:a1e0:*'
    $externalSession = $tailnetSession -or $env:SSH_CLIENT -like '127.0.0.1 *' -or $env:SSH_CLIENT -like '::1 *'
    if ($State -eq 'Disabled' -and $externalSession -and -not $Force) {
        throw 'Disabling external access will cut this tailnet or loopback (Cloudflare) SSH session. Use -Force from this session or use a local/LAN console.'
    }
    Write-Host '==> External maintenance access'
    if ($State -eq 'Disabled') { Write-Host 'Configured external paths will stop and be disabled. LAN SSH stays available.' }
    else { Write-Host 'Configured external paths will start automatically and reconnect.' }
    $desired = Get-DesiredState
    $changed = $desired.externalAccess -ne $State.ToLowerInvariant()
    # Persist intent before network changes so the watchdog can finish after a disconnect.
    if ($changed) { Write-DesiredState $State $Reason }
    $log = Join-Path $script:MaintenanceRoot 'logs\access-changes.log'
    $record = [ordered]@{ when = [DateTime]::UtcNow.ToString('o'); who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        from = $env:SSH_CLIENT; state = $State; reason = $Reason; result = 'requested' }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $log -Encoding UTF8
    try {
        if (Sync-ExternalAccess $config $State.ToLowerInvariant() $AuthKey) { $changed = $true }
        $record.result = 'applied'
    } catch {
        $record.result = 'failed; desired state retained for watchdog'
        throw
    } finally { $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $log -Encoding UTF8 }
    if ($changed) { Write-Host 'changed' } else { Write-Host 'ok' }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
