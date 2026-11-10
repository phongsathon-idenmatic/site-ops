<#
.SYNOPSIS
Installs host maintenance access. Changes accounts, SSH, firewall, power and watchdog.
.PARAMETER ConfigPath
Site data file. Required except when using the installed bin\site.psd1 copy.
.PARAMETER AuthKey
One-time pre-tagged Tailscale key, as SecureString. Prompted only when login is needed.
.PARAMETER TailscaleMsi
Optional local signed Tailscale MSI; otherwise downloaded from the stable channel.
.PARAMETER SkipTailscale
Skip Tailscale; external access is disabled when no configured provider is active.
.PARAMETER TunnelToken
Cloudflare tunnel token for this machine, as SecureString. Prompted only if no token file exists.
Supply again to rotate the stored token and restart the service.
.PARAMETER CloudflaredExe
Optional local signed cloudflared executable; otherwise downloaded. Re-run Install to update it.
.PARAMETER SkipCloudflare
Skip Cloudflare; external access is disabled when no configured provider is active.
.PARAMETER Only
Keys replaces only the administrator public keys and their ACL.
.EXAMPLE
.\Install-Maintenance.ps1 -ConfigPath .\config\site.psd1
.EXAMPLE
.\Install-Maintenance.ps1 -ConfigPath .\config\site.psd1 -Only Keys
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Security.SecureString]$AuthKey,
    [string]$TailscaleMsi,
    [switch]$SkipTailscale,
    [Security.SecureString]$TunnelToken,
    [string]$CloudflaredExe,
    [switch]$SkipCloudflare,
    [ValidateSet('All', 'Keys')][string]$Only = 'All'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\MaintenanceCommon.ps1')

function Invoke-Step([string]$Name, [scriptblock]$Action) {
    Write-Host "==> $Name"
    $result = & $Action
    if ($result) { Write-Host 'changed' } else { Write-Host 'ok' }
}

