# Maintenance layer - runbook

Task-oriented. Design and reasons are in [`ARCHITECTURE.md`](ARCHITECTURE.md).
Commands are PowerShell; "elevated" means "Run as administrator". `<site>` is the site code,
`<role>` is `srv` or `desk`. The Cloudflare hostname is `vms-<site>-<role>.maint.<domain>`
(`maint.example.com` is a placeholder until the real zone is confirmed). The Tailscale
hostname (fallback) is `vms-<site>-<role>`.

Note: `-TunnelToken` and `-AuthKey` are SecureStrings. Omit them and the script prompts. Do
not put a token or key in a command line.

## 1. Before you go to site

1. Cloudflare Zero Trust dashboard (primary path). TODO(confirm): the real Cloudflare DNS zone
   (a domain whose DNS is on Cloudflare is required).
   - Once: create the Zero Trust organization (free plan), connect the company IdP with MFA,
     and create the engineers group.
   - Once: create one self-hosted Access application for `*.maint.<domain>` (wildcard) with an
     Allow policy for the engineers group (via the IdP, MFA required).
   - Per machine (two machines means two tunnels and two tokens):
     1. Create a remotely-managed Cloudflare Tunnel (for example `vms-<site>-<role>`).
     2. Add a published application route: hostname `vms-<site>-<role>.<domain>` -> service
        `ssh://localhost:22`.
     3. Copy the tunnel token and keep it in the vault until install.
2. Tailscale admin console (fallback, only if TailscaleTag is set):
   - Create the group `group:vms-engineers` and add the engineers.
   - Apply the tailnet policy from `examples/tailnet-policy.example.hujson` (replace the
     default allow-all). Edit group and tag names only if they differ.
   - For each machine, create a one-time auth key, pre-tagged `tag:vms-site`, short expiry.
     Two machines means two keys.
3. Prepare one config per machine: copy `config/site.example.psd1` to
   `config/<site>-<role>.psd1` and set `SiteCode`, `Role`, `MaintenanceAccount`,
   `LanSubnets`, `CloudflareHostname` (full FQDN, must start with `vms-<site>-<role>.`),
   `TailscaleTag` (optional), `AuthorizedKeysFile`. At least one of `CloudflareHostname` and
   `TailscaleTag` is required; if both are set, both paths are installed. Real configs are
   gitignored.
4. Prepare `keys/engineers.pub` from `keys/engineers.pub.example`: one ed25519 public key per
   line, comment = engineer name.
5. Have a vault entry ready for the maintenance account password (shown once at install),
   and the tunnel token for each machine.
6. Put the whole `maintenance/` folder on a USB stick, plus the signed `cloudflared.exe` (for
   `-CloudflaredExe`) and, if Tailscale is used, the Tailscale MSI, if the site may lack
   internet. If the site has internet, the script downloads them
   (cloudflared from `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe`).

## 2. First install on a machine

Local, on the machine. Do the Server PC, then the Desk PC. This is the only step that needs
someone at the machine; every later run goes over SSH.

**Easiest: double-click `Start-Install.cmd`** in the `maintenance` folder and approve the
administrator (UAC) prompt.

