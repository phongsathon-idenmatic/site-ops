<#
.SYNOPSIS
Checks host maintenance access. Read-only unless -Repair is supplied; exits 1 on FAIL.
.PARAMETER ConfigPath
Site data file; defaults to site.psd1 beside this script in the installed bin directory.
.PARAMETER Repair
Only restore service startup/running state, enable the managed firewall rule, and enforce
saved external-access intent. Writes watchdog logs; never modifies accounts, SSH config or keys.
.PARAMETER Quiet
Suppress console results. Watchdog logging remains active with -Repair.
.PARAMETER Json
Print an array of id/status/detail results (also with -Quiet).
.EXAMPLE
.\Test-Maintenance.ps1 -ConfigPath .\config\site.psd1 -Json
.EXAMPLE
.\Test-Maintenance.ps1 -Repair -Quiet
#>
[CmdletBinding()]
param([string]$ConfigPath, [switch]$Repair, [switch]$Quiet, [switch]$Json)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\MaintenanceCommon.ps1')
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Repairs = New-Object 'System.Collections.Generic.List[string]'

function Add-Result([string]$Id, [string]$Status, [string]$Detail) {
    $Detail = ($Detail -replace '[\r\n]+', ' ').Trim()
    $script:Results.Add([pscustomobject][ordered]@{ id = $Id; status = $Status; detail = $Detail })
}

function Invoke-Check([string]$Id, [scriptblock]$Action, [string]$ErrorStatus = 'FAIL') {
    try { & $Action } catch { Add-Result $Id $ErrorStatus $_.Exception.Message }
}

function Assert-Check([bool]$Condition, [string]$Detail) {
    if (-not $Condition) { throw $Detail }
}

