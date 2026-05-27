# Audit TODO

Consolidated, prioritized checklist from the 2026-05 audit of the scripts in
this repo. Higher tiers first. Each item is tagged:

- **[BUG]** likely-incorrect behaviour
- **[CONVENTION]** violates `AGENTS.md`
- **[POLISH]** style / robustness / DX improvement

Tick items off as they land.

---

## Tier 1 — Real bugs and lockout risks

- [x] **[BUG]** `bootstrap_server.sh: configure_swap` — `dd` fallback path is
      hardcoded to `count=2048` (2 G) and ignores `SWAP_SIZE`. Derive the
      count from `SWAP_SIZE` or refuse to fall back unless the size matches.
- [x] **[BUG]** `bootstrap_server.sh: secure_file_permissions` — unquoted
      globs (`chmod 600 /etc/ssh/ssh_host_*_key`) abort under `set -u` on
      images that ship without host keys. Wrap in `shopt -s nullglob` or
      switch to `find … -exec chmod`.
- [x] **[BUG]** `bootstrap_server.sh: print_summary` — claims "Fail2Ban (24h
      SSH bans)" but `jail.local` sets `bantime = 12h`. Pick one and make
      them match.
- [x] **[BUG]** `bootstrap_server.sh: setup_user_ssh_keys` — empty
      `authorized_keys` only warns. If password auth is being disabled and
      `--ts-ssh` was not requested, this is a guaranteed lockout. Promote
      the warning to an `error` in that combination.
- [ ] **[BUG]** `setup_vaultwarden.sh: cmd_setup` — `local hostname="$1"`
      aborts under `set -u` when no args are given, before the friendly
      "hostname is required" error. Use `"${1:-}"` and validate.
