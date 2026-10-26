# Shared maintenance primitives. Dot-source only; loading this file changes no machine state.
$script:MaintenanceVersion = '0.2.0'
$script:MaintenanceRoot = Join-Path $env:ProgramData 'IDENMATIC\maintenance'
$script:CloudflaredService = 'VMS-Maint-Cloudflared'
$script:CloudflaredExe = Join-Path $script:MaintenanceRoot 'cloudflared\cloudflared.exe'
$script:CloudflaredTokenFile = Join-Path $script:MaintenanceRoot 'secrets\cloudflared-token'
$script:CloudflaredMetrics = '127.0.0.1:20241'
$script:MaintenanceRule = 'VMS-Maint-SSH-In'
$script:MaintenanceTask = 'VMS-Maintenance-Watchdog'
$script:MaintenanceTaskPath = '\IDENMATIC\'

function Invoke-Native([string]$Description, [scriptblock]$Command, [switch]$Sensitive) {
    $ErrorActionPreference = 'Continue'
    $output = & $Command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($Sensitive) { throw "$Description failed with exit code $code. Native output suppressed (may contain credentials)." }
        throw "$Description failed with exit code $code.`n$($output -join "`n")"
    }
    return $output
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Platform {
    if (-not (Test-Elevated)) { throw 'An elevated Windows PowerShell session is required.' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) { throw 'Windows build 17763 or later is required.' }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'PowerShell 5.1 or later is required.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
}

function Read-SiteConfig([string]$ConfigPath, [string]$ScriptRoot) {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'site.psd1' }
    $resolved = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $config = Import-PowerShellDataFile -LiteralPath $resolved
    foreach ($name in @('SiteCode', 'Role', 'MaintenanceAccount', 'LanSubnets', 'AuthorizedKeysFile')) {
        if (-not $config.ContainsKey($name)) { throw "Config is missing $name." }
    }
    foreach ($name in $config.Keys) {
        if ($name -notin @('SiteCode', 'Role', 'MaintenanceAccount', 'LanSubnets', 'TailscaleTag', 'CloudflareHostname', 'AuthorizedKeysFile')) {
            throw "Unknown config field: $name."
        }
    }
    if ($config.SiteCode -isnot [string] -or $config.SiteCode -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        throw 'SiteCode must contain lowercase letters, digits and single internal hyphens.'
    }
    if ($config.Role -cnotin @('srv', 'desk')) { throw 'Role must be srv or desk.' }
    $hostname = "vms-$($config.SiteCode)-$($config.Role)"
    if ($hostname.Length -gt 63) { throw 'Tailnet hostname must be at most 63 characters.' }
    if ($config.MaintenanceAccount -isnot [string] -or
        $config.MaintenanceAccount -cnotmatch '^[a-z][a-z0-9_-]{0,19}$') {
        throw 'MaintenanceAccount must be a lowercase local username (1-20 letters, digits, underscore or hyphen).'
    }
    if ($config.MaintenanceAccount -in @('administrator', 'guest', 'defaultaccount', 'wdagutilityaccount')) {
        throw 'MaintenanceAccount must be a dedicated account, not a built-in account.'
    }
    $config.UseCloudflare = $config.ContainsKey('CloudflareHostname')
    $config.UseTailscale = $config.ContainsKey('TailscaleTag')
    if (-not $config.UseCloudflare -and -not $config.UseTailscale) {
        throw 'Config must set CloudflareHostname, TailscaleTag, or both.'
    }
    if ($config.UseTailscale -and ($config.TailscaleTag -isnot [string] -or
        $config.TailscaleTag -cnotmatch '^tag:[a-z][a-z0-9-]*$')) {
        throw 'TailscaleTag must be a tag:name value.'
    }
    if ($config.UseCloudflare) {
        if ($config.CloudflareHostname -isnot [string] -or $config.CloudflareHostname.Length -gt 253 -or
            -not $config.CloudflareHostname.StartsWith("$hostname.", [StringComparison]::Ordinal)) {
            throw 'CloudflareHostname must be a lowercase FQDN starting with the machine hostname and a dot (at most 253 characters).'
        }
        $labels = $config.CloudflareHostname.Split('.')
        if ($labels.Count -lt 3) { throw 'CloudflareHostname must contain at least three labels.' }
        foreach ($label in $labels) {
            if ($label -match '\s' -or $label -cnotmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$') {
                throw 'CloudflareHostname labels must contain lowercase letters, digits and internal hyphens (1-63 characters).'
            }
        }
    }
    if ($config.LanSubnets -is [string] -or @($config.LanSubnets).Count -eq 0) {
        throw 'LanSubnets must be a non-empty array of CIDR networks.'
    }
    foreach ($subnet in $config.LanSubnets) {
        $parts = "$subnet".Split('/')
        $ip = $null
        $prefix = 0
        if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
            -not [int]::TryParse($parts[1], [ref]$prefix)) { throw "Invalid LAN CIDR: $subnet." }
        $bits = 128
        if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { $bits = 32 }
        if ($prefix -lt 1 -or $prefix -gt $bits) { throw "Invalid LAN prefix: $subnet." }
        if ($bits -eq 128 -and $ip.ScopeId -ne 0) { throw "LAN CIDR must not contain a zone identifier: $subnet." }
        $bytes = $ip.GetAddressBytes()
        for ($bit = $prefix; $bit -lt $bits; $bit++) {
            if (($bytes[[int][math]::Floor($bit / 8)] -band (1 -shl (7 - ($bit % 8)))) -ne 0) {
                throw "LAN CIDR must use a network address, with host bits zero: $subnet."
            }
        }
    }
    if ($config.AuthorizedKeysFile -isnot [string] -or [string]::IsNullOrWhiteSpace($config.AuthorizedKeysFile)) {
        throw 'AuthorizedKeysFile must be a non-empty path.'
    }
    if (-not [IO.Path]::IsPathRooted($config.AuthorizedKeysFile)) {
        $config.AuthorizedKeysFile = [IO.Path]::GetFullPath((Join-Path (Split-Path $resolved) $config.AuthorizedKeysFile))
    }
    $config.Hostname = $hostname
    return $config
}

function Get-TailscalePath {
    $path = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Tailscale executable is not installed.'
}

function Get-DesiredState {
    $path = Join-Path $script:MaintenanceRoot 'state.json'
    $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($state.externalAccess -cnotin @('enabled', 'disabled')) { throw 'state.json has invalid externalAccess.' }
    return $state
}

function Set-PrivateAcl([string]$Path) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-DesiredState([string]$State, [string]$Reason) {
    $path = Join-Path $script:MaintenanceRoot 'state.json'
    $candidate = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [ordered]@{ externalAccess = $State.ToLowerInvariant(); changedAt = [DateTime]::UtcNow.ToString('o')
            changedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name; reason = $Reason
        } | ConvertTo-Json | Set-Content -LiteralPath $candidate -Encoding UTF8
        Move-Item -LiteralPath $candidate -Destination $path -Force
    } finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force } }
}

function Get-ExpectedAddresses($Config) {
    return @('100.64.0.0/10', 'fd7a:115c:a1e0::/48') + @($Config.LanSubnets)
}

function Test-SameSet($Left, $Right) {
    return @(Compare-Object @($Left | Sort-Object -Unique) @($Right | Sort-Object -Unique)).Count -eq 0
}

function Get-EngineerKeys([string]$Path) {
    $keys = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    if ($keys.Count -eq 0) { throw 'Public key file contains no keys.' }
    foreach ($key in $keys) {
        if ($key -notmatch '^ssh-ed25519\s+([A-Za-z0-9+/]+={0,2})\s+(.+)$') {
            throw 'Each public key must be an ed25519 key followed by an engineer comment.'
        }
        try { $bytes = [Convert]::FromBase64String($Matches[1]) } catch { throw 'Invalid public key base64.' }
        if ($bytes.Length -ne 51 -or [BitConverter]::ToString($bytes[0..3]) -ne '00-00-00-0B' -or
            [Text.Encoding]::ASCII.GetString($bytes, 4, 11) -ne 'ssh-ed25519' -or
            [BitConverter]::ToString($bytes[15..18]) -ne '00-00-00-20') { throw 'Invalid ed25519 key encoding.' }
    }
    return $keys
}

function Test-Recovery([string]$ServiceName) {
    $value = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name FailureActions).FailureActions
    if ($value.Length -lt 44) { return $false }
    if ([BitConverter]::ToUInt32($value, 0) -ne 86400 -or [BitConverter]::ToUInt32($value, 12) -ne 3) { return $false }
    for ($i = 0; $i -lt 3; $i++) {
        $delay = 5000
        if ($i -eq 2) { $delay = 30000 }
        if ([BitConverter]::ToUInt32($value, (20 + 8 * $i)) -ne 1 -or
            [BitConverter]::ToUInt32($value, (24 + 8 * $i)) -ne $delay) { return $false }
    }
    return $true
}

function Test-HibernationEnabled {
    # Newer Windows builds can omit HibernateEnabled; disabling hibernation removes hiberfil.sys.
    $power = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
    if ($power.HibernateEnabled -eq 1) { return $true }
    $file = Join-Path $env:SystemDrive 'hiberfil.sys'
    try { Get-Item -LiteralPath $file -Force -ErrorAction Stop | Out-Null; return $true }
    catch [System.Management.Automation.ItemNotFoundException] { return $false }
}

function Set-AutomaticRunning([string]$Name) {
    $changed = $false
    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.StartType -ne 'Automatic') { Set-Service -Name $Name -StartupType Automatic; $changed = $true }
    if ($service.Status -ne 'Running') { Start-Service -Name $Name; $changed = $true }
    return $changed
}

function Enable-Tailnet($Config, [Security.SecureString]$AuthKey) {
    $exe = Get-TailscalePath
    $arguments = @('up', '--unattended=true', "--hostname=$($Config.Hostname)",
        "--advertise-tags=$($Config.TailscaleTag)", '--accept-dns=false', '--accept-routes=false')
    $pointer = [IntPtr]::Zero
    try {
        if ($AuthKey) {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AuthKey)
            $arguments += '--auth-key=' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        Invoke-Native 'Tailscale join' { & $exe @arguments } -Sensitive | Out-Null
    } finally {
        $arguments = $null
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Sync-ExternalAccess($Config, [string]$State, [Security.SecureString]$AuthKey) {
    $changed = $false
    if ($Config.UseCloudflare -and (Get-Service $script:CloudflaredService -ErrorAction SilentlyContinue)) {
        if ($State -eq 'disabled') {
            $service = Get-Service $script:CloudflaredService -ErrorAction Stop
            if ($service.Status -ne 'Stopped') { Stop-Service $script:CloudflaredService; $changed = $true }
            if ($service.StartType -ne 'Disabled') {
                Set-Service $script:CloudflaredService -StartupType Disabled; $changed = $true
            }
        } elseif (Set-AutomaticRunning $script:CloudflaredService) { $changed = $true }
    }
    $cloudflareChanged = $changed
    if ($Config.UseTailscale -and (Get-Service Tailscale -ErrorAction SilentlyContinue)) {
        if ($State -eq 'disabled') {
            $service = Get-Service Tailscale -ErrorAction Stop
            if ($service.Status -ne 'Stopped') {
                try {
                    $exe = Get-TailscalePath
                    Invoke-Native 'Tailscale down' { & $exe down } | Out-Null
                } finally {
                    # Enforce off even if the daemon cannot answer its down command.
                    Stop-Service Tailscale -ErrorAction Stop
                    Set-Service Tailscale -StartupType Disabled
                }
                $changed = $true
            }
            if ($service.StartType -ne 'Disabled') { Set-Service Tailscale -StartupType Disabled; $changed = $true }
        } else {
            $changed = Set-AutomaticRunning 'Tailscale'
            $exe = Get-TailscalePath
            $status = Invoke-Native 'Tailscale status' { & $exe status --json } | Out-String | ConvertFrom-Json
            if ($status.BackendState -in @('NeedsLogin', 'NoState') -and -not $AuthKey) {
                throw 'Tailscale requires authentication. Supply -AuthKey (SecureString) to enable access.'
            }
            $prefs = $null
            try { $prefs = Invoke-Native 'Tailscale preferences' { & $exe debug prefs } | Out-String | ConvertFrom-Json } catch { }
            if ($AuthKey -or $status.BackendState -ne 'Running' -or $status.Self.HostName -cne $Config.Hostname -or
                -not $prefs -or -not $prefs.ForceDaemon -or $prefs.CorpDNS -or $prefs.RouteAll) {
                Enable-Tailnet $Config $AuthKey
                $changed = $true
            }
        }
    }
    return $changed -or $cloudflareChanged
}
