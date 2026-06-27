# AGENTS.md

Conventions for humans and AI agents editing scripts in this repository.

## Repository purpose

Bash scripts for provisioning and managing personal Digital Ocean droplets
running **Ubuntu 24.04 LTS** (Noble). The scripts are run interactively as
`root` (or under `sudo`) on freshly-booted droplets. They are not libraries,
not portable across distros, and not intended for production multi-tenant use.

Always assume the target environment is Ubuntu 24.04. Scripts should refuse
to run on anything else.

### Server-side vs. client-side

The conventions in this file describe the **droplet-side bash scripts** — the
top-level role/app directories (`server/`, `vaultwarden/`, ...). These run as
`root` on Ubuntu 24.04.

Anything under **`client/`** is the exception: those tools run from a client
laptop, not the droplet. They are **not** bash, **not** run as root, and **not**
bound to Ubuntu 24.04, so the bash style guide, preflight checks (`require_root`,
`require_ubuntu`), and `apt`/systemd conventions below do **not** apply to them.
Each `client/` subtree carries its own tooling and conventions (e.g.
`client/digitalocean/dosb` is a Rust project with its own `Cargo.toml` and
pinned toolchain). When adding a laptop-run tool, place it under `client/`.

## Script style guide

These conventions apply to every `*.sh` file in the repo. When editing an
existing script that violates them, fix the violation in the same change
where reasonable — but do not reformat an entire file in an unrelated PR.

### File header

```bash
#!/usr/bin/env bash
#
# <one-line description>
#
# Usage: <how to invoke, including subcommands and flags>
#
# Prerequisites:
#   - <anything that must be true before running>
#
# What this script does:
#   1. ...
#   2. ...

set -euo pipefail
IFS=$'\n\t'
```

- **Shebang:** `#!/usr/bin/env bash` (not `#!/bin/bash`).
- **Strict mode:** always `set -euo pipefail`. Reset `IFS` to avoid splitting
  on spaces in command substitutions.
- **Error trap** (optional but recommended):
  ```bash
  trap 'error "Failed at line $LINENO (command: $BASH_COMMAND)"' ERR
  ```

### Structure

- Code lives in **functions**. The bottom of every script is:
  ```bash
  main "$@"
  ```
- A `main()` function orchestrates the work. Each numbered step is its own
  function: `install_dependencies`, `setup_user`, `configure_ufw`, etc.
- Section banners use the box-drawing style already in use:
  ```bash
  # ── Step 3: Configure SSH ─────────────────────────────────────────────────
  ```
- Multi-command scripts use a subcommand dispatch at the bottom (see
  `setup_vaultwarden.sh`):
  ```bash
  case "${1:-}" in
      setup)   shift; cmd_setup "$@" ;;
      harden)  cmd_harden ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
  esac
  ```

### Formatting

- **Indentation:** 4 spaces. Never tabs.
- **Line length:** soft limit 100 columns.
- **Quoting:** always quote variable expansions: `"$var"`, `"$@"`, `"${arr[@]}"`.
  Unquoted expansion is only acceptable for arithmetic in `(( ))`.
- **Tests:** use `[[ ... ]]`, never `[ ... ]`. Use `(( ... ))` for arithmetic.
- **Variables:** function-scope variables are declared `local`. Globals are
  `UPPER_SNAKE_CASE` and grouped at the top of the file. Locals are
  `lower_snake_case`.
- **Arrays for flag lists.** Never build up a string of flags and rely on
  word-splitting:
  ```bash
  # bad
  args=""
  [[ "$ssh" == true ]] && args="$args --ssh"
  tailscale up $args

  # good
  args=()
  [[ "$ssh" == true ]] && args+=(--ssh)
  tailscale up "${args[@]}"
  ```

### Logging helpers

Every script uses the same four logging functions, written to look identical
across the repo. Colours are nice-to-have; gate them on `[[ -t 1 ]]` and
`NO_COLOR` so output is clean in CI / log files:

```bash
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[0;31m'; _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[1;33m'; _C_BLUE=$'\033[0;34m'; _C_NC=$'\033[0m'
else
    _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""; _C_NC=""
fi

info()    { echo "${_C_BLUE}[INFO]${_C_NC}    $*"; }
success() { echo "${_C_GREEN}[OK]${_C_NC}      $*"; }
warn()    { echo "${_C_YELLOW}[WARN]${_C_NC}   $*" >&2; }
error()   { echo "${_C_RED}[ERROR]${_C_NC} $*" >&2; exit 1; }
```