- It picks the config from `config\`: if there is exactly one `*.psd1` (examples ignored) it
  uses that; if there are several (for example both `<site>-srv.psd1` and `<site>-desk.psd1`
  on the same USB stick), it lists them and asks you to type the one for this machine.
- It runs `Install-Maintenance.ps1` elevated with a process-only execution-policy bypass
  (machine policy is not changed), then shows the exit code and keeps the window open.
- To name the config explicitly: `Start-Install.cmd config\<site>-<role>.psd1`.

**Equivalent by hand**, in an elevated PowerShell:

```powershell
cd <path>\maintenance
Set-ExecutionPolicy -Scope Process Bypass
.\Install-Maintenance.ps1 -ConfigPath .\config\<site>-<role>.psd1
```

The script prompts for the Cloudflare tunnel token (SecureString) and, if `TailscaleTag` is
set, the Tailscale auth key. `Start-Install.cmd` is unchanged and prompts for the token too.
Optional parameters (by hand only):

```powershell
.\Install-Maintenance.ps1 -ConfigPath .\config\<site>-<role>.psd1 -CloudflaredExe D:\cloudflared.exe
.\Install-Maintenance.ps1 -ConfigPath .\config\<site>-<role>.psd1 -SkipCloudflare
.\Install-Maintenance.ps1 -ConfigPath .\config\<site>-<role>.psd1 -TailscaleMsi D:\tailscale.msi   # fallback
.\Install-Maintenance.ps1 -ConfigPath .\config\<site>-<role>.psd1 -SkipTailscale                   # fallback
```

`-CloudflaredExe` is a local signed exe for offline sites. The exe must be signed
"Cloudflare, Inc." and version >= 2025.4.0.
The token is stored in `C:\ProgramData\IDENMATIC\maintenance\secrets\cloudflared-token`
(Administrators + SYSTEM only), because cloudflared needs it at every start.
`-SkipCloudflare` / `-SkipTailscale` skip that path. If no provider is active (configured and
not skipped), you get LAN-only mode and the state is `disabled`; otherwise it is `enabled`.

What to expect:

- Each step prints `==> step` and then `ok`, `changed` or `skipped`.
- The maintenance account password is printed once. Copy it into the vault now. It is not
  stored anywhere on the machine.
- The install ends by printing `Cloudflare SSH host: <hostname>`. Note it for the engineers.
- The last step runs the verification. The script exits with its code: 0 means no FAIL.
  WARN lines are acceptable but read them (for example BIOS power items).

Re-running the install is safe.

## 3. Verify

Locally, elevated:

```powershell
.\Test-Maintenance.ps1
.\Test-Maintenance.ps1 -Json
```

Installed copy:

```powershell
C:\ProgramData\IDENMATIC\maintenance\bin\Test-Maintenance.ps1
```

Remotely, from an engineer laptop:

```powershell
# Cloudflare (primary)
ssh vms-<site>-srv.maint.example.com "powershell -NoProfile -File C:\ProgramData\IDENMATIC\maintenance\bin\Test-Maintenance.ps1"
ssh vms-<site>-srv.maint.example.com "powershell -NoProfile -File C:\ProgramData\IDENMATIC\maintenance\bin\Test-Maintenance.ps1 -Json"

# Tailscale (fallback, only if TailscaleTag is set)
ssh vms-<site>-srv "powershell -NoProfile -File C:\ProgramData\IDENMATIC\maintenance\bin\Test-Maintenance.ps1"
```

Cloudflare checks: `cloudflared-installed`, `cloudflared-token`, `cloudflared-service`,
`cloudflared-recovery`, `cloudflared-ready` (GET `http://127.0.0.1:20241/ready`: PASS when
HTTP 200 and readyConnections > 0). Tailscale checks appear only when Tailscale is configured.

`-Json` prints an array of `{ id, status, detail }`. Exit code 1 means at least one FAIL.
Use `-Repair` only when you want the narrow repairs (services, Cloudflare service state and
recovery, firewall rule, access state). It never downloads cloudflared or touches the token.

## 4. Engineer workstation setup

1. Cloudflare (primary): install cloudflared (`winget install --id Cloudflare.cloudflared`).
   It must be on PATH. Make sure you are in the engineers group in the company IdP.
2. Have an ed25519 key with a passphrase. Give the public key to whoever maintains
   `keys/engineers.pub`.
3. Add this block to `~/.ssh/config` and set the `IdentityFile`:

```
Host vms-*.maint.example.com
    User vmsmaint
    ProxyCommand cloudflared access ssh --hostname %h
    ServerAliveInterval 30
```

4. First connect (a browser opens for the Access login):

```powershell
ssh vms-<site>-srv.maint.example.com
ssh vms-<site>-desk.maint.example.com
```

Check the host key prompt, then accept.

Fallback if one machine's tunnel is down: jump through the other over the LAN.

```powershell
ssh -J vms-<site>-desk.maint.example.com vmsmaint@<server-lan-ip>
```

Tailscale (fallback, only if TailscaleTag is set): install the Tailscale client and sign in
with company SSO (MFA). Copy `examples/ssh_config.example` into `~/.ssh/config` (it defines
`Host vms-*` with `User vmsmaint` and `ServerAliveInterval 30`). Then
`ssh vms-<site>-srv`, or `ssh -J vms-<site>-desk vmsmaint@<server-lan-ip>`.

