# Maintenance layer - architecture

## Purpose

Give engineers standing remote maintenance access to the Server PC and the Desk PC at a
customer site, using Windows built-ins and one mature package: Cloudflare Tunnel
(`cloudflared`, primary) or Tailscale (optional fallback). No custom services or agents. The layer sits on the Windows host and has no dependency on Hyper-V,
Docker, the VM or any VMS app.

## Requirements it meets

- Both machines reachable from engineers' laptops without a public IP or port forwarding.
- Reachable for install, update, configure, troubleshoot, roll back and remove (later parts).
- Survives reboot, power cut, service crash and app failure without a site visit.
- Local VMS operation keeps working with no internet.
- External access can be turned off later; LAN and local management then remain.
- Each machine is independent; one can be used to reach the other over the LAN.
- Idempotent install and a read-only verification command.
- Auditable: who connected, which key, who changed access state.

## Topology

Primary path, Cloudflare (Option A):

```
Engineer laptop
  OpenSSH client + cloudflared (ProxyCommand)
        |
        |  Cloudflare Access (company IdP + MFA, Allow: engineers group)
        |  hostname vms-<site>-<role>.maint.<domain>
        v
   Cloudflare edge  <---- outbound-only tunnel from each machine
        |
        v
+------------------------- Customer LAN --------------------------+
|                                                                 |
|  Server PC                                  Desk PC             |
|  +--------------------+  LAN ssh (jump)  +--------------------+ |
|  | cloudflared service| <--------------> | cloudflared service| |
|  | (own tunnel+token) |                  | (own tunnel+token) | |
|  | sshd (localhost:22)|                  | sshd (localhost:22)| |
|  +--------------------+                  +--------------------+ |
|    |                                                            |
|    +-- (Part 2: Hyper-V VM, reached by ProxyJump via Server PC) |
|                                                                 |
+-----------------------------------------------------------------+
```

Optional fallback, Tailscale (only if `TailscaleTag` is set): the engineer's Tailscale client
(company SSO + MFA) reaches the machine over the tailnet (WireGuard, outbound-only from the
site, ACL: engineers -> `tag:vms-site`, tcp:22 only). Each machine is then also its own
tailnet node, with a Tailscale service beside `cloudflared`.

- The same layer is installed on both machines, independently. Each has its own Cloudflare
  Tunnel and token (and its own tailnet node if Tailscale is configured).
- There is no automatic failover between the two paths. The engineer picks the path by hand
  (by hostname: `vms-<site>-srv.maint.<domain>` for Cloudflare, `vms-<site>-srv` for Tailscale).
- If one machine's tunnel fails, reach it through the other over the LAN:
  `ssh -J vms-<site>-desk.maint.<domain> vmsmaint@<server-lan-ip>`
  (Tailscale: `ssh -J vms-<site>-desk vmsmaint@<server-lan-ip>`).
- The VM (Part 2) is not a tunnel endpoint. It is reached with `ProxyJump` through the Server PC.
- Web UIs, when needed, go through `ssh -L`. No other port is exposed.

## Components

### Cloudflare Tunnel (primary)

- What: `cloudflared` as a Windows service. One remotely-managed Cloudflare Tunnel per machine
  (Server PC and Desk PC each have their own tunnel and token). Each tunnel has a published
  application route: hostname `vms-<site>-<role>.<domain>` -> service `ssh://localhost:22`.
  The domain is the placeholder `maint.example.com` until the real Cloudflare DNS zone is
  confirmed. A domain whose DNS is on Cloudflare is required.
  TODO(confirm): the real Cloudflare DNS zone / domain.
- Why: outbound-only, no public IP or inbound port, free plan, plain OpenSSH on top.
- Cloudflare Access: one self-hosted Access application for `*.maint.<domain>` (wildcard) with
  an Allow policy for the engineers group via the company IdP with MFA. Free plan: up to 50
  users, logs kept up to 24 hours, community support.