function Protect-MaintenanceRoot {
    $owner = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $changed = $false
    if (-not (Test-Path -LiteralPath $script:MaintenanceRoot)) {
        # Supply the ACL at creation so there is no writable interval before protection.
        [IO.Directory]::CreateDirectory($script:MaintenanceRoot, $acl) | Out-Null
        $changed = $true
    }
    $root = Get-Item -LiteralPath $script:MaintenanceRoot -Force
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Maintenance root must be a real directory, not a reparse point.'
    }
    $rootAcl = Get-Acl -LiteralPath $root.FullName
    $rootRules = @($rootAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $rootCorrect = $rootAcl.AreAccessRulesProtected -and $rootRules.Count -eq 2 -and
        $rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $owner.Value
    $sids = @($rootRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    if ($sids.Count -ne 2 -or 'S-1-5-32-544' -notin $sids -or 'S-1-5-18' -notin $sids) { $rootCorrect = $false }
    foreach ($rule in $rootRules) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl' -or
            $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' -or
            $rule.PropagationFlags -ne 'None') { $rootCorrect = $false }
    }
    if (-not $rootCorrect) {
        Set-Acl -LiteralPath $root.FullName -AclObject $acl
        $changed = $true
    }
    $children = @(Get-ChildItem -LiteralPath $root.FullName -Recurse -Force -ErrorAction Stop)
    if (@($children | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw 'Remove reparse points from the maintenance tree before installing.'
    }
    # Upgrade existing installs too: remove explicit grants and restore parent inheritance.
    foreach ($child in ($children | Sort-Object { $_.FullName.Length })) {
        $childAcl = Get-Acl -LiteralPath $child.FullName
        $before = $childAcl.Sddl
        $childAcl.SetOwner($owner)
        $childAcl.SetAccessRuleProtection($false, $false)
        foreach ($rule in @($childAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
            $childAcl.RemoveAccessRuleSpecific($rule)
        }
        if ($before -cne $childAcl.Sddl) {
            Set-Acl -LiteralPath $child.FullName -AclObject $childAcl
            $changed = $true
        }
    }
    return $changed
}

function Copy-LayerFile([string]$Source, [string]$Destination) {
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ($sourcePath -eq $destinationPath) {
        Write-Host "skipped (source is installed destination: $destinationPath)"
        return $false
    }
    if ((Test-Path -LiteralPath $destinationPath) -and
        (Get-FileHash -LiteralPath $sourcePath).Hash -eq (Get-FileHash -LiteralPath $destinationPath).Hash) {
        return $false
    }
    $parent = Split-Path $destinationPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    return $true
}

function Register-SshdRestart {
    $taskName = 'VMS-Maintenance-SshdRestart'
    $command = @'
$ErrorActionPreference = 'Stop'
try { Restart-Service -Name sshd -ErrorAction Stop }
finally { Unregister-ScheduledTask -TaskPath '\IDENMATIC\' -TaskName 'VMS-Maintenance-SshdRestart' -Confirm:$false }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    # try { $scheduler.GetFolder($script:MaintenanceTaskPath) | Out-Null }
    try { $scheduler.GetFolder($script:MaintenanceTaskPath.TrimEnd('\')) | Out-Null }
    catch { $scheduler.GetFolder('\').CreateFolder('IDENMATIC') | Out-Null }
    Register-ScheduledTask -TaskName $taskName -TaskPath $script:MaintenanceTaskPath -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host 'sshd restart scheduled in ~30s; reconnect afterwards'
}

$script:sshRestartPending = $false
$exitCode = 1
try {
    Write-Host '==> Preflight'
    Assert-Platform
    $config = Read-SiteConfig $ConfigPath $PSScriptRoot
    # Skip switches affect this invocation, not the configured providers or saved config.
    $installConfig = $config.Clone()
    $installConfig.UseTailscale = $config.UseTailscale -and -not $SkipTailscale
    $installConfig.UseCloudflare = $config.UseCloudflare -and -not $SkipCloudflare
    $providerActive = $installConfig.UseTailscale -or $installConfig.UseCloudflare
    $keys = @(Get-EngineerKeys $config.AuthorizedKeysFile)
    $sshDirectory = Join-Path $env:ProgramData 'ssh'
    $sshd = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    if ($Only -eq 'All') {
        foreach ($file in @('templates\sshd_config', 'Test-Maintenance.ps1', 'SetAccess-Maintenance.ps1', 'lib\MaintenanceCommon.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing install source: $file." }
        }
    } elseif (-not (Test-Path -LiteralPath $sshDirectory)) { throw 'OpenSSH must be installed before -Only Keys.' }
    Write-Host 'ok'

    Invoke-Step 'Protected maintenance root and inherited child ACLs' { Protect-MaintenanceRoot }

    if ($Only -eq 'All') {
        Invoke-Step 'OpenSSH Server capability' {
            $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
            if ($capability.State -ne 'Installed') {
                Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
                $true
            }
        }
        Invoke-Step 'Maintenance account' {
            $changed = $false
            $account = Get-LocalUser -Name $config.MaintenanceAccount -ErrorAction SilentlyContinue
            if (-not $account) {
                $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                try {
                    $buffer = New-Object byte[] 32
                    $rng.GetBytes($buffer)
                    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%*-_'
                    $password = 'Aa7!' + (-join ($buffer[0..27] | ForEach-Object { $alphabet[[int]$_ % $alphabet.Length] }))
                    $secure = ConvertTo-SecureString $password -AsPlainText -Force
                    $account = New-LocalUser -Name $config.MaintenanceAccount -Password $secure -PasswordNeverExpires
                    Write-Host "Store in the company vault now. $($config.MaintenanceAccount) password (shown once): $password"
                } finally {
                    $password = $null
                    if ($secure) { $secure.Dispose() }
                    $rng.Dispose()
                }
                $changed = $true
            }
            if (-not $account.Enabled) { Enable-LocalUser -Name $account.Name; $changed = $true }
            if (-not $account.PasswordNeverExpires) {
                # LocalUser does not expose PasswordNeverExpires consistently; inspect the local SAM flag.
                $sam = [ADSI]("WinNT://$env:COMPUTERNAME/$($account.Name),user")
                if (([int]$sam.UserFlags.Value -band 0x10000) -eq 0) {
                    Set-LocalUser -Name $account.Name -PasswordNeverExpires $true
                    $changed = $true
                }
            }
            $group = Get-LocalGroup -SID 'S-1-5-32-544'
            if (-not (Get-LocalGroupMember -Group $group | Where-Object { $_.SID -eq $account.SID })) {
                Add-LocalGroupMember -Group $group -Member $account
                $changed = $true
            }
            $userList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
            if (-not (Test-Path $userList)) { New-Item $userList -Force | Out-Null }
            $hidden = Get-ItemProperty -LiteralPath $userList -Name $account.Name -ErrorAction SilentlyContinue
            if (-not $hidden -or $hidden.($account.Name) -ne 0) {
                New-ItemProperty -LiteralPath $userList -Name $account.Name -Value 0 -PropertyType DWord -Force | Out-Null
                $changed = $true
            }
            $changed
        }
    }

    Invoke-Step 'Administrator public keys and ACL' {
        if (-not (Test-Path -LiteralPath $sshDirectory)) { New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null }
        $path = Join-Path $sshDirectory 'administrators_authorized_keys'
        $text = ($keys -join "`r`n") + "`r`n"
        $changed = -not (Test-Path -LiteralPath $path)
        if (-not $changed) { $changed = [IO.File]::ReadAllText($path) -cne $text }
        if ($changed) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }
        $before = (Get-Acl -LiteralPath $path).Sddl
        Set-PrivateAcl $path
        $changed -or $before -ne (Get-Acl -LiteralPath $path).Sddl
    }
    if ($Only -eq 'Keys') { exit 0 }

    $script:sshConfigChanged = $false
    Invoke-Step 'Validated sshd_config and PowerShell default shell' {
        $changed = $false
        $target = Join-Path $sshDirectory 'sshd_config'
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\sshd_config')).Replace(
            '{{MAINTENANCE_ACCOUNT}}', $config.MaintenanceAccount)
        if (-not (Test-Path -LiteralPath $target) -or [IO.File]::ReadAllText($target) -cne $text) {
            $candidate = "$target.$([guid]::NewGuid().ToString('N')).tmp"
            try {
                [IO.File]::WriteAllText($candidate, $text, (New-Object Text.UTF8Encoding($false)))
                # sshd -t requires host keys even before the first service start.
                $keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
                Invoke-Native 'Ensure SSH host keys' { & $keygen -A } | Out-Null
                Invoke-Native 'Validate sshd_config' { & $sshd -t -f $candidate } | Out-Null
                $backup = Join-Path $sshDirectory 'sshd_config.pre-vms-maint'
                if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $backup)) {
                    Copy-Item -LiteralPath $target -Destination $backup
                }
                Move-Item -LiteralPath $candidate -Destination $target -Force
                $script:sshConfigChanged = $true
                if ($env:SSH_CLIENT) { $script:sshRestartPending = $true }
                $changed = $true
            } finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force } }
        }
        $registry = 'HKLM:\SOFTWARE\OpenSSH'
        $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $registry)) { New-Item $registry -Force | Out-Null }
        if ((Get-ItemProperty $registry -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell -ne $shell) {
            New-ItemProperty $registry -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
            $changed = $true
        }
        $changed
    }
    Invoke-Step 'SSH service and recovery' {
        $service = Get-Service sshd
        $wasRunning = $service.Status -eq 'Running'
        $changed = Set-AutomaticRunning 'sshd'
        if ($script:sshConfigChanged -and $wasRunning -and -not $env:SSH_CLIENT) {
            Restart-Service sshd
            $changed = $true
        }
        $recovery = $false
        try { $recovery = Test-Recovery 'sshd' } catch { }
        if (-not $recovery) {
            Invoke-Native 'SSH service recovery' { & sc.exe failure sshd reset= 86400 actions= restart/5000/restart/5000/restart/30000 } | Out-Null
            $changed = $true
        }
        $changed
    }
    Invoke-Step 'Scoped SSH firewall' {
        $changed = $false
        $stock = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        if ($stock -and $stock.Enabled -ne 'False') { $stock | Disable-NetFirewallRule; $changed = $true }
        $rule = Get-NetFirewallRule -Name $script:MaintenanceRule -ErrorAction SilentlyContinue
        $addresses = Get-ExpectedAddresses $config
        if (-not $rule) {
            New-NetFirewallRule -Name $script:MaintenanceRule -DisplayName 'VMS maintenance SSH' -Direction Inbound `
                -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress $addresses | Out-Null
            $changed = $true
        } else {
            $port = $rule | Get-NetFirewallPortFilter
            $remote = $rule | Get-NetFirewallAddressFilter
            if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or
                $rule.Profile -ne 'Any' -or $port.Protocol -notin @('TCP', '6') -or $port.LocalPort -ne '22' -or
                -not (Test-SameSet $remote.RemoteAddress $addresses)) {
                Set-NetFirewallRule -Name $script:MaintenanceRule -Enabled True -Direction Inbound -Action Allow `
                    -Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress $addresses
                $changed = $true
            }
        }
        $changed
    }
    Invoke-Step 'AC standby and hibernation' {
        $changed = $false
        $power = Invoke-Native 'Query standby' { & powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE } | Out-String
        $indices = [regex]::Matches($power, '0x[0-9a-fA-F]{8}')
        if ($indices.Count -lt 2) { throw 'Cannot determine AC standby timeout.' }
        if ([Convert]::ToUInt32($indices[$indices.Count - 2].Value.Substring(2), 16) -ne 0) {
            Invoke-Native 'Disable AC standby' { & powercfg.exe /change standby-timeout-ac 0 } | Out-Null
            $changed = $true
        }
        if (Test-HibernationEnabled) { Invoke-Native 'Disable hibernation' { & powercfg.exe /hibernate off } | Out-Null; $changed = $true }
        $changed
    }
    Invoke-Step 'Installed maintenance layer, resolved config and desired state' {
        $changed = $false
        $bin = Join-Path $script:MaintenanceRoot 'bin'
        foreach ($directory in @($bin, (Join-Path $bin 'lib'), (Join-Path $script:MaintenanceRoot 'logs'))) {
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null; $changed = $true }
        }
        $layerFiles = @('Install-Maintenance.ps1', 'Test-Maintenance.ps1', 'SetAccess-Maintenance.ps1')
        foreach ($folder in @('lib', 'templates')) {
            $layerFiles += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Recurse -File | ForEach-Object {
                $_.FullName.Substring($PSScriptRoot.TrimEnd('\').Length + 1)
            })
        }
        foreach ($relative in $layerFiles) {
            $source = Join-Path $PSScriptRoot $relative
            $destination = Join-Path $bin $relative
            if (Copy-LayerFile $source $destination) { $changed = $true }
        }
        if (Copy-LayerFile $config.AuthorizedKeysFile (Join-Path $bin 'keys\engineers.pub')) { $changed = $true }
        $lines = @('@{')
        foreach ($name in @('SiteCode', 'Role', 'MaintenanceAccount', 'CloudflareHostname', 'TailscaleTag')) {
            if (-not $config.ContainsKey($name)) { continue }
            $lines += "    $name = '$($config[$name].Replace("'", "''"))'"
        }
        $lines += "    AuthorizedKeysFile = 'keys\engineers.pub'"
        $lines += '    LanSubnets = @(' + (($config.LanSubnets | ForEach-Object { "'$_'" }) -join ', ') + ')'
        $lines += '}'
        $configText = ($lines -join "`r`n") + "`r`n"
        $site = Join-Path $bin 'site.psd1'
        if (-not (Test-Path -LiteralPath $site) -or [IO.File]::ReadAllText($site) -cne $configText) {
            [IO.File]::WriteAllText($site, $configText, (New-Object Text.UTF8Encoding($true))); $changed = $true
        }
        $versionPath = Join-Path $bin 'VERSION'
        if (-not (Test-Path $versionPath) -or (Get-Content $versionPath -Raw).Trim() -ne $script:MaintenanceVersion) {
            Set-Content -LiteralPath $versionPath -Value $script:MaintenanceVersion -Encoding ASCII; $changed = $true
        }
        if (-not (Test-Path (Join-Path $script:MaintenanceRoot 'state.json'))) {
            $initial = 'enabled'
            if (-not $providerActive) { $initial = 'disabled' }
            Write-DesiredState $initial 'Initial install'; $changed = $true
        } elseif (-not $providerActive -and (Get-DesiredState).externalAccess -ne 'disabled') {
            Write-DesiredState 'disabled' 'Install: no active external provider'; $changed = $true
        }
        $changed
    }
    Write-Host '==> Tailscale install and desired access'
    if (-not $config.UseTailscale) {
        Write-Host 'skipped (Tailscale not configured)'
    } elseif ($SkipTailscale) {
        $tailConfig = $config.Clone()
        $tailConfig.UseCloudflare = $false
        if (Get-Service Tailscale -ErrorAction SilentlyContinue) { Sync-ExternalAccess $tailConfig 'disabled' | Out-Null }
        Write-Host 'skipped (-SkipTailscale)'
    } else {
        $changed = $false
        $exe = $null
        try { $exe = Get-TailscalePath } catch { }
        if (-not $exe) {
            $download = $null
            try {
                if (-not $TailscaleMsi) {
                    $download = Join-Path $env:TEMP ("vms-tailscale-$([guid]::NewGuid().ToString('N')).msi")
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $download -UseBasicParsing
                    $TailscaleMsi = $download
                }
                $msi = (Resolve-Path -LiteralPath $TailscaleMsi).Path
                $signature = Get-AuthenticodeSignature -LiteralPath $msi
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Tailscale Inc*') {
                    throw 'Tailscale MSI must have a valid Tailscale Inc signature.'
                }
                Invoke-Native 'Install Tailscale MSI' {
                    & msiexec.exe /i $msi /qn /norestart TS_UNATTENDEDMODE=always TS_NOLAUNCH=1 TS_INSTALLUPDATES=always `
                        TS_ALLOWINCOMINGCONNECTIONS=always TS_ENABLEDNS=never TS_ENABLESUBNETS=never TS_ADVERTISEEXITNODE=never
                } | Out-Null
                $changed = $true
            } finally { if ($download -and (Test-Path $download)) { Remove-Item -LiteralPath $download -Force } }
        }
        $desired = (Get-DesiredState).externalAccess
        if ($desired -eq 'enabled') {
            if (Set-AutomaticRunning 'Tailscale') { $changed = $true }
            $exe = Get-TailscalePath
            $status = Invoke-Native 'Tailscale status' { & $exe status --json } | Out-String | ConvertFrom-Json
            if ($status.BackendState -in @('NeedsLogin', 'NoState') -and -not $AuthKey) {
                $AuthKey = Read-Host 'One-time pre-tagged Tailscale auth key' -AsSecureString
            }
        }
        if (Sync-ExternalAccess $installConfig $desired $AuthKey) { $changed = $true }
        $recovery = $false
        try { $recovery = Test-Recovery 'Tailscale' } catch { }
        if (-not $recovery) {
            Invoke-Native 'Tailscale service recovery' { & sc.exe failure Tailscale reset= 86400 actions= restart/5000/restart/5000/restart/30000 } | Out-Null
            $changed = $true
        }
        if ($changed) { Write-Host 'changed' } else { Write-Host 'ok' }
    }
    Write-Host '==> Cloudflare tunnel'
    if (-not $config.UseCloudflare) {
        Write-Host 'skipped (Cloudflare not configured)'
    } elseif ($SkipCloudflare) {
        $cloudConfig = $config.Clone()
        $cloudConfig.UseTailscale = $false
        if (Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue) {
            Sync-ExternalAccess $cloudConfig 'disabled' | Out-Null
        }
        Write-Host 'skipped (-SkipCloudflare)'
    } else {
        Invoke-Step 'Cloudflare binary, token and service' {
            $changed = $false
            $download = $null
            try {
                if (-not $CloudflaredExe) {
                    $download = Join-Path $env:TEMP ("vms-cloudflared-$([guid]::NewGuid().ToString('N')).exe")
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $download -UseBasicParsing
                    $CloudflaredExe = $download
                }
                $source = (Resolve-Path -LiteralPath $CloudflaredExe).Path
                $signature = Get-AuthenticodeSignature -LiteralPath $source
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*CN="Cloudflare, Inc."*') {
                    throw 'cloudflared must have a valid Cloudflare, Inc. signature.'
                }
                $version = Invoke-Native 'Cloudflare version' { & $source --version } | Out-String
                if ($version -notmatch 'cloudflared version (\d+)\.(\d+)\.(\d+)' -or
                    [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -lt [version]'2025.4.0') {
                    throw 'cloudflared version must be 2025.4.0 or later.'
                }
                if (-not (Test-Path -LiteralPath $script:CloudflaredExe) -or
                    (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $script:CloudflaredExe).Hash) {
                    $service = Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue
                    if ($service -and $service.Status -ne 'Stopped') { Stop-Service $script:CloudflaredService }
                    Copy-LayerFile $source $script:CloudflaredExe | Out-Null
                    $changed = $true
                }
            } finally { if ($download -and (Test-Path $download)) { Remove-Item -LiteralPath $download -Force } }
            $rotate = $null -ne $TunnelToken -or -not (Test-Path -LiteralPath $script:CloudflaredTokenFile)
            if ($rotate) {
                if ($null -eq $TunnelToken) { $TunnelToken = Read-Host "Cloudflare tunnel token for $($config.Hostname)" -AsSecureString }
                $secrets = Split-Path $script:CloudflaredTokenFile
                if (-not (Test-Path -LiteralPath $secrets)) { New-Item -ItemType Directory -Path $secrets -Force | Out-Null }
                $candidate = Join-Path $secrets ("cloudflared-$([guid]::NewGuid().ToString('N')).tmp")
                $pointer = [IntPtr]::Zero
                try {
                    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($TunnelToken)
                    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                    if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s' -or $token -match '[^\x21-\x7e]') {
                        throw 'Cloudflare tunnel token must be non-empty ASCII without whitespace.'
                    }
                    [IO.File]::WriteAllText($candidate, $token, [Text.Encoding]::ASCII)
                    Set-PrivateAcl $candidate
                    Move-Item -LiteralPath $candidate -Destination $script:CloudflaredTokenFile -Force
                } catch {
                    # Suppress exception details from the plaintext conversion and write operations.
                    throw 'Cloudflare tunnel token could not be stored; use non-empty ASCII without whitespace and check the protected secrets directory.'
                } finally {
                    $token = $null
                    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
                    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
                }
                $changed = $true
            }
            Set-PrivateAcl $script:CloudflaredTokenFile
            $binPath = '"' + $script:CloudflaredExe + '" tunnel --metrics ' + $script:CloudflaredMetrics +
                ' run --token-file "' + $script:CloudflaredTokenFile + '"'
            $service = Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue
            if (-not $service) {
                New-Service -Name $script:CloudflaredService -BinaryPathName $binPath -StartupType Automatic `
                    -DisplayName 'VMS maintenance Cloudflare tunnel' -Description 'Per-machine Cloudflare tunnel for maintenance SSH through Cloudflare Access.' | Out-Null
                $changed = $true
            } else {
                $image = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$script:CloudflaredService" -Name ImagePath).ImagePath
                if ($image.Trim() -ine $binPath.Trim()) {
                    if ($service.Status -ne 'Stopped') { Stop-Service $script:CloudflaredService }
                    $svc = Get-CimInstance Win32_Service -Filter "Name='$($script:CloudflaredService)'"
                    $result = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ PathName = $binPath }
                    if ($result.ReturnValue -ne 0) { throw "Cloudflare service command update failed with code $($result.ReturnValue)." }
                    $changed = $true
                } elseif ($rotate -and $service.Status -ne 'Stopped') { Stop-Service $script:CloudflaredService }
            }
            $recovery = $false
            try { $recovery = Test-Recovery $script:CloudflaredService } catch { }
            if (-not $recovery) {
                Invoke-Native 'Cloudflare service recovery' { & sc.exe failure $script:CloudflaredService reset= 86400 actions= restart/5000/restart/5000/restart/30000 } | Out-Null
                $changed = $true
            }
            $cloudConfig = $installConfig.Clone()
            $cloudConfig.UseTailscale = $false
            if (Sync-ExternalAccess $cloudConfig (Get-DesiredState).externalAccess) { $changed = $true }
            $changed
        }
    }
    Invoke-Step 'SYSTEM watchdog task' {
        $bin = Join-Path $script:MaintenanceRoot 'bin'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $bin 'Test-Maintenance.ps1') + '" -Repair -Quiet'
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $escapedExe = [Security.SecurityElement]::Escape($powershell)
        $escapedArguments = [Security.SecurityElement]::Escape($arguments)
        # XML expresses an indefinitely repeating trigger without a finite duration limit.
        $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    <TimeTrigger><Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><StartBoundary>2020-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger>
  </Triggers>
  <Principals><Principal id="System"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><ExecutionTimeLimit>PT4M</ExecutionTimeLimit></Settings>
  <Actions Context="System"><Exec><Command>$escapedExe</Command><Arguments>$escapedArguments</Arguments></Exec></Actions>