- [ ] **[BUG]** `setup_vaultwarden.sh: cmd_cert_refresh` — accepts an empty
      hostname (passed through from the dispatcher's `"${2:-}"`) and writes
      broken cert files for the empty string. Validate non-empty at the top.
- [ ] **[BUG-likely]** `setup_vaultwarden.sh` Quadlet — `[Unit] After=default.target`
      combined with `[Install] WantedBy=default.target` is an inverse
      ordering loop. Drop the `After=` (or change to a concrete target).
- [ ] **[BUG]** `bootstrap_server.sh: install_tailscale` — dead-code
      placeholder check (`REPLACE_WITH_*`) can never fire now that a real
      hash is set. Either delete it or convert to "hash must be 64 hex chars".

---

## Tier 2 — `AGENTS.md` violations

- [ ] **[CONVENTION]** `setup_vaultwarden.sh` shebang is `#!/bin/bash`.
      Change to `#!/usr/bin/env bash`.
- [ ] **[CONVENTION]** `setup_rootless_podman.sh` is indented with **2
      spaces** throughout. Reformat to 4 spaces (`shfmt -i 4 -w` will do
      it mechanically).
- [ ] **[CONVENTION]** `setup_vaultwarden.sh` uses `[ ... ]` tests in 10+
      places. Convert to `[[ ... ]]`.
- [ ] **[CONVENTION]** `setup_vaultwarden.sh: cmd_help` greps comments from
      `$0`. Replace with a literal heredoc `usage()` function.
- [ ] **[CONVENTION]** `setup_rootless_podman.sh` and `setup_vaultwarden.sh`
      don't call `require_ubuntu 24.04`. Add it to `main()` of both.
- [ ] **[CONVENTION]** `setup_rootless_podman.sh` has no `--help` / `-h`.
      Add a `usage()` heredoc + dispatcher.
- [ ] **[CONVENTION]** None of the three scripts reset `IFS=$'\n\t'` per
      the AGENTS.md file-header template. Add it.
- [ ] **[CONVENTION]** `setup_vaultwarden.sh: apt-get install -y argon2`
      is missing `--no-install-recommends` and `DEBIAN_FRONTEND=noninteractive`.
      Same for `setup_rootless_podman.sh: install_dependencies`.
- [ ] **[CONVENTION]** `setup_rootless_podman.sh` — validate the username
      argument (reject anything starting with `-` so `--help` doesn't
      create a user called `--help`).

---

## Tier 3 — Logging / helper consolidation

- [ ] **[CONVENTION]** Delete the `print_info` / `print_success` / `print_warning`
      / `print_error` / `print_section` aliases in `setup_vaultwarden.sh`.
      Call `info` / `success` / `warn` / `error` / `section` directly.
      Where `error()`'s implicit exit is wrong, call `warn ...; exit 1`
      explicitly (or introduce a `die()` helper).
- [ ] **[CONVENTION]** Delete the `GREEN` / `YELLOW` / `NC` back-compat
      aliases in `bootstrap_server.sh` and `setup_vaultwarden.sh`. Rewrite
      the `echo -e "${YELLOW}..."` lines in the summary blocks as `warn` /
      `info` calls.
- [ ] **[POLISH]** Promote shared helpers into `lib/common.sh`:
    - [ ] `run_as_user <user> <cmd…>` — sets `XDG_RUNTIME_DIR` and
          `DBUS_SESSION_BUS_ADDRESS`.
    - [ ] `systemctl_user <user> <args…>` — wraps `run_as_user … systemctl --user`.
    - [ ] `require_rootless_podman_user <user>` — replaces the
          `check_system_user` block in `setup_vaultwarden.sh`.
    - [ ] `require_linger_enabled <user>`.
- [ ] **[POLISH]** Consider `lib/podman.sh` (separate from `common.sh`)
      once a second app script lands. Premature today, but plan for it.

---

## Tier 4 — Robustness / correctness improvements

- [ ] **[POLISH]** `setup_rootless_podman.sh` — move the AppArmor
      `flags=(unconfined)` patch out of in-place sed and into
      `/etc/apparmor.d/local/podman` (and equivalent local overrides for
      `crun` and `slirp4netns`). The current patch is silently undone the
      next time `unattended-upgrades` reinstalls `podman`.
- [ ] **[POLISH]** `bootstrap_server.sh: secure_shared_memory` — replace
      the `/etc/fstab` append with a systemd drop-in at
      `/etc/systemd/system/dev-shm.mount.d/hardening.conf`. Matches the
      "drop-in files, never append to system files" rule in AGENTS.md.
- [ ] **[POLISH]** `bootstrap_server.sh: configure_swap` — appends
      `vm.swappiness` to `99-hardening.conf` but `configure_sysctl_hardening`
      runs first and writes that file with `>`. On a re-run where
      `/swapfile` already exists, swappiness is silently dropped. Fold
      swap-related sysctls into a single `write_sysctl_hardening()` that
      always emits the whole file.
- [ ] **[POLISH]** `bootstrap_server.sh` — reconsider the
      `Defaults requiretty` + `Defaults log_input,log_output` combination.
      `log_input,log_output` records every keystroke and every output byte
      of every sudo session into `/var/log/sudo-io/`, which is more than
      most single-admin droplets actually want. Keep `logfile=` (command-
      level audit) and drop the io logging unless there's a compliance need.
- [ ] **[POLISH]** `bootstrap_server.sh: configure_apparmor` — the mass
      `aa-enforce` on every top-level profile forces some upstream-
      complain profiles into enforce mode, which then has to be undone by
      `setup_rootless_podman.sh`. Either narrow the enforce list or
      document the ordering dependency loudly.
- [ ] **[POLISH]** `bootstrap_server.sh: install_tailscale` — `apt-get
      upgrade -y` earlier in the script may have upgraded the kernel; some
      hardening then applies to a kernel that isn't running. Detect and
      either reboot or print a prominent "reboot required before
      provisioning further" warning at the end.
- [ ] **[POLISH]** `bootstrap_server.sh` — `export DEBIAN_FRONTEND=noninteractive`
      once at the top of `main()` instead of inside `update_system`. As-is,
      later `apt-get` calls (e.g. `install_tailscale`'s `apt-get install
      "/tmp/${ts_deb}"`) run without it.
- [ ] **[POLISH]** `setup_vaultwarden.sh` — pin `VW_IMAGE` by digest
      instead of (or in addition to) the version tag. Document the update
      flow (`skopeo inspect docker://… | jq -r .Digest`).
- [ ] **[POLISH]** `setup_vaultwarden.sh` — replace `PodmanArgs=--memory=512m
      --pids-limit=512` with first-class Quadlet fields `Memory=512M` and
      `PidsLimit=512`.
- [ ] **[POLISH]** `setup_vaultwarden.sh` — drop the python3 dependency
      for parsing `tailscale status --json`. Install and use `jq` instead,
      or use `tailscale status --self --json --peers=false`.
- [ ] **[POLISH]** `setup_vaultwarden.sh` — the `/root/vaultwarden-admin-token.txt`
      existence check aborts hard. A partial run leaves you stuck without
      manual cleanup. Either rename the existing one to a timestamped
      backup or accept-and-warn.
- [ ] **[POLISH]** `setup_vaultwarden.sh` — the health-check loop sleeps
      after the final failed attempt. Restructure so the final retry
      either succeeds or exits the loop without sleeping.
- [ ] **[POLISH]** `setup_vaultwarden.sh` — `apt-get update -qq` masks
      progress and errors; the other scripts use plain `apt-get update`.
      Standardize on no `-qq`.
- [ ] **[POLISH]** `setup_rootless_podman.sh` — kernel version parsing
      via `echo "$KERNEL_VERSION" | cut -d. -f1` → use parameter
      expansion (`${KERNEL_VERSION%%.*}`).
- [ ] **[POLISH]** `setup_rootless_podman.sh: setup_storage` — silently
      no-ops on re-run if config exists, even after a kernel upgrade
      across the 5.11 native-overlay boundary. Either detect-and-warn or
      offer a `--reconfigure` mode.
- [ ] **[POLISH]** `setup_rootless_podman.sh` — smoke-test failure should
      use a distinctive exit code (e.g. 42) so CI / wrappers can tell
      "configuration error" from "smoke test inconclusive".
- [ ] **[POLISH]** `setup_rootless_podman.sh` — `PODMAN_UID` and
      `PODMAN_USER_PREEXISTED` as cross-function globals work but are a
      smell. Either pass them explicitly or annotate with a clear
      "state exported from setup_user()" comment block.

---

## Tier 5 — DX, ops, and longer-term

- [ ] **[POLISH]** Add a `vw` (or `vaultwarden-ctl`) wrapper at
      `/usr/local/sbin/` so the post-setup summary collapses from
      `sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/$(id -u vaultwarden)
      systemctl --user …` to `vw logs` / `vw restart` / `vw status`.
- [ ] **[POLISH]** Add a Vaultwarden backup script (daily `sqlite3 …
      ".backup …"` to a separate path, ideally off-host). Out of scope
      for `setup_vaultwarden.sh` itself, but the single biggest
      operational gap today.
- [ ] **[POLISH]** Add `shfmt` (`-i 4 -ci -bn`) to `.pre-commit-config.yaml`.
- [ ] **[POLISH]** Bump shellcheck severity in pre-commit from `warning`
      to `info` once the above lands. Fix or `# shellcheck disable=` the
      long tail.
- [ ] **[POLISH]** Add a GitHub Actions workflow that runs
      `pre-commit run --all-files` on PRs.
- [ ] **[POLISH]** Adopt the AGENTS.md-recommended ERR trap in all three
      scripts:
      ```bash
      trap 'error "Failed at line $LINENO (command: $BASH_COMMAND)"' ERR
      ```
      (Requires `set -E` for inheritance into functions.)
- [ ] **[POLISH]** Add a `docs/smoke-test.md` describing the manual
      throwaway-droplet test procedure each script should pass.
- [ ] **[POLISH]** Add a `docs/post-install.md` consolidating the "after
      running, do X" sections currently duplicated across each script's
      summary block (Tailscale ACL hint, `harden` command, admin token
      location, fail2ban tuning, …).
- [ ] **[POLISH]** Add a root `Makefile` with `make lint`, `make fmt`,
      and (eventually) `make smoke DROPLET=…` targets.

---

## Notes on ordering

- Tier 1 fixes can lock you out of a droplet or silently corrupt
  state — do these first.
- Tier 2 is mechanical and unblocks Tier 3 (the helper consolidation is
  easier once every script speaks the same dialect).
- Tier 3 shrinks the codebase and removes drift risk between
  `setup_rootless_podman.sh` and any future app-on-podman script.
- Tier 4 items are individually small but compound — most of them remove
  a specific footgun documented in an in-line comment.
- Tier 5 is forward-looking; do these as the repo grows past three
  scripts.