- On the machine:
  - exe: `C:\ProgramData\IDENMATIC\maintenance\cloudflared\cloudflared.exe`. Signature must be
    signed "Cloudflare, Inc."; it is verified at install, and the version must be >= 2025.4.0.
    Otherwise install refuses.
  - exe source: `-CloudflaredExe` (a local signed exe, for offline sites), otherwise downloaded
    from `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe`.
  - cloudflared does not auto-update on Windows. Re-running Install updates it.
  - service `VMS-Maint-Cloudflared` (display name "VMS maintenance Cloudflare tunnel"), binPath
    `"<exe>" tunnel --metrics 127.0.0.1:20241 run --token-file "<token file>"`.
  - service recovery: restart/5000/restart/5000/restart/30000.
- Token: entered as a SecureString at install (prompt) and stored in
  `C:\ProgramData\IDENMATIC\maintenance\secrets\cloudflared-token` with a private ACL
  (Administrators + SYSTEM only). This is a deliberate difference from the Tailscale auth key
  (never stored): cloudflared needs the token at every start. `--token-file` keeps it out of
  the service command line, which local users can read.
  - Rotate: re-run Install with `-TunnelToken`.
  - If a token leaks: rotate/refresh the tunnel token in the Cloudflare dashboard, then re-run
    Install with the new one.
- Network: cloudflared reaches sshd through loopback, which Windows Firewall does not filter.
  No new inbound rule and no inbound port.

### Tailscale (optional fallback)

Installed only when `TailscaleTag` is set in the site config.

Site config (`site.psd1`): `CloudflareHostname` (optional, full FQDN, must start with
`vms-<site>-<role>.`) and `TailscaleTag` (now optional). At least one of them is required.
If both are present, both paths are installed and both follow the one access switch.

- What: Windows MSI, runs as a service. Provides the encrypted outbound tunnel.
- Why: no inbound port or public IP needed; company SSO + MFA; ACLs in one place; an
  admin-console kill switch.
- Key settings:
  - Silent install: `msiexec /i <msi> /qn /norestart TS_UNATTENDEDMODE=always TS_NOLAUNCH=1 TS_INSTALLUPDATES=always TS_ALLOWINCOMINGCONNECTIONS=always TS_ENABLEDNS=never TS_ENABLESUBNETS=never TS_ADVERTISEEXITNODE=never`
  - MSI from `-TailscaleMsi` or `https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi`.
    The signature must be `Valid` with signer subject containing `Tailscale Inc`. Otherwise
    install refuses.
  - Join: `tailscale up --unattended=true --auth-key=<key> --hostname=vms-<site>-<role> --accept-dns=false --accept-routes=false`
  - Auth key: one-time, pre-tagged `tag:vms-site`, short expiry, created in the admin
    console. A tagged node has key expiry disabled by default. The key is read as a
    SecureString, never logged, never written to disk.
  - Site isolation comes from the tailnet policy: no grant from `tag:vms-site` to anything.
    The example policy replaces the default allow-all.
  - Tailscale SSH is not used.

### OpenSSH Server

- What: the in-box Windows feature (preinstalled on Server 2025). Remote shell and file copy.
- Why: built in, key-based, works with `ProxyJump` and `-L`.
- Key settings:
  - Installed if missing: `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`.
  - `sshd` StartupType Automatic; failure actions restart (reset 86400 s, restart after 5 s, 5 s, 30 s).
  - `C:\ProgramData\ssh\sshd_config` is written from `templates/sshd_config`. The original is
    kept once as `sshd_config.pre-vms-maint`. The candidate is checked with
    `sshd.exe -t -f <candidate>` before it replaces the live file; if invalid, the old file stays.
  - Directives: `PasswordAuthentication no`, `PubkeyAuthentication yes`,
    `PermitEmptyPasswords no`, `KbdInteractiveAuthentication no`, `AllowUsers <account>`,
    `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 60`, `ClientAliveCountMax 3`,
    `AllowTcpForwarding yes` (needed for `-L` and `ProxyJump`), `GatewayPorts no`,
    `PermitTunnel no`, `Subsystem sftp sftp-server.exe`, `LogLevel VERBOSE`, and the stock
    `Match Group administrators` block using `__PROGRAMDATA__/ssh/administrators_authorized_keys`.
  - `LogLevel VERBOSE` writes the key fingerprint of every login to the Event Log
    (`OpenSSH/Operational`).
  - `administrators_authorized_keys` is built from `keys/engineers.pub` (one key per line,
    comment = engineer name). The repo file is the source of truth; install replaces the
    content. ACL: Administrators and SYSTEM only.
  - `DefaultShell` is Windows PowerShell 5.1 (`HKLM:\SOFTWARE\OpenSSH`).

