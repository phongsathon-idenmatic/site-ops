# VMS site operations

Site operations for customer deployments: one Server PC and one Desk PC on the customer LAN.
This folder holds what engineers need to reach, prepare and run those machines.

## Three responsibilities

| # | Name | Scope | Not in it | Depends on | Status |
|---|---|---|---|---|---|
| 1 | Maintenance layer (`maintenance/`) | Remote connectivity (Cloudflare Tunnel (primary) or Tailscale (fallback)), remote shell (Windows OpenSSH Server), maintenance account and keys, firewall scoping, service recovery and watchdog, enable/disable external access, verification | Hyper-V, VM, Docker, Visitor Operator, any VMS app; app deploy and update | Windows only (internet once to install cloudflared or Tailscale; Cloudflare or Tailscale coordination for external access). Nothing in Parts 2 or 3 | Implemented |
| 2 | Machine preparation (`deployment/`, future) | Server: Windows settings, Hyper-V role, VM creation (Ubuntu LTS), VM sshd, docker-ce, VM autostart, time sync. Desk: Windows prep for the existing NSIS installer (per-machine install, launch task, operator account/autologon decision, reader runtimes such as EPRAssist) | Remote access itself; VMS app versions | Part 1 (installed and verified first; Part 2 is performed through it) | Not started |
| 3 | VMS system (`vms/` or in each project, future) | Docker Compose stack (VMS Core, Admin Web, future services), Visitor Operator releases, app config, update, rollback, removal, backups of app data | OS and VM preparation; remote access | Part 2 (runtime present) and, for remote operation, Part 1 | Not started |

### 1. Maintenance layer

Keeps the two Windows machines reachable and manageable by engineers, with no site visit.
It lives on the Windows host and knows nothing about the VM, Docker or the apps.
Scripts and when to use each: [`maintenance/README.md`](maintenance/README.md).
Design: [`maintenance/ARCHITECTURE.md`](maintenance/ARCHITECTURE.md).
Procedures: [`maintenance/RUNBOOK.md`](maintenance/RUNBOOK.md).

### 2. Machine preparation

Turns a bare Windows machine into one that can run the VMS system. Not started. It does not
touch remote access and does not choose app versions.

### 3. VMS system

The applications themselves and their lifecycle (update, rollback, removal, data backup).
Not started. It does not prepare the OS or the VM and does not manage remote access.

## Dependency rule

The direction is one-way: 3 depends on 2, 2 depends on 1. Part 1 never depends on 2 or 3.

Why: a broken VM, a broken Docker install or a crashed Visitor Operator must not remove
remote access. If Part 1 needed any of them, the failure that most needs a remote fix would
also lock the engineer out.

Parts 2 and 3 run over the maintenance layer (through its SSH access). They never modify its
files or settings.

## Order at a new site

1. Part 1: install on each machine locally (elevated PowerShell, one command), then verify
   locally. See the first two tasks in the runbook.
2. Everything else is remote: re-runs of Part 1, then Part 2, then Part 3.

## Existing material Parts 2 and 3 will reuse

Pointers only. They are not part of Part 1.

- [`../projects/VMS-core/deploy/docker-beta/`](../projects/VMS-core/deploy/docker-beta/) -
  compose file, Dockerfile, env/secrets script, backup commands
- [`../projects/visitor-operator/electron-builder.config.cjs`](../projects/visitor-operator/electron-builder.config.cjs) -
  NSIS installer config
- [`../projects/visitor-operator/docs/desk-provisioning.md`](../projects/visitor-operator/docs/desk-provisioning.md) -
  desk machine provisioning

## Decisions

Owner, 2026-10-26.

- Docker is permanent for VMS services. It is not being reconsidered.
- Engineers have standing remote access during the initial deployment phase. It may be
  disabled once the site is stable; machines are then managed locally (on-site, LAN, or via
  VMS Core).
- This supersedes the earlier "remote support is core-only, customer-opened, never
  always-on" rule and the earlier "updates are delivered by hand, no internet at deploy time"
  rule.
- Local VMS operation must keep working without internet.