There is no automatic failover. You choose the path by the hostname you use.

## 5. Enable / disable external access

Run on the machine (locally or over SSH), elevated.

```powershell
.\SetAccess-Maintenance.ps1 -State Status
.\SetAccess-Maintenance.ps1 -State Disabled -Reason "site stable, handed over"
.\SetAccess-Maintenance.ps1 -State Enabled -Reason "update window"
```

- One switch for all configured paths. Disabled stops and disables `VMS-Maint-Cloudflared`
  (and Tailscale, if configured). `Status` shows the Cloudflare service and hostname.
- (fallback, only if TailscaleTag is set) If the node was logged out or removed from the
  tailnet, enabling needs a new one-time tagged key: add `-AuthKey` (it is a SecureString;
  omit it and the script prompts).
- If you run `-State Disabled` inside an SSH session that came through an external path, the
  script refuses, because it cuts your own session. This now includes Cloudflare sessions:
  cloudflared delivers SSH from localhost, so `SSH_CLIENT` starts with `127.0.0.1` or `::1`.
  Tailnet sessions (`100.` / `fd7a:115c:a1e0:`) are also refused. `-Force` overrides this.
  Only use it if you accept losing the session. Prefer doing it locally or from a LAN session.
- Disabling leaves sshd and the LAN rule running (LAN SSH stays). The watchdog keeps the state.
- Every change is logged to `C:\ProgramData\IDENMATIC\maintenance\logs\access-changes.log`.

Our-side kill switch (not scripted): in the Cloudflare dashboard, disable or delete the
tunnel, or remove the engineer from the Access policy. (fallback) In the Tailscale admin
console, remove or disable the grant in the policy, or disable the device.

## 6. Rotate or revoke an engineer key

1. Edit `keys/engineers.pub`: add the new line, or delete the leaving engineer's line.
2. Push it to each machine and run the keys-only step. Install keeps a full copy of the
   layer in `C:\ProgramData\IDENMATIC\maintenance\bin\`, with the site config at
   `bin\site.psd1` and the keys at `bin\keys\engineers.pub`, so no other folder is needed.
3. For a person leaving, also remove them from the IdP group and the Cloudflare Access policy.

```powershell
$hosts = 'vms-acme-bkk1-srv.maint.example.com','vms-acme-bkk1-desk.maint.example.com'
foreach ($h in $hosts) {
  scp .\keys\engineers.pub "${h}:C:/ProgramData/IDENMATIC/maintenance/bin/keys/engineers.pub"
  ssh $h "powershell -NoProfile -File C:\ProgramData\IDENMATIC\maintenance\bin\Install-Maintenance.ps1 -Only Keys"
}
```

`-Only Keys` rewrites `administrators_authorized_keys` and its ACL, nothing else.

Do not remove your own key and then close your session before confirming another key works
(open a second session with the remaining key first).

## 7. Update the maintenance scripts themselves

1. Copy the new `maintenance/` folder to a temporary folder on the machine (`scp -r`, or USB).
2. Run its install against the installed config. It is idempotent and refreshes
   `C:\ProgramData\IDENMATIC\maintenance\bin\`:

   ```powershell
   ssh vms-<site>-srv.maint.example.com "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\maintenance\Install-Maintenance.ps1 -ConfigPath C:\ProgramData\IDENMATIC\maintenance\bin\site.psd1"
   ```

   cloudflared does not auto-update on Windows; re-running Install updates it. The run may
   prompt for the tunnel token (see section 8 for rotation).

3. If `sshd_config` changed and you ran it over SSH, the script does not restart sshd under
   your session; it schedules the restart about 30 seconds later. Reconnect afterwards.
4. Run the verification. A WARN about the `bin` copy version means it did not refresh.
   Delete the temporary folder.

## 8. Recover

| Symptom | What to do |
|---|---|
| Cannot reach one machine over Cloudflare | Check the tunnel is Healthy in the Cloudflare dashboard. Jump through the other: `ssh -J vms-<site>-desk.maint.example.com vmsmaint@<server-lan-ip>`. Then run the verification on the broken machine (`cloudflared-ready` shows whether the tunnel has connections). If Tailscale is configured, you can switch to it by hand. |
| Cannot reach one machine over the tailnet (fallback) | Jump through the other: `ssh -J vms-<site>-desk vmsmaint@<server-lan-ip>`. Then run the verification on the broken machine. |
| Cloudflare Access login fails or is denied | Check you are in the engineers group and the Access policy; cloudflared must be on PATH on the laptop. |
| Tunnel token leaked or needs rotating | Rotate/refresh the tunnel token in the Cloudflare dashboard, then re-run Install with the new one (`-TunnelToken`, or enter it at the prompt). |
| Both unreachable | Ask the customer to check power, router and internet. If still down, go on site. |
| Machine reachable but check shows FAIL | Run `Test-Maintenance.ps1 -Repair`. If a FAIL remains, re-run the install. |
| Watchdog seems inactive | Read `C:\ProgramData\IDENMATIC\maintenance\logs\watchdog-YYYYMM.log`. It logs only when something is repaired or failing, so an empty log is normal. Check the task `\IDENMATIC\VMS-Maintenance-Watchdog` exists and last result is 0. |
| Login refused | Read the sshd log (below). Check the key is in `keys/engineers.pub` and was installed. |
| Bad `sshd_config` (sshd will not start) | Locally or via LAN console: restore the backup (below). |
| Tailscale logged out or node removed (fallback) | Create a new one-time tagged key, then `SetAccess-Maintenance.ps1 -State Enabled -AuthKey`. |

Read the sshd log:

```powershell
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 50
```

Restore the original sshd config (local):

```powershell
Copy-Item C:\ProgramData\ssh\sshd_config.pre-vms-maint C:\ProgramData\ssh\sshd_config -Force
Restart-Service sshd
```

This restores the stock config, so the hardening is lost until the install is re-run.

## 9. Manual removal

There is no uninstall script. Elevated PowerShell on the machine.

```powershell
# watchdog
Unregister-ScheduledTask -TaskName 'VMS-Maintenance-Watchdog' -TaskPath '\IDENMATIC\' -Confirm:$false