### Maintenance account

- What: local user, default `vmsmaint`, member of `Administrators`.
- Why: one named account for `AllowUsers`, separate from customer and operator accounts.
- Key settings: random 32-character password generated at creation, shown once on the
  console for the company vault, never stored on disk. Key login does not use it; it is for
  break-glass local console only. `PasswordNeverExpires`. Hidden from the sign-in screen
  (`Winlogon\SpecialAccounts\UserList`, value 0). If the account already exists, its password
  is left alone and only group membership is ensured.

### Firewall

- What: one scoped inbound rule.
- Why: the stock rule allows SSH from any source.
- Key settings: disable `OpenSSH-Server-In-TCP`. Add `VMS-Maint-SSH-In`: TCP 22 inbound, all
  profiles, RemoteAddress `100.64.0.0/10`, `fd7a:115c:a1e0::/48` and the configured LAN
  subnets. The LAN entry allows the cross-machine fallback jump and local management when
  external access is off. This layer adds no other inbound rule. The rule is unchanged by the
  Cloudflare path: cloudflared reaches sshd via loopback, which Windows Firewall does not
  filter.

### Power

- What: keep the machine awake and reachable.
- Key settings: AC standby timeout 0, hibernate off (`powercfg`). BIOS "power on after AC
  loss" cannot be scripted; it is an on-site checklist item (see the runbook).

### Watchdog

- What: scheduled task `\IDENMATIC\VMS-Maintenance-Watchdog`, runs as SYSTEM, at startup
  (1 minute delay) and every 5 minutes. Runs `Test-Maintenance.ps1 -Repair -Quiet`.
- Why: service recovery actions cover a crash; the watchdog covers a service that was
  stopped or disabled (sshd, `VMS-Maint-Cloudflared`, Tailscale), a disabled firewall rule, and drift from the desired access state.
- Logs: one line per run, only when something is repaired or failing, to
  `C:\ProgramData\IDENMATIC\maintenance\logs\watchdog-YYYYMM.log`. Logs older than 12 months
  are deleted.

### Desired state

- What: `C:\ProgramData\IDENMATIC\maintenance\state.json`:
  `{ "externalAccess": "enabled"|"disabled", "changedAt": ISO8601, "changedBy": "<user>", "reason": "<text>" }`.
  ACL: Administrators and SYSTEM.
- Why: the watchdog needs one place to read what the state should be.
- Initial state at install: `disabled` only if no provider is active (configured and not
  skipped); otherwise `enabled`.
