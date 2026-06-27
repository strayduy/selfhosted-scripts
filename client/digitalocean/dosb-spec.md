# `dosb` — DigitalOcean sandbox CLI spec

A Rust CLI for managing **ephemeral sandbox droplets** on DigitalOcean. It is a
scoped-down workflow tool built around a single loop:

> create a droplet from a hardened snapshot → work on a hobby project → commit to
> the remote git repo → optionally take a new snapshot → destroy the droplet.

It deliberately exposes only the operations that loop needs, with safety rails so
you can never accidentally destroy a non-sandbox droplet or boot from a
non-sandbox snapshot.

---

## Architecture

- **Direct DigitalOcean REST API** access over HTTP (e.g. `reqwest` + `serde`).
  **No** `doctl` dependency — the surface we need is ~6 endpoints
  (list/create/delete droplets, list/create/delete snapshots, list SSH keys,
  list regions/sizes), and typed responses make polling and error handling
  cleaner.
- Run from the **laptop**, not from inside a droplet.
- Ephemeral droplets do **not** use Tailscale (short-lived, disposable). They are
  reached over their public IP using an SSH key on a custom port.

## Authentication

- Token is read **only** from the `DIGITALOCEAN_ACCESS_TOKEN` environment
  variable (the same var `doctl`/Terraform use).
- A preflight check runs at startup for any command that hits the API: if the var
  is unset, fail fast with a message naming the variable. Surface API `401`s
  plainly.
- The token is **never** stored in the config file. If a token is found in the
  config, ignore it (and optionally warn).

## Configuration

- Format: **TOML**.
- Location: `~/.config/dosb/config.toml` (XDG). Override with `--config <path>` or
  the `DOSB_CONFIG` env var. Use an XDG-aware crate so paths are correct on macOS
  too.
- Precedence for every value: **command-line flag > environment variable >
  config file > built-in default**.

```toml
region          = "sfo3"             # fixed region (snapshots are region-bound)
size            = "s-2vcpu-4gb"      # default droplet size, overridable per-run
ssh_key_name    = "my-laptop"        # DO-registered SSH key injected at create
tag             = "ephemeral"        # tag applied to every created droplet
snapshot_prefix = "sandbox-"         # naming-convention filter for snapshots
ssh_user        = "myuser"           # SSH login user for connect-droplet
ssh_port        = 2222               # SSH port for connect-droplet
identity_file   = "~/.ssh/id_ed25519" # SSH identity file for connect-droplet
```

- If a required value is missing everywhere, **hard-error** at runtime with a
  message naming the missing key and how to set it.
- First-run setup is handled by the `init` subcommand (below).

## Naming conventions

- **Shared prefix** for both droplets and snapshots: `sandbox-` (configurable via
  `snapshot_prefix`).
- Both droplets and snapshots are named:

  ```
  sandbox-<optional-label>-<UTC-timestamp>
  ```

  e.g. `sandbox-myproject-20260627T1430Z`. With no label: `sandbox-20260627T1430Z`.
- Timestamps are **UTC** (`YYYYMMDDThhmmZ`-style) so names sort chronologically
  and never collide.

## Safety model

- **Droplet operations** (`list-droplets`, `destroy-droplet`, `connect-droplet`,
  `take-snapshot`) filter strictly by the **`ephemeral` tag**. The droplet name is
  display-only — a `sandbox-`named droplet *without* the tag is never actionable.
- **Snapshot selection** (`create-droplet`, `list-snapshots`) filters strictly by
  the **`sandbox-` prefix**, so you can never boot a sandbox from an unintended
  image.

---

## Commands

Binary name: **`dosb`**. Verb-noun subcommand naming throughout.

### `init`
Interactive first-run setup. Prompts for each config value and writes
`~/.config/dosb/config.toml` (respecting `--config` / `DOSB_CONFIG`).

### `create-droplet`
Creates an ephemeral droplet from a sandbox snapshot.

- **Interactive snapshot picker** by default (filtered to `sandbox-` snapshots);
  `--snapshot <name-or-id>` to skip the picker.
- Overrides: `--size`, `--name`, `--label`.
- Always **injects the DO-registered SSH key** named by `ssh_key_name` (safety
  net on top of the key already baked into the snapshot).
- Always applies the **`ephemeral` tag**. Backups **off**.
- Validates the chosen snapshot is **available in the configured region** before
  the create call (clear error instead of a raw API rejection).
- **Blocks**, polling until the droplet is `active`, then prints the public IP and
  a ready-to-paste `ssh` line. (No `--no-wait`.)

### `list-droplets`
Aligned table of `ephemeral`-tagged droplets: name, ID, region, size, public IP,
status, age (from `created_at`). Prints a friendly "none found" when empty.

### `list-snapshots`
Aligned table of `sandbox-`prefixed snapshots: name, ID, size (GB), region(s),
age. Flags snapshots **not available in the configured region**. Friendly
"none found" when empty.

### `take-snapshot`
Snapshots an ephemeral droplet.

- Selection: `take-snapshot <name-or-id>` or interactive picker over
  `ephemeral`-tagged droplets.
- Optional `--label` for the snapshot name.
- **`[y/N]` confirmation** ("this will power off `<name>` and take a few
  minutes"), skippable with `--yes`.
- Default flow: **power off → snapshot → leave off** (the usual next step is
  destroy). Polls the snapshot action to completion with progress.
- Escape hatches: `--keep-running` (power back on afterward), `--live` (snapshot
  without powering off; faster, small risk of an inconsistent image).

### `destroy-droplet`
Destroys a single ephemeral droplet.

- Selection: `destroy-droplet <name-or-id>` or interactive picker over
  `ephemeral`-tagged droplets only. Untagged droplets are never offered or
  accepted.
- **Type-the-full-droplet-name confirmation** (stronger than `[y/N]` because it
  is irreversible).
- Single droplet only — no multi-destroy, no `--all`.

### `connect-droplet`
SSHes into an ephemeral droplet.

- Selection: `connect-droplet <name-or-id>` or interactive picker over
  `ephemeral`-tagged droplets.
- Resolves the public IP from the API and **execs**
  `ssh -i <identity_file> -p <port> <user>@<ip>` (config values, overridable by
  flags) — you land directly in the shell.
- **Bounded SSH-readiness retry** (~30s) so "create then immediately connect"
  works while sshd is still coming up.

---

## Output & error handling

- Human-readable **aligned tables** only for v1 (no `--json`).
- Colors gated on a TTY and `NO_COLOR` (same discipline as the repo's bash
  scripts).
- Surface DO API error messages verbatim.
- **Bounded retry with backoff** on `429` and transient `5xx`; keep it simple for
  v1.
- Empty states print a friendly "none found" rather than an empty table.

## Suggested module layout

```
dosb/
├── Cargo.toml
└── src/
    ├── main.rs        # entrypoint, dispatch
    ├── cli.rs         # clap definitions
    ├── config.rs      # load/merge config (flag > env > file > default)
    ├── api/           # DO REST client (droplets, snapshots, keys, regions)
    └── commands/      # one module per subcommand
```

## Out of scope (v1)

- `resize`, `restart`, `rebuild`.
- Multi-droplet destroy / `--all`.
- `--json` output.
- Tailscale integration for ephemeral droplets.
- Storing the API token anywhere on disk.
