# Maintenance layer (Part 1)

Makes a site's Server PC and Desk PC remotely maintainable (Cloudflare Tunnel (primary) or Tailscale (fallback) + Windows OpenSSH)
before, and independently of, any VMS application. Design:
[`ARCHITECTURE.md`](ARCHITECTURE.md). Step-by-step tasks: [`RUNBOOK.md`](RUNBOOK.md).

## Scripts — what each is for

The three entry scripts share the `-Maintenance` suffix (one layer) and differ by action.
They are **not a sequence**: install once, then use the other two whenever needed.

| Script | When | Run by | Changes the machine? |
|---|---|---|---|
| `Start-Install.cmd` | **First install only**, on site. Double-click; it elevates and runs `Install-Maintenance.ps1` | Person at the machine | Yes (via Install) |
| `Install-Maintenance.ps1` | First install, and every re-run: rotate keys (`-Only Keys`), apply updated scripts. Idempotent; ends by running the verification | Engineer (on site first, then over SSH) | Yes |
| `Test-Maintenance.ps1` | Any time you want a health check. Also runs every 5 minutes as the watchdog (`-Repair -Quiet`) | Engineer / watchdog task | No (only with `-Repair`: restarts services, re-enables the firewall rule, re-applies access state) |
| `SetAccess-Maintenance.ps1` | Only when someone decides to turn outside access on or off (`-State Enabled\|Disabled\|Status`) | Engineer | Yes (Cloudflare tunnel and Tailscale services only; SSH over the LAN stays) |

Only one order matters: **Install comes first.** Test and SetAccess read what Install set
up (`C:\ProgramData\IDENMATIC\maintenance\`), so they fail until Install has run.

After the first install every script is also available on the machine itself, in
`C:\ProgramData\IDENMATIC\maintenance\bin\`, so later runs work over SSH without copying
this folder again.

## Supporting files

| Path | Purpose |
|---|---|
| `lib/MaintenanceCommon.ps1` | Shared functions, dot-sourced by the scripts. Never run directly |
| `templates/sshd_config` | SSH server config written by Install |
| `config/site.example.psd1` | Copy to `config/<site>-<role>.psd1`, one per machine (real configs are gitignored) |
| `keys/engineers.pub.example` | Copy to `keys/engineers.pub`: one ed25519 public key per engineer |
| `examples/tailnet-policy.example.hujson` | Tailscale access policy (fallback only) to apply in the admin console |
| `examples/ssh_config.example` | Engineer laptop `~/.ssh/config` entries (Cloudflare primary, Tailscale fallback) |