- Install copies the **whole layer** (all scripts, `lib\`, `templates\`, the keys file as
  `bin\keys\engineers.pub`, and the resolved config as `bin\site.psd1`) to
  `C:\ProgramData\IDENMATIC\maintenance\bin\`. The watchdog does not depend on where the install
  folder was unpacked (a USB stick may be removed), and every later re-run (keys, script
  update) works remotely from that copy.
- The maintenance root has a protected ACL (Administrators + SYSTEM only, inherited by
  everything below). Without it, `C:\ProgramData` lets standard users create files there, and
  the SYSTEM watchdog would run code a desk user could plant. `Test-Maintenance.ps1` checks it.

### Applying sshd changes over SSH

When install changes `sshd_config` from inside an SSH session, it does not restart sshd under
its own session. It registers a one-shot SYSTEM task (`\IDENMATIC\VMS-Maintenance-SshdRestart`)
that restarts sshd about 30 seconds later and removes itself. Outside SSH it restarts inline.

## Why these tools

| Choice | Reason |
|---|---|
| Cloudflare Tunnel + Access (primary) | Outbound-only tunnel, IdP + MFA, free plan. See "Why Cloudflare (Option A)" below. |
| Tailscale (optional fallback) | Outbound-only tunnel, SSO + MFA, ACLs, device kill switch. Plan: Standard, $8/user/month, 50 tagged devices included, then $1/device/month. The Personal plan is non-commercial only, so it is not used. |
| Windows OpenSSH, not Tailscale SSH | The Tailscale SSH server is not available on Windows. |
| SSH, not WinRM | WinRM is awkward outside a domain and does not give port forwarding. SSH gives shell, file copy, `-L` and `ProxyJump`. |
| No bastion host | Cloudflare Access (or the tailnet) already provides the controlled entry point; a bastion would be one more thing to run. |

### Why Cloudflare (Option A)

Decision: owner, 2026-10-26.

- Why Cloudflare over Tailscale: cost. Cloudflare Zero Trust free plan vs Tailscale Standard
  ($8/user/month); Tailscale's free Personal plan is non-commercial.
- Why Option A (public hostname + Access) over the WARP client: a per-machine hostname ->
  `localhost:22` avoids overlapping customer LAN ranges (no virtual networks), exposes only SSH
  and not the site LAN, and keeps plain OpenSSH so `ssh -J`, port forwarding and `scp` keep
  working.
- Why not Access for Infrastructure: it needs the WARP client, does not support
  ProxyJump or port forwarding, and documents Linux targets only.
- Tailscale is kept as an optional fallback. There is no automatic failover; the engineer
  chooses the path by hand.

## External access on/off

`SetAccess-Maintenance.ps1 -State Enabled|Disabled|Status [-Reason <text>] [-AuthKey <secure>] [-Force]`

One switch for all configured paths (Cloudflare, and Tailscale if configured).

- Disabled: write state, stop and disable `VMS-Maint-Cloudflared`; if Tailscale is configured,
  also `tailscale down`, stop the Tailscale service and set it to Disabled. sshd and the LAN
  rule stay, so local and LAN management continue. The watchdog keeps it off.
- Enabled: write state, set the services to Automatic and start them; for Tailscale,
  `tailscale up --unattended=true` with the same flags as install. If the Tailscale node was
  logged out or removed from the tailnet, `-AuthKey` is required. The Cloudflare token is
  read from the stored token file, so no token parameter is needed.
- Status: shows the Cloudflare service and hostname (and Tailscale if configured).
- Safety: `-State Disabled` is refused unless `-Force` inside an SSH session that arrives
  through an external path, because it cuts the caller's own session. Tailnet sessions have
  `$env:SSH_CLIENT` starting with `100.` or `fd7a:115c:a1e0:`. Cloudflare sessions arrive from
  localhost, because cloudflared delivers SSH from localhost: `SSH_CLIENT` starts with
  `127.0.0.1` or `::1`.
- Our-side kill switch (documented, not scripted): in the Cloudflare dashboard, disable or
  delete the tunnel, or remove the engineer from the Access policy. For Tailscale: remove or
  disable the grant in the tailnet policy, or disable the device in the admin console.
- Every change is appended to `logs\access-changes.log` (who, when, from where, reason).

## Verification and watchdog

`Test-Maintenance.ps1 [-Repair] [-Quiet] [-Json]` is read-only unless `-Repair`. Each check
returns `PASS`, `WARN` or `FAIL` with one line of detail. Exit code 0 if no FAIL, 1 if any
FAIL. `-Json` prints an array of `{ id, status, detail }`.

Checks: elevation, OS build (Windows 10 1809 / Server 2019 or later), PowerShell 5.1+;
maintenance account (exists, enabled, Administrators, hidden); OpenSSH installed, `sshd`
running and Automatic, failure actions; effective config from `sshd.exe -T`;
`administrators_authorized_keys` (exists, at least one key, ACL, key count and comments);
maintenance root ACL (protected, Administrators + SYSTEM only); firewall rules; port 22 listening; Cloudflare checks (below); Tailscale version and service state against the
desired state; when enabled, `tailscale status --json` (BackendState Running, tag, key expiry,
hostname, Online) and the unattended preference (WARN if the command is unavailable); when
disabled, service Stopped and Disabled; watchdog task registered, enabled, SYSTEM, last
result; power (WARN); time sync status (WARN); free disk of at least 5 GB on the system
drive (WARN); installed `bin` copy matches the repo `VERSION` (WARN on drift).

Cloudflare checks: `cloudflared-installed`, `cloudflared-token`, `cloudflared-service`,
`cloudflared-recovery`, `cloudflared-ready`. `cloudflared-ready` does
GET `http://127.0.0.1:20241/ready` and is PASS when HTTP 200 and `readyConnections` > 0.
Tailscale checks appear only when Tailscale is configured.

What `-Repair` may do: start stopped sshd, `VMS-Maint-Cloudflared` or Tailscale services,
restore their StartupType, re-apply the Cloudflare service state and recovery actions,
re-enable the `VMS-Maint-SSH-In` rule, and enforce the desired external-access state.

What `-Repair` may not do: rewrite `sshd_config`, change keys, change the account, change
ACLs, download cloudflared, touch the tunnel token, or touch anything else. Those need an explicit install run.

## Failure scenarios

| Scenario | What keeps access / recovery |
|---|---|
| VMS app / Docker / VM broken | Unaffected. The layer is on the Windows host with no dependency on Parts 2 or 3. |
| Windows reboot / power cut | sshd, `VMS-Maint-Cloudflared` (and Tailscale, unattended mode) are Automatic, watchdog at startup. BIOS power-on after AC loss is an on-site checklist item. |
| sshd, cloudflared or Tailscale crashes or is stopped | Service recovery actions; the watchdog restarts within 5 minutes. |
| Tunnel broken on one machine | Jump through the other machine over the LAN, or switch by hand to the other path if Tailscale is configured. |
| Bad `sshd_config` | Install validates before swapping; the watchdog never touches config; LAN or console fallback. |
| Internet outage | External access lost. LAN access and VMS local operation are unaffected. |
| Cloudflare (vendor) outage | Switch by hand to Tailscale if configured; otherwise on-site or the customer. Accepted risk. |
| Tailscale (vendor) outage | Existing peer connections may continue; new ones may fail. Use the Cloudflare path. |
| Cloudflare tunnel token leaked | Rotate/refresh the tunnel token in the Cloudflare dashboard, then re-run Install with `-TunnelToken`. |
| Engineer laptop lost / person leaves | Remove from the IdP group (and the Access policy) and from `keys/engineers.pub`, re-run the key step on each site. |
| Both machines down, router down, hardware failure | On-site intervention required. |

## Security

- MFA through the company IdP on Cloudflare Access (and on Tailscale, if used).
- Cloudflare: one Access application for `*.maint.<domain>`, Allow policy for the engineers
  group only. Each tunnel publishes only `ssh://localhost:22`; the site LAN is not exposed.
- Tunnel token: stored on the machine in `secrets\cloudflared-token` (Administrators + SYSTEM
  only), passed with `--token-file`, never on the service command line.
- Tailnet ACL (if used): engineers to site only, tcp:22 only. No site-to-site, no
  site-to-engineer. One-time, pre-tagged auth keys.
- SSH keys only, one allowed account, ed25519 key per engineer, passphrase protected.
- Firewall scoped to the tailnet and the LAN. No inbound port for Cloudflare.
- The account password lives only in the company vault.
- Audit: Cloudflare Access logs (free plan keeps them up to 24 hours only, so they are not a
  long-term record), Tailscale admin console (if used), Windows Event Log
  (`Microsoft-Windows-OpenSSH/Operational`, which keeps the key fingerprint of every login),
  and `access-changes.log`.

## Out of scope

Hyper-V, VM, WSL, Docker, Visitor Operator, app updates and rollback, backups of app data,
PowerShell 7, remote desktop or GUI tools, time-bounded sessions (possible later), and an
uninstall script (manual removal steps are in the runbook).

## Open questions

- Per-engineer Windows accounts or one shared `vmsmaint` with per-key fingerprints in the
  logs. Current choice: shared account, per-engineer keys, because it is simpler.
- BIOS power-on after AC loss cannot be scripted. It is handled as an on-site checklist item.
