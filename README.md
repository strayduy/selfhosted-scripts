# selfhosted-scripts

Setup and management scripts for the Digital Ocean droplets that host my
personal web apps. Targets **Ubuntu 24.04 LTS** (Noble) exclusively — the
scripts will refuse to run on other versions.

## Layout

```
selfhosted-scripts/
├── server/
│   ├── bootstrap_server.sh        # Initial droplet hardening (users, SSH, UFW, fail2ban, ...)
│   ├── finalize_tailscale.sh      # Join/rejoin the tailnet (no-key bootstrap, snapshot copies)
│   └── setup_rootless_podman.sh   # Create a rootless-Podman service account
├── lib/
│   ├── common.sh                  # Logging + preflight helpers
│   └── tailscale.sh               # Tailscale helpers shared by the server/ scripts
├── vaultwarden/
│   └── setup_vaultwarden.sh       # Deploy Vaultwarden behind Tailscale TLS
├── client/                        # Tools run from a client laptop, not the droplet
│   └── digitalocean/
│       ├── fleeting-spec.md       # Design spec for the fleeting CLI
│       └── fleeting/              # Rust CLI for ephemeral sandbox droplets
├── AGENTS.md                      # Conventions for humans/AI editing this repo
└── README.md
```

> **Convention:** top-level app/role directories (`server/`, `vaultwarden/`) run
> *on* the droplet, as `root`, on Ubuntu 24.04. Anything under `client/` runs
> from your **laptop** instead — e.g. `client/digitalocean/fleeting` drives the
> DigitalOcean API to create and tear down throwaway droplets.

## Typical droplet flow

1. **Provision** a fresh Ubuntu 24.04 droplet on Digital Ocean.
2. **Bootstrap** as `root`:
   ```bash
   ssh root@<ip>
   apt-get update && apt-get install -y git
   git clone https://github.com/strayduy/selfhosted-scripts.git
   cd selfhosted-scripts
   ./server/bootstrap_server.sh <username> 2222 --tailscale
   ```
   This creates the admin user, hardens SSH, enables UFW/fail2ban/unattended-upgrades,
   and optionally joins the machine to Tailscale. With `--tailscale` you'll be
   prompted (input hidden) for an auth key, so it never lands in shell history.
3. **Reconnect** as the new user on the new SSH port.
4. **(Per-app)** Create a dedicated service account for rootless containers, e.g.:
   ```bash
   sudo ./server/setup_rootless_podman.sh vaultwarden
   ```
5. **(Per-app)** Run the app's setup script, e.g.:
   ```bash
   sudo ./vaultwarden/setup_vaultwarden.sh my-droplet.tail1234.ts.net
   ```

## Scripts

### `server/bootstrap_server.sh`

One-shot droplet hardening. Run **once**, as `root`, immediately after the
droplet boots for the first time.

```
Usage: bootstrap_server.sh <username> [ssh_port] [--tailscale] [--ts-ssh]
```

What it configures:

- Creates an admin user, grants `sudo`, copies root's `authorized_keys`.
- Hardens `sshd` via `/etc/ssh/sshd_config.d/00-bootstrap.conf` (no password auth, no root login, custom port) and verifies the effective config with `sshd -T`.
- UFW firewall — SSH only by default; web ports must be opened manually.
- Fail2Ban for `sshd` (12 h bans).
- `unattended-upgrades` for security updates, auto-rebooting at 11:00 UTC (4 AM PDT / 3 AM PST) when an update requires it.
- pam_pwquality password policy (enforced before the admin password is set).
- Kernel hardening via `/etc/sysctl.d/99-hardening.conf`.
- 2 G swap file, `vm.swappiness=10`.
- chrony, AppArmor (stock profiles), `noexec,nosuid,nodev` on `/dev/shm`, 5-minute sudo credential cache.
- GitHub's SSH host keys pinned in `/etc/ssh/ssh_known_hosts`, plus an
  `/etc/ssh/sshrc` + `/etc/tmux.conf` pair that keeps a forwarded agent usable
  inside tmux across reconnects (see fleeting's GitHub agent forwarding below).
- Optional Tailscale install (pinned version, hash-verified) + Tailscale SSH.
- With Tailscale: a cloud-init first-boot hook so droplets created from a
  snapshot get a fresh Tailscale identity (see `finalize_tailscale.sh`).

Settings from the last run are kept in `/etc/bootstrap_server.conf`.

The script is **partly idempotent** — most steps are safe to re-run, but it's
intended as a one-shot.

### `server/finalize_tailscale.sh`

Joins (or rejoins) the tailnet after `bootstrap_server.sh --tailscale`. Prompts
for an auth key (hidden; leave blank to log in via URL), runs `tailscale up`
(with `--ssh` if bootstrap used `--ts-ssh`), and — after confirmation — closes
the public SSH port when Tailscale SSH is enabled.

Run it when:

- bootstrap ran without an auth key, or
- on a droplet created from a snapshot. A snapshot carries the original
  node's Tailscale identity, so copies would fight over it. A cloud-init
  per-instance hook wipes `tailscaled.state` on the copy's first boot,
  temporarily reopens the public SSH port if Tailscale SSH had closed it,
  and shows a login message until this script has run.

```
Usage: sudo ./server/finalize_tailscale.sh
```

### `server/setup_rootless_podman.sh`

Creates an unprivileged system account configured to run rootless Podman
containers under systemd-lingered sessions. Use one account per app.

```
Usage: sudo ./setup_rootless_podman.sh [username]    # default: podman
```

Handles all the Ubuntu-24.04-specific footguns: subuid/subgid allocation,
cgroup delegation via `user@.service`, `net.ipv4.ip_unprivileged_port_start=443` so
containers can bind to 443 without root, the network-backend pinning for
Podman v5+, and a smoke test.

### `vaultwarden/setup_vaultwarden.sh`

Deploys [Vaultwarden](https://github.com/dani-garcia/vaultwarden) in a rootless
Podman container, managed by a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
unit under the dedicated `vaultwarden` user's systemd session. TLS is terminated
by Vaultwarden itself using a certificate issued by `tailscale cert` (no nginx,
no Let's Encrypt). The service is reachable only over the tailnet — the port is
bound to the Tailscale interface IP.

```
Usage: sudo ./setup_vaultwarden.sh <tailscale-hostname> [--port 443] [--admin-token <token>]
       sudo ./setup_vaultwarden.sh harden                  # disable signups + admin UI
       sudo ./setup_vaultwarden.sh update [1.35.5]         # roll forward to a new image
       sudo ./setup_vaultwarden.sh cert-refresh <host>     # called by daily cron
```

**Prerequisites:**

- Tailscale is up and authenticated.
- MagicDNS and HTTPS certificates are enabled in the Tailscale admin console.
- A `vaultwarden` system user exists (run `setup_rootless_podman.sh vaultwarden` first).

After setup, visit `https://<tailscale-hostname>`, create your account, then run
`sudo ./setup_vaultwarden.sh harden` to disable signups and the `/admin` interface.

**Updating.** Never re-run `setup` to update — it regenerates the admin token and
undoes `harden`. Use the `update` subcommand instead: it stops the container,
tars `/srv/vaultwarden` into `/root/vaultwarden-backups/`, repins `Image=` in the
quadlet, restarts, health-checks `/alive`, and automatically rolls back to the
previous image if the new one fails to come up. With no argument it updates to
the `VW_IMAGE` version pinned at the top of the script; bump that constant in
the repo too so fresh installs match. `update <version>` also works; the
quadlet is then pinned to the digest that was actually pulled, so a later
re-push of that tag can't change what runs.

### `client/digitalocean/fleeting`

A small Rust CLI (run from your **laptop**, not the droplet) for managing
**ephemeral sandbox droplets** used as throwaway agentic-coding environments. It
calls the DigitalOcean v2 API directly — no `doctl` — and reads its token only
from `DIGITALOCEAN_ACCESS_TOKEN`. The workflow it automates: create a droplet
from a hardened snapshot → work → optionally snapshot → destroy.

```
fleeting init               # interactive first-run config (~/.config/fleeting/config.toml)
fleeting create-droplet     # create from a sandbox snapshot, block until active
fleeting list-droplets      # list ephemeral (tagged) droplets
fleeting list-snapshots     # list sandbox-prefixed snapshots
fleeting take-snapshot      # power off, snapshot, leave off
fleeting destroy-droplet    # destroy one droplet (type-the-name confirmation)
fleeting connect-droplet    # exec ssh into a droplet (forwards the GitHub agent)
fleeting setup-github       # one-time: create + register the GitHub-only key via gh
```

**GitHub access.** Droplets hold no GitHub credentials. `connect-droplet`
forwards a dedicated laptop-side ssh-agent that holds only a GitHub key, so
`git pull`/`push` work during attended sessions and nothing usable ends up in a
snapshot. See the fleeting README for details.

Migrating from per-repo keys stored on droplets (one-time):

1. Re-bootstrap a fresh droplet and take a new base snapshot.
2. Run `fleeting setup-github`, connect, and confirm `git push` works — including
   from a tmux pane after detaching and reconnecting.
3. Delete the old deploy keys on GitHub, then delete the old `sandbox-`
   snapshots that contain them (DigitalOcean console).
4. Point any `git@github.com-<repo>:` remotes back at `git@github.com:`.

Safety rails: droplet operations only ever act on `ephemeral`-tagged droplets,
and snapshot operations only on `sandbox-`prefixed images, so you can't
accidentally destroy a real server or boot a sandbox from the wrong image. A
global `--dry-run` validates inputs against the live API without making changes.

Build with a pinned toolchain (`mise install` then `cargo build --release`); see
[`client/digitalocean/fleeting/README.md`](./client/digitalocean/fleeting/README.md) and
[`client/digitalocean/fleeting-spec.md`](./client/digitalocean/fleeting-spec.md) for details.

Unlike the bash scripts, this is a Rust project and is **not** subject to the
Ubuntu-24.04 / `root` assumptions in `AGENTS.md`.

## Known gaps

- **No automated Vaultwarden backups.** The SQLite DB, `attachments/`,
  `rsa_key*` and `config.json` under `/srv/vaultwarden` live only on the
  droplet's disk; backups are manual (droplet snapshots). A daily off-droplet
  backup (e.g. restic to a versioned S3 bucket) is the natural next step.
- **AppArmor on older droplets.** Droplets bootstrapped before AppArmor
  mass-enforcement was removed (and snapshots of them) still have stripped
  stock profiles plus `setup_rootless_podman.sh`'s old unconfined overrides
  and `rootless-podman-apparmor.service`. They keep working; rebuild from a
  fresh droplet to get back to stock profiles.

## Conventions

See [`AGENTS.md`](./AGENTS.md) for the shared script style guide.

## License

Personal use; no license declared.