$config = $null
$desired = $null
Invoke-Check 'elevated' {
    Assert-Check (Test-Elevated) 'Not elevated; run Windows PowerShell as Administrator for complete checks.'
    Add-Result 'elevated' 'PASS' 'Elevated.'
}
Invoke-Check 'os' {
    Assert-Check ([Environment]::OSVersion.Version.Build -ge 17763) 'Requires Windows build 17763 or later.'
    Add-Result 'os' 'PASS' "Windows build $([Environment]::OSVersion.Version.Build)."
}
Invoke-Check 'powershell' {
    Assert-Check ($PSVersionTable.PSVersion -ge [version]'5.1') 'Requires PowerShell 5.1 or later.'
    Assert-Check ([Environment]::Is64BitProcess) 'Use 64-bit PowerShell for local account and system path access.'
    Add-Result 'powershell' 'PASS' "PowerShell $($PSVersionTable.PSVersion), 64-bit."
}
Invoke-Check 'config' {
    $script:config = Read-SiteConfig $ConfigPath $PSScriptRoot
    Add-Result 'config' 'PASS' "Site $($config.SiteCode), role $($config.Role), hostname $($config.Hostname)."
}
Invoke-Check 'desired-state' {
    $script:desired = Get-DesiredState
    Add-Result 'desired-state' 'PASS' "External access $($desired.externalAccess)."
}
Invoke-Check 'maintenance-acl' {
    $root = Get-Item -LiteralPath $script:MaintenanceRoot -Force -ErrorAction Stop
    Assert-Check ($root.PSIsContainer -and -not ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Maintenance root must be a real directory.'
    $acl = Get-Acl -LiteralPath $root.FullName
    Assert-Check $acl.AreAccessRulesProtected 'Maintenance root ACL must not inherit ProgramData permissions.'
    Assert-Check ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Maintenance root owner must be Administrators.'
    $allowed = @('S-1-5-32-544', 'S-1-5-18')
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    Assert-Check (Test-SameSet @($rules | ForEach-Object { $_.IdentityReference.Value }) $allowed) 'Maintenance root must grant only Administrators and SYSTEM.'
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($rule in $rules) {
        Assert-Check ($rule.AccessControlType -eq 'Allow' -and
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
            [Security.AccessControl.FileSystemRights]::FullControl -and
            $rule.InheritanceFlags -eq $inheritance -and $rule.PropagationFlags -eq 'None') 'Maintenance root requires inheritable FullControl for Administrators and SYSTEM.'
    }
    $bin = Get-Item -LiteralPath (Join-Path $root.FullName 'bin') -Force -ErrorAction Stop
    Assert-Check ($bin.PSIsContainer -and -not ($bin.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Installed bin must be a real directory.'
    $items = @($bin) + @(Get-ChildItem -LiteralPath $bin.FullName -Recurse -Force -ErrorAction Stop)
    foreach ($item in $items) {
        Assert-Check (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "Reparse point under bin: $($item.FullName)."
        $itemAcl = Get-Acl -LiteralPath $item.FullName
        $itemRules = @($itemAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-Check (Test-SameSet @($itemRules | ForEach-Object { $_.IdentityReference.Value }) $allowed) "Unexpected or missing SID in bin ACL: $($item.FullName)."
        foreach ($rule in $itemRules) {
            Assert-Check ($rule.AccessControlType -eq 'Allow') "Unexpected deny ACE in bin: $($item.FullName)."
        }
    }
    Add-Result 'maintenance-acl' 'PASS' 'Root protected, owner Administrators, inheritable Administrators + SYSTEM FullControl; bin ACLs contain only these SIDs.'
}

if ($Repair) {
    Invoke-Check 'repair' {
        Assert-Platform
        Assert-Check ($null -ne $config -and $null -ne $desired) 'Repair requires valid config and desired state.'
        if (Set-AutomaticRunning 'sshd') { $script:Repairs.Add('sshd startup/running state restored') }
        $rule = Get-NetFirewallRule -Name $script:MaintenanceRule -ErrorAction Stop
        if ($rule.Enabled -ne 'True') {
            Enable-NetFirewallRule -Name $script:MaintenanceRule
            $script:Repairs.Add('managed firewall rule enabled')
        }
        if (Sync-ExternalAccess $config $desired.externalAccess) {
            $script:Repairs.Add('Configured external paths desired access state restored')
        }
        if ($config.UseCloudflare -and (Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue)) {
            $recovery = $false
            try { $recovery = Test-Recovery $script:CloudflaredService } catch { }
            if (-not $recovery) {
                Invoke-Native 'Cloudflare service recovery' { & sc.exe failure $script:CloudflaredService reset= 86400 actions= restart/5000/restart/5000/restart/30000 } | Out-Null
                $script:Repairs.Add('Cloudflare service recovery restored')
            }
        }
    }
}

Invoke-Check 'account' {
    Assert-Check ($null -ne $config) 'Cannot check account without valid site config.'
    $account = Get-LocalUser -Name $config.MaintenanceAccount -ErrorAction Stop
    Assert-Check $account.Enabled 'Maintenance account is disabled.'
    $members = Get-LocalGroupMember -SID 'S-1-5-32-544'
    Assert-Check (@($members | Where-Object { $_.SID -eq $account.SID }).Count -gt 0) 'Maintenance account is not in Administrators.'
    $registry = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    $hidden = Get-ItemProperty -LiteralPath $registry -Name $account.Name -ErrorAction Stop
    Assert-Check ($hidden.($account.Name) -eq 0) 'Maintenance account is not hidden from sign-in.'
    Add-Result 'account' 'PASS' "$($account.Name) enabled, administrator, hidden from sign-in."
}
Invoke-Check 'openssh' {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    Assert-Check ($capability.State -eq 'Installed') 'OpenSSH Server capability is not installed.'
    Add-Result 'openssh' 'PASS' 'OpenSSH Server capability installed.'
}
Invoke-Check 'sshd-service' {
    $service = Get-Service sshd -ErrorAction Stop
    Assert-Check ($service.Status -eq 'Running' -and $service.StartType -eq 'Automatic') 'sshd must be Running and Automatic.'
    Add-Result 'sshd-service' 'PASS' 'sshd Running and Automatic.'
}
Invoke-Check 'sshd-recovery' {
    Assert-Check (Test-Recovery 'sshd') 'sshd recovery must reset after 86400s and restart after 5s/5s/30s.'
    Add-Result 'sshd-recovery' 'PASS' 'Restart after 5s/5s/30s, reset 86400s.'
}
Invoke-Check 'sshd-config' {
    Assert-Check (Test-Elevated) 'Effective sshd config requires elevation.'
    Assert-Check ($null -ne $config) 'Cannot check AllowUsers without valid site config.'
    $exe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    $effective = Invoke-Native 'Effective SSH configuration' { & $exe -T } | Out-String
    Assert-Check ($effective -match '(?m)^passwordauthentication no\s*$') 'Effective PasswordAuthentication must be no.'
    Assert-Check ($effective -match '(?m)^pubkeyauthentication yes\s*$') 'Effective PubkeyAuthentication must be yes.'
    $allowed = [regex]::Matches($effective, '(?m)^allowusers\s+(.+)$')
    $users = @($allowed | ForEach-Object { $_.Groups[1].Value.Trim() -split '\s+' })
    Assert-Check ($config.MaintenanceAccount -cin $users) 'Effective AllowUsers must contain maintenance account.'
    Add-Result 'sshd-config' 'PASS' 'Public-key authentication enabled, passwords disabled, maintenance account allowed.'
}
Invoke-Check 'authorized-keys' {
    $path = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $keys = @(Get-EngineerKeys $path)
    $acl = Get-Acl -LiteralPath $path
    Assert-Check $acl.AreAccessRulesProtected 'Public key ACL must not inherit permissions.'
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $sids = @($rules | ForEach-Object { $_.IdentityReference.Value })
    Assert-Check (Test-SameSet $sids @('S-1-5-32-544', 'S-1-5-18')) 'Public key ACL must contain only Administrators and SYSTEM.'
    foreach ($rule in $rules) {
        Assert-Check ($rule.AccessControlType -eq 'Allow' -and
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
            [Security.AccessControl.FileSystemRights]::FullControl) 'Administrators and SYSTEM must have full control.'
    }
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    Assert-Check ($owner -in @('S-1-5-32-544', 'S-1-5-18')) 'Public key owner must be Administrators or SYSTEM.'
    $comments = @($keys | ForEach-Object { ($_ -split '\s+', 3)[2] }) -join ', '
    Add-Result 'authorized-keys' 'PASS' "$($keys.Count) key(s): $comments; ACL Administrators + SYSTEM only."
}
Invoke-Check 'firewall' {
    Assert-Check ($null -ne $config) 'Cannot check firewall scope without valid config.'
    $rule = Get-NetFirewallRule -Name $script:MaintenanceRule -ErrorAction Stop
    $port = $rule | Get-NetFirewallPortFilter
    $address = $rule | Get-NetFirewallAddressFilter
    Assert-Check ($rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and
        $rule.Action -eq 'Allow' -and $rule.Profile -eq 'Any') 'Managed firewall rule must allow inbound traffic on all profiles and be enabled.'
    Assert-Check ($port.Protocol -in @('TCP', '6') -and $port.LocalPort -eq '22') 'Managed firewall rule must scope TCP port 22.'
    Assert-Check (Test-SameSet $address.RemoteAddress (Get-ExpectedAddresses $config)) 'Managed firewall RemoteAddress differs from tailnet + configured LAN networks.'
    Add-Result 'firewall' 'PASS' "TCP 22 scoped to $($address.RemoteAddress -join ', ')."
}
Invoke-Check 'stock-firewall' {
    $stock = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($stock -and $stock.Enabled -eq 'True') { Add-Result 'stock-firewall' 'WARN' 'Stock OpenSSH firewall rule is enabled (broad SSH access).' }
    else { Add-Result 'stock-firewall' 'PASS' 'Stock broad OpenSSH firewall rule disabled or absent.' }
} 'WARN'
Invoke-Check 'port22' {
    $listeners = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction Stop)
    Assert-Check ($listeners.Count -gt 0) 'No TCP port 22 listener.'
    Add-Result 'port22' 'PASS' "Port 22 listening on $($listeners.LocalAddress -join ', ')."
}

if ($config.UseTailscale) {
$tailscale = $null
Invoke-Check 'tailscale-installed' {
    try { $script:tailscale = Get-TailscalePath } catch {
        if ($desired -and $desired.externalAccess -eq 'disabled') {
            Add-Result 'tailscale-installed' 'WARN' 'Tailscale absent; desired access disabled (LAN-only).'
            return
        }
        throw
    }
    $version = Invoke-Native 'Tailscale version' { & $tailscale version } | Out-String
    Add-Result 'tailscale-installed' 'PASS' $version
}
Invoke-Check 'tailscale-service' {
    Assert-Check ($null -ne $desired) 'Cannot check Tailscale service without valid desired state.'
    $service = Get-Service Tailscale -ErrorAction SilentlyContinue
    if (-not $service -and $desired.externalAccess -eq 'disabled') {
        Add-Result 'tailscale-service' 'WARN' 'Tailscale service absent; LAN-only mode.'
    } else {
        Assert-Check ($null -ne $service) 'Tailscale service missing.'
        if ($desired.externalAccess -eq 'disabled') {
            Assert-Check ($service.Status -eq 'Stopped' -and $service.StartType -eq 'Disabled') 'Disabled access requires Tailscale Stopped and Disabled.'
        } else {
            Assert-Check ($service.Status -eq 'Running' -and $service.StartType -eq 'Automatic') 'Enabled access requires Tailscale Running and Automatic.'
        }
        Add-Result 'tailscale-service' 'PASS' "Tailscale $($service.Status), $($service.StartType); matches $($desired.externalAccess)."
    }
}
if ($desired -and $desired.externalAccess -eq 'enabled') {
    $tailStatus = $null
    Invoke-Check 'tailscale-status' {
        Assert-Check ($null -ne $tailscale) 'Tailscale executable missing.'
        $script:tailStatus = Invoke-Native 'Tailscale status' { & $tailscale status --json } | Out-String | ConvertFrom-Json
        Assert-Check ($tailStatus.BackendState -eq 'Running') "Tailscale BackendState: $($tailStatus.BackendState)."
        Assert-Check ([bool]$tailStatus.Self.Online) 'Tailscale node is offline.'
        Assert-Check ($null -ne $config) 'Cannot check hostname and tag without valid config.'
        Assert-Check ($tailStatus.Self.HostName -ceq $config.Hostname) 'Tailscale hostname differs from config.'
        Assert-Check ($config.TailscaleTag -cin @($tailStatus.Self.Tags)) "Node missing required tag $($config.TailscaleTag)."
        Add-Result 'tailscale-status' 'PASS' 'Running, online, hostname and tag match config.'
    }
    Invoke-Check 'tailscale-expiry' {
        Assert-Check ($null -ne $tailStatus) 'Tailscale status unavailable; key expiry UNKNOWN.'
        $expiry = $tailStatus.Self.KeyExpiry
        if ($expiry -and "$expiry" -ne '0' -and "$expiry" -notmatch '^0001-01-01T00:00:00') {
            Add-Result 'tailscale-expiry' 'WARN' "Node key expires: $expiry."
        } else { Add-Result 'tailscale-expiry' 'PASS' 'Node key expiry disabled.' }
    } 'WARN'
    Invoke-Check 'tailscale-unattended' {
        Assert-Check ($null -ne $tailscale) 'Tailscale executable missing; unattended preference UNKNOWN.'
        $prefs = Invoke-Native 'Tailscale debug prefs' { & $tailscale debug prefs } | Out-String | ConvertFrom-Json
        if ($null -eq $prefs.ForceDaemon) { Add-Result 'tailscale-unattended' 'WARN' 'ForceDaemon preference unavailable.' }
        elseif (-not $prefs.ForceDaemon) { Add-Result 'tailscale-unattended' 'FAIL' 'Unattended preference ForceDaemon is false.' }
        else { Add-Result 'tailscale-unattended' 'PASS' 'Unattended preference ForceDaemon true.' }
    } 'WARN'
}

}

if ($config.UseCloudflare) {
    Invoke-Check 'cloudflared-installed' {
        if (-not (Test-Path -LiteralPath $script:CloudflaredExe) -and $desired -and $desired.externalAccess -eq 'disabled') {
            Add-Result 'cloudflared-installed' 'WARN' 'cloudflared absent; desired access disabled (LAN-only).'
            return
        }
        Assert-Check (Test-Path -LiteralPath $script:CloudflaredExe) 'cloudflared executable missing.'
        $signature = Get-AuthenticodeSignature -LiteralPath $script:CloudflaredExe
        Assert-Check ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -like '*CN="Cloudflare, Inc."*') 'cloudflared must have a valid Cloudflare, Inc. signature.'
        $version = Invoke-Native 'Cloudflare version' { & $script:CloudflaredExe --version } | Out-String
        Assert-Check ($version -match 'cloudflared version (\d+)\.(\d+)\.(\d+)') 'cloudflared version unavailable.'
        Assert-Check ([version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -ge [version]'2025.4.0') 'cloudflared version must be 2025.4.0 or later.'
        Add-Result 'cloudflared-installed' 'PASS' $version
    }
    Invoke-Check 'cloudflared-token' {
        $file = Get-Item -LiteralPath $script:CloudflaredTokenFile -Force -ErrorAction Stop
        Assert-Check (-not $file.PSIsContainer -and $file.Length -gt 0 -and
            -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Cloudflare token must be a non-empty regular file.'
        $acl = Get-Acl -LiteralPath $script:CloudflaredTokenFile
        Assert-Check $acl.AreAccessRulesProtected 'Cloudflare token ACL must not inherit permissions.'
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $sids = @($rules | ForEach-Object { $_.IdentityReference.Value })
        Assert-Check (Test-SameSet $sids @('S-1-5-32-544', 'S-1-5-18')) 'Cloudflare token ACL must contain only Administrators and SYSTEM.'
        foreach ($rule in $rules) {
            Assert-Check ($rule.AccessControlType -eq 'Allow' -and
                ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl) 'Administrators and SYSTEM must have full control of the Cloudflare token.'
        }
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Assert-Check ($owner -in @('S-1-5-32-544', 'S-1-5-18')) 'Cloudflare token owner must be Administrators or SYSTEM.'
        Add-Result 'cloudflared-token' 'PASS' 'Non-empty token file; protected ACL Administrators + SYSTEM only.'
    }
    Invoke-Check 'cloudflared-service' {
        Assert-Check ($null -ne $desired) 'Cannot check Cloudflare service without valid desired state.'
        $service = Get-Service $script:CloudflaredService -ErrorAction Stop
        if ($desired.externalAccess -eq 'disabled') {
            Assert-Check ($service.Status -eq 'Stopped' -and $service.StartType -eq 'Disabled') 'Disabled access requires Cloudflare Stopped and Disabled.'
        } else {
            Assert-Check ($service.Status -eq 'Running' -and $service.StartType -eq 'Automatic') 'Enabled access requires Cloudflare Running and Automatic.'
        }
        $binPath = '"' + $script:CloudflaredExe + '" tunnel --metrics ' + $script:CloudflaredMetrics +
            ' run --token-file "' + $script:CloudflaredTokenFile + '"'
        $image = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$script:CloudflaredService" -Name ImagePath).ImagePath
        Assert-Check ($image.Trim() -ieq $binPath.Trim()) 'Cloudflare service ImagePath differs from expected command.'
        Add-Result 'cloudflared-service' 'PASS' "Cloudflare $($service.Status), $($service.StartType); command and desired state match."
    }
    Invoke-Check 'cloudflared-recovery' {
        Assert-Check (Test-Recovery $script:CloudflaredService) 'Cloudflare recovery must reset after 86400s and restart after 5s/5s/30s.'
        Add-Result 'cloudflared-recovery' 'PASS' 'Restart after 5s/5s/30s, reset 86400s.'
    }
    if ($desired -and $desired.externalAccess -eq 'enabled') {
        Invoke-Check 'cloudflared-ready' {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://$script:CloudflaredMetrics/ready"
                $ready = $response.Content | ConvertFrom-Json
            } catch {
                throw "tunnel not connected to Cloudflare edge: $($_.Exception.Message)"
            }
            Assert-Check ($response.StatusCode -eq 200 -and $ready.readyConnections -gt 0) "tunnel not connected to Cloudflare edge (HTTP $($response.StatusCode))."
            Add-Result 'cloudflared-ready' 'PASS' "Cloudflare edge readyConnections: $($ready.readyConnections)."
        }
    }
}

Invoke-Check 'watchdog' {
    $task = Get-ScheduledTask -TaskName $script:MaintenanceTask -TaskPath $script:MaintenanceTaskPath -ErrorAction Stop
    Assert-Check $task.Settings.Enabled 'Watchdog task is disabled.'
    Assert-Check ($task.Principal.UserId -in @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM')) 'Watchdog must run as SYSTEM.'
    $action = @($task.Actions)[0]
    $binTest = Join-Path $script:MaintenanceRoot 'bin\Test-Maintenance.ps1'
    Assert-Check ($action.Execute -like '*\powershell.exe' -and $action.Arguments -like "*$binTest*" -and
        $action.Arguments -match '\s-Repair(\s|$)' -and $action.Arguments -match '\s-Quiet(\s|$)') 'Watchdog action does not run installed Test-Maintenance.ps1 -Repair -Quiet.'
    Add-Result 'watchdog' 'PASS' 'Watchdog registered, enabled, SYSTEM; installed verifier action.'
    $info = Get-ScheduledTaskInfo -TaskName $script:MaintenanceTask -TaskPath $script:MaintenanceTaskPath
    if ($info.LastTaskResult -ne 0) { Add-Result 'watchdog-last-result' 'WARN' "Last task result: $($info.LastTaskResult)." }
    else { Add-Result 'watchdog-last-result' 'PASS' 'Last task result 0.' }
}
Invoke-Check 'power-standby' {
    $output = Invoke-Native 'AC standby query' { & powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE } | Out-String
    $indices = [regex]::Matches($output, '0x[0-9a-fA-F]{8}')
    Assert-Check ($indices.Count -ge 2) 'AC standby index UNKNOWN.'
    $seconds = [Convert]::ToUInt32($indices[$indices.Count - 2].Value.Substring(2), 16)
    Assert-Check ($seconds -eq 0) "AC standby timeout is $seconds seconds; expected 0."
    Add-Result 'power-standby' 'PASS' 'AC standby disabled.'
} 'WARN'
Invoke-Check 'power-hibernate' {
    Assert-Check (-not (Test-HibernationEnabled)) 'Hibernation enabled.'
    Add-Result 'power-hibernate' 'PASS' 'Hibernation disabled; BIOS power-on after AC loss requires an on-site check (UNKNOWN).'
} 'WARN'
Invoke-Check 'time' {
    $output = Invoke-Native 'Windows time status' { & w32tm.exe /query /status } | Out-String
    # Keep the source and last-sync text intact on localized Windows installations.
    Assert-Check (-not [string]::IsNullOrWhiteSpace($output)) 'Time source and last sync UNKNOWN.'
    $warning = $output -match 'Local CMOS Clock|Free-running System Clock|Stratum:\s*0|Last Successful Sync Time:\s*unspecified'
    if ($warning) { Add-Result 'time' 'WARN' $output }
    else { Add-Result 'time' 'PASS' $output }
} 'WARN'
Invoke-Check 'disk' {
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    Assert-Check ($null -ne $drive -and $null -ne $drive.FreeSpace) 'System-drive free space UNKNOWN.'
    $gb = [math]::Round($drive.FreeSpace / 1GB, 2)
    Assert-Check ($drive.FreeSpace -ge 5GB) "Only $gb GB free on $env:SystemDrive (minimum 5 GB)."
    Add-Result 'disk' 'PASS' "$gb GB free on $env:SystemDrive."
} 'WARN'
Invoke-Check 'version' {
    $installed = (Get-Content -LiteralPath (Join-Path $script:MaintenanceRoot 'bin\VERSION') -Raw).Trim()
    Assert-Check ($installed -eq $script:MaintenanceVersion) "Version drift: running $script:MaintenanceVersion, installed $installed."
    Add-Result 'version' 'PASS' "Running and installed version $installed."
} 'WARN'

if ($Repair) {
    Invoke-Check 'watchdog-log' {
        Assert-Check (Test-Elevated) 'Watchdog log writes require elevation.'
        $directory = Join-Path $script:MaintenanceRoot 'logs'
        $issues = @($script:Results | Where-Object { $_.status -eq 'FAIL' })
        if ($issues.Count -gt 0 -or $script:Repairs.Count -gt 0) {
            $entry = [ordered]@{ when = [DateTime]::UtcNow.ToString('o'); repairs = @($script:Repairs.ToArray())
                failures = @($issues | ForEach-Object { "$($_.id): $($_.detail)" }) }
            $path = Join-Path $directory ("watchdog-$([DateTime]::Now.ToString('yyyyMM')).log")
            $entry | ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $path -Encoding UTF8
        }
        Get-ChildItem -LiteralPath $directory -Filter 'watchdog-??????.log' -File | ForEach-Object {
            if ($_.BaseName -match '^watchdog-(\d{6})$') {
                $month = [datetime]::MinValue
                if ([datetime]::TryParseExact($Matches[1], 'yyyyMM', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$month) -and
                    $month -lt (Get-Date -Day 1).Date.AddMonths(-12)) { Remove-Item -LiteralPath $_.FullName -Force }
            }
        }
    }
}
if ($Json) { ConvertTo-Json -InputObject @($script:Results.ToArray()) -Depth 4 }
elseif (-not $Quiet) {
    foreach ($result in $script:Results) { Write-Output "$($result.status) $($result.id): $($result.detail)" }
}
if (@($script:Results | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { exit 1 }
exit 0