Once two scripts share these helpers, factor them into `lib/common.sh`
and source them:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
```

### Preflight checks

Every script that mutates the system performs these checks **before** doing
any work:

```bash
require_root          # [[ $EUID -eq 0 ]] || error "must run as root"
require_ubuntu 24.04  # grep VERSION_ID in /etc/os-release
```

App-specific preflights (e.g. "Tailscale is up", "the `vaultwarden` user
exists") go in their own function called from the top of `main()`.

### Argument parsing

- Positional args come first, then `--long-flags`. Flags with values use
  `--flag value` (not `--flag=value`).
- Validate every input. Numerics get a regex check:
  ```bash
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
      || error "Invalid port: $port"
  ```
- Always implement `--help` / `-h` via a `usage()` function that prints a
  literal heredoc. Do not extract help text by grepping comments from `$0`.

### `apt` usage

- Always `apt-get`, never `apt`. `apt` is documented as an unstable CLI for
  interactive use.
- Set `DEBIAN_FRONTEND=noninteractive` for unattended runs:
  ```bash
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends fail2ban ufw ...
  ```

### Idempotency

Every step must be safe to re-run. Prefer:

- **Drop-in config files** under `/etc/<thing>.d/` (one file per script), so
  re-running overwrites cleanly. Never append to system-managed files like
  `/etc/sysctl.conf` or `/etc/sudoers`.
- **Check-then-act** for state changes: `if id "$user" &>/dev/null; then ...`.
- **Pristine backups** for files we edit in place: keep `sshd_config.pristine`
  and reset to it at the top of the SSH step (see `bootstrap_server.sh`).
- **Validate before applying:** run `sshd -t`, `visudo -c`, etc. before
  restarting the service.

### Container/systemd conventions

- Containers run **rootless** under a dedicated system user (one per app),
  created by `setup_rootless_podman.sh`.
- Container images are **pinned by digest or version tag** at the top of the
  script (`VW_IMAGE="docker.io/vaultwarden/server:1.35.4"`). Document how to
  update the pin in a comment next to it.
- Systemd unit files for containers live under `/etc/systemd/system/`,
  managed by the install script.
- Quadlet (`*.container`) is the long-term direction on Ubuntu 24.04
  (Podman 4.9+); prefer it for new services where practical.

### Network and TLS

- Public-internet exposure is opt-in. Default is to bind to the Tailscale
  interface only (`tailscale ip -4`).
- TLS for tailnet-only services is provided by `tailscale cert`, refreshed
  daily by a cron job in `/etc/cron.d/`. The refresh job restarts the
  service **only if the cert fingerprint changed**.
- UFW rules: `bootstrap_server.sh` opens SSH only. App scripts open their
  own ports if (and only if) they need to be reachable from outside the
  tailnet.

### What not to do

- Do not use `eval`.
- Do not parse `ls` or `ps` output.
- Do not pipe `curl` into `bash`. Pinned `.deb` downloads with a hardcoded
  SHA-256 are the model (see the Tailscale install in `bootstrap_server.sh`).
- Do not `set +e` to "work around" an error. Either handle the failure
  explicitly with `|| true` on the single command, or fix the cause.
- Do not write secrets to the terminal. Use a root-owned reveal file under
  `/root/` and instruct the user to `cat` and then `rm` it.
- Do not hand-edit `/etc/pam.d/*` files directly — use `pam-auth-update`.

## Workflow for changes

1. Read the script you're touching end-to-end before editing — many lines
   have non-obvious "I hit this footgun once" comments.
2. **Install the pre-commit hooks** once per clone:
   ```bash
   sudo apt-get install pre-commit   # or: pipx install pre-commit
   pre-commit install
   ```
   This wires up `.pre-commit-config.yaml`, which runs `shellcheck` and a
   handful of whitespace/YAML hygiene hooks on every `git commit`. Run all
   hooks across the repo without committing:
   ```bash
   pre-commit run --all-files
   ```
   New shellcheck warnings should be fixed or explicitly disabled with a
   justifying `# shellcheck disable=SCxxxx` comment on the line above. To
   bypass the hook for a WIP commit, use `git commit --no-verify` — sparingly.
3. If the change is non-trivial, smoke-test on a throwaway Ubuntu 24.04
   droplet. Most bugs surface only against a real systemd + AppArmor setup.
4. Commit messages: imperative mood, ~50 char subject, body explaining
   *why* (the existing log is a good model: "Use `grep -c` over `wc -l`
   to count non-empty lines").
