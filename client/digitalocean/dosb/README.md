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
| `dosb connect-droplet [droplet]` | `exec` into `ssh` (bounded readiness retry), forwarding the GitHub agent. `--no-forward-agent` to skip. |
| `dosb setup-github` | Create the GitHub-only SSH key and register it on your account via `gh`. Idempotent. |

## GitHub access from droplets (agent forwarding)

Droplets never hold a GitHub credential. Instead, `connect-droplet` forwards a
**dedicated ssh-agent that holds only a GitHub key**, so `git pull`/`git push`
on the droplet work while you're connected, and nothing usable is left behind
on the droplet or baked into a snapshot.

One-time setup (needs the [GitHub CLI](https://cli.github.com), logged in):

```sh
gh auth refresh -h github.com -s admin:public_key   # if gh lacks the scope
dosb setup-github
```

This generates `~/.ssh/github_ed25519` (no passphrase) if missing, registers it
on your GitHub account as an authentication key titled
`dosb-github (<hostname>)`, and verifies it with `ssh -T git@github.com`.

On every `connect-droplet`, dosb then:

1. checks the agent on `~/.ssh/agent-github.sock` (`ssh-add -l`);
2. starts it (`ssh-agent -a <sock>`) if it isn't running, clearing a stale
   socket from a previous boot;
3. loads the key with `ssh-add -t 8h` if it isn't loaded;
4. execs `ssh ... -o ForwardAgent=<sock>`.

Only that agent is forwarded — your regular agent (which logs you into the
droplet) is not exposed. If the key is missing or the agent can't be prepared,
dosb warns and connects **without** forwarding rather than failing. Pass
`--no-forward-agent` to opt out for one session.

Trade-off: while you're connected, root on the droplet can use the forwarded
agent to talk to GitHub as you. It cannot extract the key, and access ends when
you disconnect.

The droplet side (pinned GitHub host keys, a stable `SSH_AUTH_SOCK` for tmux)
is configured by `server/bootstrap_server.sh`.

Paths are configurable via `github_identity_file` and `github_agent_socket`.

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
