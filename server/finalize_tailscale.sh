#!/usr/bin/env bash
#
# Join (or rejoin) the tailnet after bootstrap_server.sh.
#
# Usage: sudo ./server/finalize_tailscale.sh [--help]
#
# Prerequisites:
#   - bootstrap_server.sh was run with --tailscale (Tailscale installed and
#     /etc/bootstrap_server.conf present).
#
# What this script does:
#   1. Prompts (input hidden) for a Tailscale auth key; leave blank to log in
#      via the URL tailscale prints instead.
#   2. Runs `tailscale up` (with --ssh if bootstrap used --ts-ssh) and checks
#      the node is online.
#   3. If Tailscale SSH is enabled, closes the public SSH port in UFW.
#   4. Clears the "identity was reset" login message left by the snapshot
#      first-boot hook.
#
# Use it when bootstrap ran without an auth key, or on a droplet created from
# a snapshot (whose Tailscale identity is reset on first boot).

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/tailscale.sh
. "$SCRIPT_DIR/../lib/tailscale.sh"

trap 'error "Failed at line $LINENO (command: $BASH_COMMAND)"' ERR

STATE_FILE="/etc/bootstrap_server.conf"
SSH_PORT=""
TS_SSH=false

usage() {
    cat <<EOF
Usage: $0 [--help]

Join (or rejoin) the tailnet after bootstrap_server.sh --tailscale. Prompts
for an auth key (hidden); leave it blank to log in via a URL instead.
If bootstrap used --ts-ssh, the public SSH port is closed once connected.
EOF
}

load_state() {
    [[ -f "$STATE_FILE" ]] \
        || error "$STATE_FILE not found — run bootstrap_server.sh --tailscale first."
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            SSH_PORT) [[ "$value" =~ ^[0-9]+$ ]] && SSH_PORT="$value" ;;
            TS_SSH) [[ "$value" == true ]] && TS_SSH=true ;;
        esac
    done <"$STATE_FILE"
    [[ -n "$SSH_PORT" ]] || error "No valid SSH_PORT in $STATE_FILE"
}

preflight() {
    command -v tailscale >/dev/null \
        || error "tailscale is not installed — run bootstrap_server.sh --tailscale first."
    systemctl enable --now tailscaled
}

join_tailnet() {
    local key
    key=$(prompt_ts_authkey)
    ts_up "$key" "$TS_SSH" || error "tailscale up failed"

    # `tailscale ip -4` only succeeds once the node has an address.
    local ip
    ip=$(tailscale ip -4 2>/dev/null) || error "Tailscale did not come up (no tailnet IP)."
    success "Connected to the tailnet as $ip"
}

main() {
    case "${1:-}" in
        --help | -h)
            usage
            exit 0
            ;;
        "") ;;
        *)
            usage >&2
            exit 1
            ;;
    esac

    require_root
    require_ubuntu 24.04
    load_state
    preflight
    join_tailnet

    if [[ "$TS_SSH" == true ]]; then
        warn "Closing public SSH port $SSH_PORT. Make sure you can reach this host over the"
        warn "tailnet first (e.g. 'ssh <user>@$(tailscale ip -4)' from another device)."
        local answer=""
        have_tty || error "No TTY to confirm closing port $SSH_PORT; re-run interactively."
        read -rp "Close public SSH port $SSH_PORT now? [y/N] " answer </dev/tty || true
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            ts_close_public_ssh "$SSH_PORT"
        else
            warn "Left port $SSH_PORT open. Re-run this script to close it later."
            exit 0
        fi
    fi

    rm -f "$TS_RESET_FLAG"
    success "Tailscale finalized"
}

main "$@"
