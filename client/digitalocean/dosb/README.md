# dosb

A small Rust CLI for managing **ephemeral DigitalOcean sandbox droplets**, built
around one workflow: create a droplet from a hardened snapshot → work → optionally
snapshot → destroy.

See [`../dosb-spec.md`](../dosb-spec.md) for the full design.

## Build

A Rust toolchain is pinned via `mise.toml` (`rust = "stable"`).

```sh
mise install        # installs the pinned toolchain
cargo build --release
```

The binary lands at `target/release/dosb`.

## Setup

1. Export your DigitalOcean API token (read **only** from the environment; never
   stored on disk):

   ```sh
   export DIGITALOCEAN_ACCESS_TOKEN=dop_v1_...
   ```

2. Create the config interactively:

   ```sh
   dosb init
   ```

   This writes `~/.config/dosb/config.toml`. Override the path with `--config`
   or `DOSB_CONFIG`.

## Commands

| Command | Description |
|---|---|
| `dosb init` | Interactive first-run setup; writes the config file. |
| `dosb create-droplet` | Create a droplet from a sandbox snapshot (interactive picker, or `--snapshot`). Blocks until active. |
| `dosb list-droplets` | List ephemeral (tagged) droplets. |
| `dosb list-snapshots` | List sandbox-prefixed snapshots. |
| `dosb take-snapshot [droplet]` | Power off, snapshot, leave off. `--keep-running`, `--live`, `--label`, `--yes`. |
| `dosb destroy-droplet [droplet]` | Destroy one ephemeral droplet (type-the-name confirmation). |
| `dosb connect-droplet [droplet]` | `exec` into `ssh` (bounded readiness retry). |

## Dry-run

Pass the global `--dry-run` flag to any mutating command to validate inputs
against the real API (snapshot/SSH-key/droplet lookups, region availability)
without making any changes — it prints what *would* happen instead:

```sh
dosb create-droplet --snapshot sandbox-base-20260627T1430Z --dry-run
dosb take-snapshot sandbox-foo-20260627T1500Z --dry-run
dosb destroy-droplet sandbox-foo-20260627T1500Z --dry-run
dosb connect-droplet sandbox-foo-20260627T1500Z --dry-run
```

Read-only commands (`list-droplets`, `list-snapshots`) are unaffected.

## Safety model

- Droplet operations only ever act on droplets carrying the configured `tag`
  (default `ephemeral`). Untagged droplets are never listed or targeted.
- Snapshot operations only ever consider images whose name starts with the
  configured `snapshot_prefix` (default `sandbox-`).