</Task>
"@
        $existing = Get-ScheduledTask -TaskName $script:MaintenanceTask -TaskPath $script:MaintenanceTaskPath -ErrorAction SilentlyContinue
        $taskMatches = $false
        if ($existing) {
            $boot = @($existing.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
            $timer = @($existing.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' })
            $actions = @($existing.Actions)
            $taskMatches = @($existing.Triggers).Count -eq 2 -and $boot.Count -eq 1 -and $timer.Count -eq 1 -and
                $boot[0].Enabled -and $boot[0].Delay -eq 'PT1M' -and $timer[0].Enabled -and
                $timer[0].Repetition.Interval -eq 'PT5M' -and -not $timer[0].Repetition.Duration -and
                $timer[0].StartBoundary -eq '2020-01-01T00:00:00' -and $actions.Count -eq 1 -and
                $actions[0].Execute -eq $powershell -and $actions[0].Arguments -ceq $arguments -and
                $existing.Principal.UserId -in @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM') -and
                $existing.Principal.LogonType -eq 'ServiceAccount' -and $existing.Principal.RunLevel -eq 'Highest' -and
                $existing.Settings.Enabled -and $existing.Settings.StartWhenAvailable -and
                -not $existing.Settings.DisallowStartIfOnBatteries -and -not $existing.Settings.StopIfGoingOnBatteries -and
                $existing.Settings.MultipleInstances -eq 'IgnoreNew' -and $existing.Settings.ExecutionTimeLimit -eq 'PT4M'
        }
        if (-not $taskMatches) {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            # try { $scheduler.GetFolder($script:MaintenanceTaskPath) | Out-Null }
            try { $scheduler.GetFolder($script:MaintenanceTaskPath.TrimEnd('\')) | Out-Null }
            catch { $scheduler.GetFolder('\').CreateFolder('IDENMATIC') | Out-Null }
            Register-ScheduledTask -TaskName $script:MaintenanceTask -TaskPath $script:MaintenanceTaskPath -Xml $xml -Force | Out-Null
            $true
        }
    }
    if ($config.UseCloudflare) { Write-Host "Cloudflare SSH host: $($config.CloudflareHostname)" }
    Write-Host '==> Verify maintenance'
    & (Join-Path $script:MaintenanceRoot 'bin\Test-Maintenance.ps1')
    $exitCode = $LASTEXITCODE
} catch {
    Write-Error $_ -ErrorAction Continue
    $exitCode = 1
}
# Defer until all copying and verification has finished, including failed later steps.
if ($script:sshRestartPending) {
    try { Register-SshdRestart }
    catch { Write-Error $_ -ErrorAction Continue; $exitCode = 1 }
}
exit $exitCode
