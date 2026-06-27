# selfhosted-scripts

Setup and management scripts for the Digital Ocean droplets that host my
personal web apps. Targets **Ubuntu 24.04 LTS** (Noble) exclusively — the
scripts will refuse to run on other versions.

## Layout

```
selfhosted-scripts/
├── server/
│   ├── bootstrap_server.sh        # Initial droplet hardening (users, SSH, UFW, fail2ban, ...)
│   └── setup_rootless_podman.sh   # Create a rootless-Podman service account
├── vaultwarden/
│   └── setup_vaultwarden.sh       # Deploy Vaultwarden behind Tailscale TLS
├── digitalocean/
│   ├── dosb-spec.md               # Design spec for the dosb CLI
│   └── dosb/                      # Rust CLI for ephemeral sandbox droplets (runs on laptop)
├── AGENTS.md                      # Conventions for humans/AI editing this repo
└── README.md
```

> **Note:** everything under `server/` and `vaultwarden/` runs *on* the droplet.
> `digitalocean/dosb` is different — it's a Rust CLI you run from your **laptop**
> to create and tear down throwaway droplets via the DigitalOcean API.

## Typical droplet flow

1. **Provision** a fresh Ubuntu 24.04 droplet on Digital Ocean.
2. **Bootstrap** as `root`:
   ```bash
   ssh root@<ip>
   apt-get update && apt-get install -y git
   git clone https://github.com/strayduy/selfhosted-scripts.git
   cd selfhosted-scripts
   ./server/bootstrap_server.sh <username> 2222 --tailscale --ts-authkey tskey-auth-...
   ```
   This creates the admin user, hardens SSH, enables UFW/fail2ban/unattended-upgrades,
   and optionally joins the machine to Tailscale.
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
Usage: bootstrap_server.sh <username> [ssh_port] [--tailscale] [--ts-authkey <key>] [--ts-ssh]
```

What it configures:

- Creates an admin user, grants `sudo`, copies root's `authorized_keys`.
- Hardens `sshd` (no password auth, no root login, modern ciphers/MACs/KEX, custom port).
- UFW firewall — SSH only by default; web ports must be opened manually.
- Fail2Ban for `sshd` (12 h bans).
- `unattended-upgrades` for security updates.
- pam_pwquality + pam_faillock for password policy and account lockout.
- Kernel hardening via `/etc/sysctl.d/99-hardening.conf`.
- 2 G swap file, `vm.swappiness=10`.
- chrony, AppArmor enforcement, sudo logging/hardening.
- Optional Tailscale install (pinned version, hash-verified) + Tailscale SSH.

The script is **partly idempotent** — most steps are safe to re-run, but it's
intended as a one-shot.

### `server/setup_rootless_podman.sh`

Creates an unprivileged system account configured to run rootless Podman
containers under systemd-lingered sessions. Use one account per app.

```
Usage: sudo ./setup_rootless_podman.sh [username]    # default: podman
```

Handles all the Ubuntu-24.04-specific footguns: subuid/subgid allocation,
cgroup delegation via `user@.service`, the AppArmor profile patch for
`podman`/`crun`/`slirp4netns`, `net.ipv4.ip_unprivileged_port_start=443` so
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
       sudo ./setup_vaultwarden.sh cert-refresh <host>     # called by daily cron
```

**Prerequisites:**

- Tailscale is up and authenticated.
- MagicDNS and HTTPS certificates are enabled in the Tailscale admin console.
- A `vaultwarden` system user exists (run `setup_rootless_podman.sh vaultwarden` first).

After setup, visit `https://<tailscale-hostname>`, create your account, then run
`sudo ./setup_vaultwarden.sh harden` to disable signups and the `/admin` interface.

### `digitalocean/dosb`

A small Rust CLI (run from your **laptop**, not the droplet) for managing
**ephemeral sandbox droplets** used as throwaway agentic-coding environments. It
calls the DigitalOcean v2 API directly — no `doctl` — and reads its token only
from `DIGITALOCEAN_ACCESS_TOKEN`. The workflow it automates: create a droplet
from a hardened snapshot → work → optionally snapshot → destroy.

```
dosb init               # interactive first-run config (~/.config/dosb/config.toml)
dosb create-droplet     # create from a sandbox snapshot, block until active
dosb list-droplets      # list ephemeral (tagged) droplets
dosb list-snapshots     # list sandbox-prefixed snapshots
dosb take-snapshot      # power off, snapshot, leave off
dosb destroy-droplet    # destroy one droplet (type-the-name confirmation)
dosb connect-droplet    # exec ssh into a droplet
```

Safety rails: droplet operations only ever act on `ephemeral`-tagged droplets,
and snapshot operations only on `sandbox-`prefixed images, so you can't
accidentally destroy a real server or boot a sandbox from the wrong image. A
global `--dry-run` validates inputs against the live API without making changes.

Build with a pinned toolchain (`mise install` then `cargo build --release`); see
[`digitalocean/dosb/README.md`](./digitalocean/dosb/README.md) and
[`digitalocean/dosb-spec.md`](./digitalocean/dosb-spec.md) for details.

Unlike the bash scripts, this is a Rust project and is **not** subject to the
Ubuntu-24.04 / `root` assumptions in `AGENTS.md`.

## Conventions

See [`AGENTS.md`](./AGENTS.md) for the shared script style guide.

## License

Personal use; no license declared.