# firewall: remove our rule, re-enable the stock rule if you want SSH from anywhere
Remove-NetFirewallRule -Name 'VMS-Maint-SSH-In'
Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'     # optional

# Cloudflare tunnel service
Stop-Service VMS-Maint-Cloudflared; sc.exe delete VMS-Maint-Cloudflared
# the cloudflared and secrets folders are deleted with the maintenance root (last step)

# Tailscale (fallback, only if TailscaleTag is set)
tailscale logout
# then uninstall: Settings > Apps, or msiexec /x <tailscale msi or product code> /qn

# sshd config back to the original
Copy-Item C:\ProgramData\ssh\sshd_config.pre-vms-maint C:\ProgramData\ssh\sshd_config -Force
Restart-Service sshd

# maintenance account (name from the config)
Remove-LocalUser -Name vmsmaint

# our files
Remove-Item -Recurse -Force C:\ProgramData\IDENMATIC\maintenance
```

Also delete the tunnel and its published route in the Cloudflare dashboard, and delete the
node from the Tailscale admin console (if used). Remove `administrators_authorized_keys`
if no other use needs it. The firewall rule's name is `VMS-Maint-SSH-In` (display name
"VMS maintenance SSH"). If a one-shot `\IDENMATIC\VMS-Maintenance-SshdRestart` task is still
listed, unregister it the same way as the watchdog.

## 10. On-site checklist

- BIOS: set "power on after AC loss" (or equivalent) on both machines. This cannot be scripted.
- Put the machines on a UPS if one is available.
- Note the LAN IP of each machine. Needed for the fallback jump and `LanSubnets`.
- Recommend a DHCP reservation for both machines on the router, so the IPs do not change.
- Confirm the config `LanSubnets` matches the real LAN.
- After install, run the verification on both machines and confirm both tunnels show as
  connected (Healthy) in the Cloudflare dashboard.
- (fallback, only if TailscaleTag is set) Confirm both appear in the Tailscale admin console
  with `tag:vms-site`.
