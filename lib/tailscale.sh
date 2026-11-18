# lib/tailscale.sh
# shellcheck shell=bash
#
# Tailscale helpers shared by bootstrap_server.sh and finalize_tailscale.sh.
# Source after lib/common.sh (uses info/success/warn/error).

# Files shared between bootstrap_server.sh, the snapshot first-boot hook and
# finalize_tailscale.sh.
TS_RESET_FLAG="/var/lib/bootstrap_server/tailscale-reset"
TS_FIRSTBOOT_HOOK="/var/lib/cloud/scripts/per-instance/bootstrap-tailscale-reset.sh"
TS_MOTD_SCRIPT="/etc/update-motd.d/99-bootstrap-tailscale"

# Prompt for a Tailscale auth key with hidden input and print it on stdout.
# Prompts go to /dev/tty so callers can use `key=$(prompt_ts_authkey)`.
# Prints nothing (and returns 0) if left blank or no TTY is available.
prompt_ts_authkey() {
    if ! have_tty; then
        warn "No TTY available — skipping Tailscale auth key prompt."
        return 0
    fi

    local key=""
    read -rsp "Tailscale auth key (leave blank to authenticate via login URL): " \
        key </dev/tty || true
    echo >/dev/tty
    if [[ -n "$key" && ! "$key" =~ ^tskey- ]]; then
        error "That doesn't look like a Tailscale auth key (expected 'tskey-...')."
    fi
    printf '%s' "$key"
}

# Run `tailscale up`, optionally with an auth key and --ssh.
# With an empty key, tailscale prints a login URL and waits for you to open it.
#
# Usage: ts_up <auth-key-or-empty> <true|false: enable Tailscale SSH>
ts_up() {
    local key="$1" ssh="$2"

    # Build tailscale up arguments as an array, not a string — see
    # "Arrays for flag lists" in AGENTS.md.
    local args=()
    [[ "$ssh" == true ]] && args+=(--ssh)

    if [[ -z "$key" ]]; then
        tailscale up "${args[@]}"
        return
    fi

    # Hand the key over via a root-only file (tailscale's 'file:' prefix)
    # rather than argv, so it never shows up in `ps`.
    local key_file rc=0
    key_file=$(mktemp)
    chmod 600 "$key_file"
    printf '%s' "$key" >"$key_file"
    tailscale up "--auth-key=file:$key_file" "${args[@]}" || rc=$?
    rm -f "$key_file"
    return "$rc"
}

# Trust the tailscale0 interface and close the public SSH port. SSH over the
# tailnet is then handled by Tailscale SSH (or sshd via tailscale0).
#
# Usage: ts_close_public_ssh <ssh-port>
ts_close_public_ssh() {
    local port="$1"
    ufw allow in on tailscale0
    ufw delete allow "$port"/tcp 2>/dev/null || true
    ufw reload
    success "Public SSH port $port closed; tailscale0 interface trusted"
}

# Install the snapshot first-boot hook and its login-message script.
#
# A snapshot carries /var/lib/tailscale/tailscaled.state, so every droplet
# created from it would come up as the SAME tailnet node and they'd fight over
# the identity. cloud-init runs per-instance scripts once per new instance-id
# (i.e. on the first boot of a droplet created from a snapshot, not on reboots
# of the original), so the hook gives each copy a fresh, logged-out identity.
#
# If Tailscale SSH had closed the public SSH port, the copy would otherwise be
# reachable only via the recovery console, so the hook temporarily reopens it.
# finalize_tailscale.sh closes it again once the copy has joined the tailnet.
install_ts_firstboot_hook() {
    mkdir -p "$(dirname "$TS_FIRSTBOOT_HOOK")" "$(dirname "$TS_RESET_FLAG")"

    cat >"$TS_FIRSTBOOT_HOOK" <<'HOOK'
#!/usr/bin/env bash
#
# Installed by bootstrap_server.sh. Runs once on the first boot of a droplet
# created from a snapshot: resets the Tailscale identity inherited from the
# snapshot and, if the public SSH port was closed, reopens it temporarily.
# Run finalize_tailscale.sh afterwards to rejoin the tailnet.

set -euo pipefail

systemctl stop tailscaled || true
rm -f /var/lib/tailscale/tailscaled.state
systemctl start tailscaled || true

ssh_port="" ts_ssh=false
if [[ -f /etc/bootstrap_server.conf ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            SSH_PORT) [[ "$value" =~ ^[0-9]+$ ]] && ssh_port="$value" ;;
            TS_SSH) [[ "$value" == true ]] && ts_ssh=true ;;
        esac
    done </etc/bootstrap_server.conf
fi

# Plain rule, no comment: finalize_tailscale.sh removes it with
# `ufw delete allow <port>/tcp`, which must match it exactly.
if [[ "$ts_ssh" == true && -n "$ssh_port" ]]; then
    ufw allow "$ssh_port"/tcp
fi

mkdir -p /var/lib/bootstrap_server
touch /var/lib/bootstrap_server/tailscale-reset
HOOK
    chmod 755 "$TS_FIRSTBOOT_HOOK"

    # SCRIPT_DIR is the calling script's directory (server/).
    cat >"$TS_MOTD_SCRIPT" <<MOTD
#!/bin/sh
# Installed by bootstrap_server.sh — shown until finalize_tailscale.sh runs.
[ -f $TS_RESET_FLAG ] || exit 0
printf '\\n*** This droplet was created from a snapshot: its Tailscale identity was reset.\\n'
printf '*** Rejoin the tailnet with: sudo $SCRIPT_DIR/finalize_tailscale.sh\\n\\n'
MOTD
    chmod 755 "$TS_MOTD_SCRIPT"
}
