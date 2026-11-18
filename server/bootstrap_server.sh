#!/usr/bin/env bash
#
# Ubuntu Server Bootstrap Script
#
# Hardens a freshly-provisioned Ubuntu 24.04 droplet: creates an admin user,
# locks down sshd, enables UFW + fail2ban + unattended-upgrades, applies kernel
# hardening, pins GitHub's SSH host keys (for git over a forwarded agent, see
# fleeting), and optionally joins the machine to a Tailscale network.
#
# Usage:
#   ./bootstrap_server.sh <username> [ssh_port] [--tailscale] [--ts-ssh]
#
# Example:
#   ./bootstrap_server.sh myuser 2222 --tailscale --ts-ssh
#
# Options:
#   --tailscale          Install and configure Tailscale. You'll be prompted
#                        (input hidden) for an auth key; leave it blank to run
#                        'tailscale up' manually afterwards.
#   --ts-ssh             Enable Tailscale SSH (requires --tailscale)

set -Eeuo pipefail
IFS=$'\n\t'

# Source shared helpers (info/success/warn/error, require_root, require_ubuntu, ...)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/tailscale.sh
. "$SCRIPT_DIR/../lib/tailscale.sh"

trap 'error "Failed at line $LINENO (command: $BASH_COMMAND)"' ERR

# ── Configuration ─────────────────────────────────────────────────────────────
# Populated by parse_args(); declared up here so set -u doesn't fire if any
# function is somehow called before parsing.

USERNAME=""
SSH_PORT="22"
INSTALL_TAILSCALE=false
TS_AUTHKEY=""
TS_CONNECTED=false
TS_SSH=false
SWAP_SIZE="2G"
REBOOT_REQUIRED=false
# Shared apt-get flags. DEBIAN_FRONTEND=noninteractive only silences debconf;
# dpkg still stops to ask about modified conffiles unless told what to do.
# confdef/confold: take the package default if we never touched the file,
# otherwise keep ours.
APT_OPTS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

# Settings from the previous run, loaded from STATE_FILE (see load_state).
STATE_FILE="/etc/bootstrap_server.conf"
PREV_SSH_PORT=""

# Warnings that mean "look at this before rebooting" (see serious_warn).
SERIOUS_WARNINGS=()

# warn() + remember the message so the end-of-run summary and reboot prompt
# can surface it again.
serious_warn() {
    warn "$*"
    SERIOUS_WARNINGS+=("$*")
}

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 <username> [ssh_port] [--tailscale] [--ts-ssh]
Example: $0 myuser 2222 --tailscale --ts-ssh

Options:
  --tailscale   Install and configure Tailscale. You'll be prompted (input
                hidden) for an auth key; leave it blank to run 'tailscale up'
                manually afterwards. Generate keys at
                https://login.tailscale.com/admin/settings/keys
  --ts-ssh      Enable Tailscale SSH and close the public SSH port
                (requires --tailscale)
  -h, --help    Show this help
EOF
}

parse_args() {
    # Handle --help anywhere on the command line before treating $1 as a
    # username, so `./bootstrap_server.sh --help` never creates a user.
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            usage
            exit 0
        fi
    done

    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 1
    fi

    USERNAME="$1"
    shift

    # Same rules as adduser's default NAME_REGEX. Reject root explicitly:
    # AllowUsers root + PermitRootLogin no would be a guaranteed lockout.
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "Invalid username: '$USERNAME'. Use lowercase letters, digits, '_' or '-'."
    fi
    if [[ "$USERNAME" == "root" ]]; then
        error "Username must not be 'root' (root SSH login is disabled by this script)."
    fi

    # The second positional argument is optional and must be numeric (SSH port).
    if [[ $# -ge 1 && "$1" != --* ]]; then
        SSH_PORT="$1"
        shift
    fi
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
        error "Invalid SSH port: '$SSH_PORT'. Must be a number between 1 and 65535."
    fi

    # Parse optional flags — $@ now contains only flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tailscale) INSTALL_TAILSCALE=true ;;
            --ts-ssh) TS_SSH=true ;;
            *) error "Unknown option: '$1' (see --help)" ;;
        esac
        shift
    done

    if [[ "$TS_SSH" == true && "$INSTALL_TAILSCALE" != true ]]; then
        error "--ts-ssh requires --tailscale"
    fi
}

# Ask for the Tailscale auth key up front (hidden input) so it never appears
# in shell history or `ps` output, and the rest of the run needs no input
# beyond adduser's password prompt.
ask_ts_authkey() {
    [[ "$INSTALL_TAILSCALE" == true ]] || return 0
    TS_AUTHKEY=$(prompt_ts_authkey)
}

print_plan() {
    info "Starting Ubuntu server bootstrap process..."
    info "Creating user: $USERNAME"
    info "SSH will be configured on port: $SSH_PORT"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        info "Tailscale: ENABLED"
        # if/fi, not `[[ ]] && info`: as the function's last command, a false
        # test would become its return status and trip set -e in main.
        if [[ "$TS_SSH" == true ]]; then
            info "  → Tailscale SSH enabled (SSH port closed to public)"
        fi
    else
        info "Tailscale: not requested (pass --tailscale to enable)"
    fi
}

# ── State file ────────────────────────────────────────────────────────────────
# /etc/bootstrap_server.conf records the settings of the last run so re-runs
# can clean up after themselves (e.g. drop the old SSH port's UFW rule) and
# so the Tailscale first-boot hook knows the SSH port. Plain KEY=value lines;
# parsed with `read`, never sourced.

load_state() {
    [[ -f "$STATE_FILE" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            SSH_PORT) [[ "$value" =~ ^[0-9]+$ ]] && PREV_SSH_PORT="$value" ;;
        esac
    done <"$STATE_FILE"
}

save_state() {
    cat >"$STATE_FILE" <<EOF
# Written by bootstrap_server.sh — settings from the last run.
USERNAME=$USERNAME
SSH_PORT=$SSH_PORT
TS_SSH=$TS_SSH
EOF
    chmod 644 "$STATE_FILE"
}

# ── Step 1: Update installed packages ─────────────────────────────────────────

update_system() {
    info "Step 1: Updating system packages..."
    apt-get update
    apt-get upgrade "${APT_OPTS[@]}"
    _detect_kernel_upgrade
    success "System packages updated successfully"
}

# Check whether apt-get upgrade installed a new kernel that isn't running yet.
# Sets REBOOT_REQUIRED=true if so, and emits an early warning.
# Detection strategy (both checked, either suffices):
#   1. Ubuntu's standard /var/run/reboot-required flag written by update-notifier-common.
#   2. Direct comparison of uname -r vs. the newest vmlinuz-* in /boot.
_detect_kernel_upgrade() {
    local running_kernel
    running_kernel=$(uname -r)

    # Strategy 1: Ubuntu's reboot-required marker (set by apt on kernel upgrades)
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_REQUIRED=true
        warn "Kernel upgrade detected (running: ${running_kernel})."
        warn "A reboot is required before provisioning further services."
        return
    fi

    # Strategy 2: compare uname -r against the newest vmlinuz-* in /boot.
    # Filenames look like: vmlinuz-6.8.0-57-generic  (excludes *rescue* kernels).
    local newest_kernel
    newest_kernel=$(
        find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*rescue*' \
            | sed 's|.*/vmlinuz-||' \
            | sort -V \
            | tail -1
    )

    if [[ -n "$newest_kernel" && "$running_kernel" != "$newest_kernel" ]]; then
        REBOOT_REQUIRED=true
        warn "Kernel upgrade detected: running ${running_kernel}, installed ${newest_kernel}."
        warn "A reboot is required before provisioning further services."
    fi
}

# ── Step 2: Install essential security packages ───────────────────────────────

install_security_packages() {
    info "Step 2: Installing essential security packages..."
    # nftables (fail2ban's Debian banaction) and cron (unattended-upgrades)
    # are Recommends but already present in the Ubuntu 24.04 server image.
    # cracklib-runtime is only a Recommends of libcrack2, but pwquality's
    # dictionary check needs the dictionary it builds; without it, and with
    # enforce_for_root, every password is rejected ("error loading dictionary").
    apt-get install "${APT_OPTS[@]}" --no-install-recommends \
        fail2ban \
        ufw \
        unattended-upgrades \
        apt-listchanges \
        libpam-pwquality \
        cracklib-runtime \
        chrony \
        lynis \
        apparmor-utils
    success "Security packages installed"
}

# ── Step 3: Configure password policies ───────────────────────────────────────

# Runs before create_user so the password chosen at the adduser prompt is
# actually checked against the policy. SSH password auth is disabled, so this
# governs the sudo / recovery-console password only.
#
# No account lockout (pam_faillock): with key-only SSH it would only guard sudo
# and the console, and with root login disabled three typos would lock the
# sole admin out of root. Ubuntu also ships no pam-auth-update profile for it.
configure_password_policies() {
    info "Step 3: Configuring password policies..."
    # Drop-in rather than editing the package-owned /etc/security/pwquality.conf.
    # enforce_for_root: adduser sets the password as root, which would otherwise
    # only warn on a weak password instead of rejecting it.
    mkdir -p /etc/security/pwquality.conf.d
    cat >/etc/security/pwquality.conf.d/bootstrap.conf <<EOF
# Managed by bootstrap_server.sh
minlen = 12
minclass = 3
maxrepeat = 2
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
enforce_for_root
EOF
    success "Password policies configured"
}

# ── Step 4: Create new user ───────────────────────────────────────────────────

create_user() {
    info "Step 4: Creating new user '$USERNAME'..."
    if id "$USERNAME" &>/dev/null; then
        warn "User '$USERNAME' already exists, skipping user creation"
    else
        adduser --comment "" "$USERNAME"
        success "User '$USERNAME' created successfully"
    fi
    ensure_user_password
}

# adduser still creates the account if every password attempt is rejected,
# leaving it locked. SSH is key-only, but sudo needs a password, and root login
# is disabled — so a passwordless admin would have no way to escalate. Keep
# prompting until a password is set (Ctrl-C to abort).
ensure_user_password() {
    local status
    status=$(passwd -S "$USERNAME" | awk '{print $2}')
    [[ "$status" == "P" ]] && return 0

    warn "User '$USERNAME' has no usable password (needed for sudo) — set one now."
    until passwd "$USERNAME"; do
        warn "Password not set; try again (Ctrl-C to abort)."
    done
    success "Password set for '$USERNAME'"
}

# ── Step 5: Grant admin privileges ────────────────────────────────────────────

grant_admin_privileges() {
    info "Step 5: Granting admin privileges to '$USERNAME'..."
    usermod -aG sudo "$USERNAME"
    success "Admin privileges granted to '$USERNAME'"
}

# ── Step 6: Set up SSH keys for new user ──────────────────────────────────────

setup_user_ssh_keys() {
    info "Step 6: Setting up SSH key directory for '$USERNAME'..."
    local user_home="/home/$USERNAME"
    local ssh_dir="$user_home/.ssh"

    if [[ ! -d "$ssh_dir" ]]; then
        sudo -u "$USERNAME" mkdir -p "$ssh_dir"
        sudo -u "$USERNAME" chmod 700 "$ssh_dir"
    fi

    # Copy root's authorized_keys if present, otherwise create an empty file.
    # Copying allows the same key used to access the droplet as root to immediately
    # work for the new user — no need to re-add it manually.
    local root_authorized_keys="/root/.ssh/authorized_keys"
    if [[ -s "$root_authorized_keys" ]]; then
        cp "$root_authorized_keys" "$ssh_dir/authorized_keys"
        chown "$USERNAME:$USERNAME" "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
        local key_count
        key_count=$(grep -c . "$ssh_dir/authorized_keys" || true)
        success "Copied $key_count key(s) from root's authorized_keys to $ssh_dir/authorized_keys"
    else
        sudo -u "$USERNAME" touch "$ssh_dir/authorized_keys"
        sudo -u "$USERNAME" chmod 600 "$ssh_dir/authorized_keys"
        # Password auth is always disabled by configure_sshd. With no keys and no
        # Tailscale SSH, there is no way back in — abort before we lock ourselves out.
        if [[ "$TS_SSH" == false ]]; then
            error "No keys found in $root_authorized_keys and --ts-ssh was not requested." \
                "configure_sshd will disable password auth, guaranteeing a lockout." \
                "Add your public key to /root/.ssh/authorized_keys and re-run, or pass --tailscale --ts-ssh."
        fi
        warn "No keys found in $root_authorized_keys — authorized_keys created empty"
        warn "--ts-ssh is enabled; you can still reach the server over the tailnet."
        warn "Remember to add your public key to $ssh_dir/authorized_keys before relying on key auth."
    fi
}

# ── Step 7: Configure SSH security settings ───────────────────────────────────

configure_sshd() {
    info "Step 7: Configuring SSH security settings..."
    local sshd_config="/etc/ssh/sshd_config"
    local dropin="/etc/ssh/sshd_config.d/00-bootstrap.conf"

    # Older versions of this script edited sshd_config in place and kept a
    # pristine copy. Restore it once so stale settings don't linger alongside
    # the drop-in, then retire the backup.
    local pristine_backup="/etc/ssh/sshd_config.pristine"
    if [[ -f "$pristine_backup" ]]; then
        cp "$sshd_config" "$sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
        mv "$pristine_backup" "$sshd_config"
        info "Restored stock sshd_config (settings now live in $dropin)"
    fi

    # Ubuntu's sshd_config begins with 'Include /etc/ssh/sshd_config.d/*.conf'
    # and sshd uses the FIRST value it sees for each keyword. A 00- drop-in
    # therefore wins over both the main file and cloud-init's
    # 50-cloud-init.conf, which may set 'PasswordAuthentication yes'.
    #
    # Ciphers/MACs/KexAlgorithms are deliberately left at the OpenSSH defaults:
    # they're maintained upstream and include the post-quantum
    # sntrup761x25519 key exchange, which a hand-pinned list would drop.
    cat >"$dropin" <<EOF
# Managed by bootstrap_server.sh — re-run the script rather than editing.
Port $SSH_PORT
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
PermitEmptyPasswords no
AllowUsers $USERNAME
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:100
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
UseDNS no
PermitUserEnvironment no
# fleeting forwards a GitHub-only agent; explicit so verification catches overrides.
AllowAgentForwarding yes
EOF
    chmod 644 "$dropin"

    # sshd -t requires the privilege separation directory to exist,
    # but it may not be present on a fresh droplet before sshd's first start.
    mkdir -p /run/sshd
    chmod 755 /run/sshd

    # Validate config before restarting — catches errors before they lock you out
    if ! sshd -t; then
        rm -f "$dropin"
        error "sshd config validation failed — removed $dropin and aborted"
    fi

    verify_sshd_effective_config
    success "SSH configuration updated (Port: $SSH_PORT)"
}

# Compare sshd's *effective* configuration (after all Includes) against what
# we asked for. Catches another drop-in or the main file overriding us.
verify_sshd_effective_config() {
    local effective
    effective=$(sshd -T 2>/dev/null) || {
        serious_warn "Could not run 'sshd -T' to verify the effective SSH config"
        return 0
    }

    local expected=(
        "port $SSH_PORT"
        "passwordauthentication no"
        "kbdinteractiveauthentication no"
        "permitrootlogin no"
        "pubkeyauthentication yes"
        "allowusers $USERNAME"
        "allowagentforwarding yes"
    )
    local line
    for line in "${expected[@]}"; do
        if ! grep -qxF "$line" <<<"$effective"; then
            serious_warn "sshd effective config is missing '$line' — check /etc/ssh/sshd_config.d/"
        fi
    done

    # Port is cumulative across files; make sure nothing adds a second one.
    local port_count
    port_count=$(grep -c '^port ' <<<"$effective" || true)
    if ((port_count != 1)); then
        serious_warn "sshd will listen on $port_count ports: $(grep '^port ' <<<"$effective" | tr '\n' ' ')"
    fi
}

# ── Step 8: Configure SSH client for GitHub ───────────────────────────────────
# fleeting's connect-droplet forwards a GitHub-only ssh-agent from the laptop, so
# git can pull/push here without any GitHub key on the droplet (see
# client/digitalocean/fleeting/README.md). This step makes that work smoothly.

# GitHub's SSH host keys, pinned so the first `git fetch` on a fresh droplet
# can't be man-in-the-middled (and doesn't stop at a trust-on-first-use prompt).
# Verify against https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# To update after a GitHub key rotation:
#   curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[]'
# then check `ssh-keygen -lf` of each line against the fingerprints page.
GITHUB_HOST_KEYS=(
    "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
    "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
)

configure_github_ssh_client() {
    info "Step 8: Configuring SSH client for GitHub..."

    # The system-wide known_hosts file. Ubuntu doesn't ship one and ssh has no
    # .d directory for it, so this script owns the whole file.
    {
        echo "# Managed by bootstrap_server.sh — re-run the script rather than editing."
        printf '%s\n' "${GITHUB_HOST_KEYS[@]}"
    } >/etc/ssh/ssh_known_hosts
    chmod 644 /etc/ssh/ssh_known_hosts

    # Stable agent socket for tmux. A forwarded agent's socket path changes on
    # every login, so tmux panes started in an earlier session point at a dead
    # socket after a reconnect. sshd runs /etc/ssh/sshrc for every session
    # (whatever the login shell — zsh doesn't read /etc/profile.d), and it
    # repoints ~/.ssh/agent.sock at the current socket. sshd skips its xauth
    # step when sshrc exists; harmless since X11Forwarding is off.
    # It is NOT run for users who have their own ~/.ssh/rc.
    cat >/etc/ssh/sshrc <<'EOF'
# Managed by bootstrap_server.sh — re-run the script rather than editing.
# Point ~/.ssh/agent.sock at this session's forwarded agent; tmux panes use
# that path (see /etc/tmux.conf), so they survive reconnects.
if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] && [ -d "$HOME/.ssh" ]; then
    ln -sfn "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
EOF
    chmod 644 /etc/ssh/sshrc

    # Panes inherit tmux's global SSH_AUTH_SOCK (the stable symlink). The
    # update-environment list is tmux's default minus SSH_AUTH_SOCK; leaving it
    # in would copy the session's direct socket over the global value.
    # A user ~/.tmux.conf is read afterwards and can override this.
    cat >/etc/tmux.conf <<'EOF'
# Managed by bootstrap_server.sh — re-run the script rather than editing.
set-environment -g SSH_AUTH_SOCK "$HOME/.ssh/agent.sock"
set -g update-environment "DISPLAY KRB5CCNAME SSH_ASKPASS SSH_AGENT_PID SSH_CONNECTION WINDOWID XAUTHORITY"
EOF
    chmod 644 /etc/tmux.conf

    success "GitHub host keys pinned; tmux agent socket configured"
}

# ── Step 9: Configure kernel security parameters ──────────────────────────────

# Write the complete 99-hardening.conf in one place so that every re-run
# produces the same file.  Both network/kernel params AND swap-tuning params
# live here; that way configure_swap() never needs to append to this file
# (which would silently disappear on any re-run that skips configure_swap).
write_sysctl_hardening() {
    cat >/etc/sysctl.d/99-hardening.conf <<'EOF'
# Kernel / network security and VM tuning (managed by bootstrap_server.sh)
#
# Per-interface settings are set for both 'all' and 'default': 'all' doesn't
# reach interfaces created later (tailscale0, podman bridges), 'default' does.
#
# rp_filter=1 (strict) is fine for a plain tailnet member. If this droplet
# ever becomes a Tailscale exit node or subnet router, switch both to 2
# (loose) — strict mode drops forwarded traffic and tailscale warns about it.
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
# VM / swap tuning — always set; harmless if no swap is present
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
}

configure_sysctl_hardening() {
    info "Step 9: Configuring kernel security parameters..."
    # Delegate to write_sysctl_hardening() so the file is always written
    # atomically and completely — including swap-related sysctls — on every
    # run.  This prevents configure_swap()'s early-return path from silently
    # dropping vm.swappiness on re-runs.
    write_sysctl_hardening
    sysctl -p /etc/sysctl.d/99-hardening.conf
    success "Kernel security parameters configured"
}

# ── Step 10: Secure shared memory ─────────────────────────────────────────────

secure_shared_memory() {
    info "Step 10: Securing shared memory..."
    # noexec: prevent executing binaries from shared memory
    # nosuid: prevent setuid/setgid bits from taking effect
    # nodev:  prevent device files in shared memory
    #
    # /etc/fstab is the supported mechanism here: /dev/shm is an API
    # filesystem mounted by systemd itself (dev-shm.mount has no unit file, so
    # a [Mount] drop-in is never applied at boot), and systemd-remount-fs
    # applies fstab options to API filesystems. Verified on a droplet after
    # reboot. Check-then-add keeps re-runs from duplicating the line.
    local fstab_line="tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0"
    if awk '$1 !~ /^#/ && $2 == "/dev/shm" { found = 1 } END { exit !found }' /etc/fstab; then
        info "/dev/shm already has an /etc/fstab entry, leaving it as is"
    else
        echo "$fstab_line" >>/etc/fstab
    fi

    # Earlier versions of this script used a drop-in that never took effect.
    if [[ -d /etc/systemd/system/dev-shm.mount.d ]]; then
        rm -rf /etc/systemd/system/dev-shm.mount.d
        systemctl daemon-reload
    fi

    # Apply the new options immediately without a reboot.
    mount -o remount,noexec,nosuid,nodev /dev/shm
    success "Shared memory secured via /etc/fstab and remounted"
}

# ── Step 11: Set up UFW firewall ──────────────────────────────────────────────

configure_ufw() {
    info "Step 11: Configuring UFW firewall..."
    # NOTE: Only SSH is opened by default. If this server runs a web application,
    # manually open the required ports after provisioning:
    #   ufw allow 80/tcp
    #   ufw allow 443/tcp
    #
    # No `ufw --force reset`: on a fresh droplet there's nothing to reset, and
    # on a re-run it would wipe ports opened later by app scripts and the
    # tailscale0 rule. Every command below is idempotent on its own.
    ufw default deny incoming
    ufw default allow outgoing
    if [[ -n "$PREV_SSH_PORT" && "$PREV_SSH_PORT" != "$SSH_PORT" ]]; then
        ufw delete allow "$PREV_SSH_PORT"/tcp || true
        info "Removed UFW rule for previous SSH port $PREV_SSH_PORT"
    fi
    ufw allow "$SSH_PORT"/tcp
    ufw --force enable
    success "UFW firewall configured (SSH port: $SSH_PORT — add web ports manually if needed)"
}

# ── Step 12: Configure Fail2Ban ───────────────────────────────────────────────

configure_fail2ban() {
    info "Step 12: Configuring Fail2Ban..."
    # backend=systemd reads sshd's journal directly, so no logpath is needed.
    # No mail actions: there's no MTA on the droplet.
    # ignoreip includes Tailscale's CGNAT range so a fumbled login from your
    # own tailnet device can't ban it.
    cat >/etc/fail2ban/jail.local <<EOF
# Managed by bootstrap_server.sh
[DEFAULT]
bantime = 12h
findtime = 10m
maxretry = 3
backend = systemd
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10

[sshd]
enabled = true
port = $SSH_PORT
EOF

    systemctl enable fail2ban
    systemctl start fail2ban
    success "Fail2Ban configured and started"
}

# ── Step 13: Configure automatic security updates ─────────────────────────────

configure_unattended_upgrades() {
    info "Step 13: Configuring automatic security updates..."
    # Drop-in rather than overwriting the package-owned 50unattended-upgrades
    # (which would trigger conffile conflicts on upgrade). Later files win for
    # scalar settings; the stock file's Allowed-Origins (security + ESM) is
    # what we want, so it isn't repeated here.
    #
    # Automatic-Reboot only fires when /var/run/reboot-required exists, i.e.
    # when an update actually needs it. The time is in the server's timezone,
    # which is UTC on droplets: 11:00 UTC = 4 AM PDT / 3 AM PST.
    cat >/etc/apt/apt.conf.d/52bootstrap-unattended-upgrades <<EOF
// Managed by bootstrap_server.sh
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "11:00";
EOF

    cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable unattended-upgrades
    success "Automatic security updates configured"
}

# ── Step 14: Configure swap file ──────────────────────────────────────────────

configure_swap() {
    info "Step 14: Configuring swap file..."
    # Each part (create, fstab entry, activation) is checked independently so
    # a run interrupted halfway is completed rather than skipped on re-run.
    if [[ -f /swapfile ]]; then
        info "Swap file already exists, not recreating"
    else
        create_swapfile
    fi

    if ! awk '$1 == "/swapfile" { found = 1 } END { exit !found }' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi

    if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
        swapon /swapfile
    fi
    # vm.swappiness and vm.vfs_cache_pressure are written (and applied) by
    # configure_sysctl_hardening() via write_sysctl_hardening().
    success "Swap file ($SWAP_SIZE) configured and enabled"
}

create_swapfile() {
    # fallocate is fast but unsupported on some filesystems (e.g. btrfs, some XFS configs).
    # Fall back to dd, which is universally compatible, if fallocate fails.
    if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
        warn "fallocate failed (unsupported filesystem?), falling back to dd..."
        # Derive block count (MiB) from SWAP_SIZE so dd honours the configured size.
        # Accepted formats: <N>G / <N>g  →  N*1024 MiB
        #                   <N>M / <N>m  →  N MiB
        local swap_mib
        if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
            swap_mib=$((BASH_REMATCH[1] * 1024))
        elif [[ "$SWAP_SIZE" =~ ^([0-9]+)[Mm]$ ]]; then
            swap_mib=${BASH_REMATCH[1]}
        else
            error "Cannot derive dd block count from SWAP_SIZE='$SWAP_SIZE'; expected format like '2G' or '512M'"
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mib" status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
}

# ── Step 15: Configure chrony for time synchronization ────────────────────────

configure_chrony() {
    info "Step 15: Configuring time synchronization..."
    systemctl enable chrony
    systemctl start chrony
    success "Time synchronization configured"
}

# ── Step 16: Disable unused services ──────────────────────────────────────────

disable_unused_services() {
    info "Step 16: Disabling unused services..."
    local services_to_disable=(avahi-daemon cups isc-dhcp-server isc-dhcp-server6 rpcbind nfs-server)

    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable "$service"
            systemctl stop "$service" 2>/dev/null || true
            info "Disabled service: $service"
        fi
    done
    success "Unused services disabled"
}

# ── Step 17: Configure AppArmor ───────────────────────────────────────────────

configure_apparmor() {
    info "Step 17: Configuring AppArmor..."
    # AppArmor is enabled and enforcing by default on Ubuntu; just make sure.
    #
    # Do NOT run aa-enforce over /etc/apparmor.d. Many stock 24.04 profiles
    # (podman, crun, slirp4netns, buildah, browsers, ...) are deliberately
    # flags=(unconfined) with a single 'userns,' rule: they exist only to
    # grant user-namespace creation, which 24.04 otherwise restricts.
    # aa-enforce strips 'unconfined', turning them into enforcing profiles
    # that break rootless Podman, and leaves them as modified conffiles.
    systemctl enable apparmor
    systemctl start apparmor
    success "AppArmor enabled (stock profiles)"
}

# ── Step 18: Configure sudo hardening ─────────────────────────────────────────

harden_sudo() {
    info "Step 18: Configuring sudo hardening..."
    # Only the cached-credential timeout differs from Ubuntu's defaults
    # (env_reset and secure_path are already set in /etc/sudoers).
    # Deliberately not set:
    #   requiretty  — breaks `ssh host sudo ...`; its purpose (blocking sudo
    #                 from cron/scripts) doesn't apply to a single-admin box.
    #   logfile=    — un-rotated duplicate of what journald and
    #                 /var/log/auth.log already record for every sudo call.
    cat >/etc/sudoers.d/hardening <<'EOF'
Defaults timestamp_timeout=5
EOF
    chmod 440 /etc/sudoers.d/hardening
    # Validate the sudoers file before proceeding
    visudo -c -f /etc/sudoers.d/hardening
    success "Sudo hardening configured"
}

# ── Step 19: Restart services to apply changes ────────────────────────────────

restart_services() {
    info "Step 19: Restarting services..."
    restart_sshd
    systemctl restart chrony
    systemctl restart fail2ban
    success "Services restarted"
}

# On Ubuntu 24.04 sshd is socket-activated: ssh.socket owns the listening port
# and sshd-socket-generator derives it from sshd_config at daemon-reload.
# Restarting ssh.service alone leaves the socket on the old port.
restart_sshd() {
    systemctl daemon-reload
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    else
        systemctl restart ssh
    fi

    if ss -Hltn "sport = :$SSH_PORT" | grep -q .; then
        success "sshd is listening on port $SSH_PORT"
    else
        serious_warn "Nothing is listening on port $SSH_PORT yet — it should be after a reboot."
    fi
}

# ── Step 20: Install and configure Tailscale (optional) ───────────────────────

# Add Tailscale's official apt repository (signed) so `apt-get install tailscale`
# pulls the current stable release, verified by apt against the pinned keyring.
#
# The keyring is a binary GPG keyring, not a script, so fetching it over HTTPS
# is not a `curl | bash`; apt's signature check is the trust anchor for every
# package from then on. The source list is written literally rather than
# fetched: this script only targets Ubuntu 24.04 (noble, enforced by
# require_ubuntu), and a hardcoded file is easier to audit than one pulled at
# runtime.
#
# Upgrades are NOT silent: unattended-upgrades only pulls from the origins in
# 50unattended-upgrades (Ubuntu security + ESM), and we deliberately do not add
# Tailscale to Allowed-Origins. Newer versions arrive only on an explicit
# `apt-get upgrade` or a re-run of this script. To opt into unattended Tailscale
# upgrades, add 'origin=Tailscale,codename=noble' to Allowed-Origins.
#
# Key rotation: if apt later reports a NO_PUBKEY/signature error, re-fetch the
# keyring from the URL below and eyeball its fingerprint (printed at install
# time, cross-check against https://tailscale.com/download/linux).
install_tailscale_apt_source() {
    local keyring="/usr/share/keyrings/tailscale-archive-keyring.gpg"
    local list="/etc/apt/sources.list.d/tailscale.list"
    local keyring_url="https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg"

    info "Configuring Tailscale apt repository..."

    # Atomic install: download to a temp file and move into place only on
    # success, so a failed fetch can't leave a truncated keyring behind.
    local tmp_keyring
    tmp_keyring=$(mktemp)
    if ! curl -fsSL "$keyring_url" -o "$tmp_keyring"; then
        rm -f "$tmp_keyring"
        error "Failed to download Tailscale apt keyring from $keyring_url"
    fi
    install -m 0644 "$tmp_keyring" "$keyring"
    rm -f "$tmp_keyring"

    # Surface the key fingerprint so it's logged and can be eyeballed.
    if command -v gpg >/dev/null; then
        local fpr
        fpr=$(gpg --show-keys --with-colons "$keyring" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        [[ -n "$fpr" ]] && info "Tailscale repo key fingerprint: $fpr"
    fi

    cat >"$list" <<EOF
# Managed by bootstrap_server.sh — Tailscale official stable repository.
deb [signed-by=$keyring] https://pkgs.tailscale.com/stable/ubuntu noble main
EOF
    chmod 644 "$list"

    apt-get update
    success "Tailscale apt repository configured"
}

install_tailscale() {
    info "Step 20: Installing and configuring Tailscale..."

    # Install Tailscale from its official signed apt repository. apt verifies
    # every package against the pinned keyring, so there's no per-.deb hash to
    # maintain and re-runs (or a manual `apt-get upgrade`) stay current with
    # upstream stable — newer than Ubuntu's own tailscale package.
    install_tailscale_apt_source
    apt-get install "${APT_OPTS[@]}" --no-install-recommends tailscale
    success "Tailscale installed ($(tailscale version 2>/dev/null | awk 'NR==1{print $1}'))"

    systemctl enable --now tailscaled
    install_ts_firstboot_hook
    info "Installed first-boot hook: snapshot copies get a fresh Tailscale identity"

    # Bring Tailscale up
    if [[ -n "$TS_AUTHKEY" ]]; then
        ts_up "$TS_AUTHKEY" "$TS_SSH" || error "tailscale up failed"
        TS_AUTHKEY=""
        TS_CONNECTED=true
        success "Tailscale connected"

        if [[ "$TS_SSH" == true ]]; then
            info "Locking down public SSH port — access via Tailscale SSH only..."
            ts_close_public_ssh "$SSH_PORT"
        fi
    else
        serious_warn "Tailscale is installed but NOT authenticated. Finish with:" \
            "sudo $SCRIPT_DIR/finalize_tailscale.sh"
        if [[ "$TS_SSH" == true ]]; then
            warn "That script also closes public SSH port $SSH_PORT once the tailnet works."
        fi
    fi

    success "Tailscale configuration complete"
}

# ── Step 21: Display security status ──────────────────────────────────────────

show_security_status() {
    info "=== SECURITY STATUS ==="
    echo ""
    info "UFW Firewall Status:"
    ufw status || warn "ufw status failed"

    echo ""
    info "Fail2Ban Status:"
    fail2ban-client status || warn "fail2ban-client status failed"

    echo ""
    info "AppArmor Status:"
    aa-status --enabled || warn "aa-status failed"

    echo ""
    info "Swap Status:"
    swapon --show || warn "swapon --show failed"

    echo ""
    info "Time Synchronization:"
    # chrony's control socket can briefly return 503 (e.g. "Not synchronised")
    # right after install while it's still bootstrapping. This is purely a
    # status display, so don't let it abort the whole bootstrap.
    chronyc sources || warn "chronyc sources failed (chrony may still be starting up)"
}

# ── Step 22: Final summary ────────────────────────────────────────────────────

print_summary() {
    success "Server bootstrapping completed!"
    echo ""

    local n=0
    reminder() {
        n=$((n + 1))
        warn "$n. $1"
        shift
        local line
        for line in "$@"; do warn "   $line"; done
    }

    warn "=== REMINDERS ==="
    if [[ "$TS_SSH" == true && "$TS_CONNECTED" == true ]]; then
        reminder "After the reboot, connect over the tailnet: ssh $USERNAME@<tailscale-hostname>" \
            "The public SSH port is CLOSED; Tailscale must be running on your client."
    else
        reminder "After the reboot, connect with: ssh -p $SSH_PORT $USERNAME@<server-ip>"
    fi
    reminder "Password authentication and root login are DISABLED; only '$USERNAME' can SSH in."
    reminder "Security updates install automatically and reboot at 11:00 UTC when needed."
    reminder "sudo is logged by journald (journalctl _COMM=sudo) and /var/log/auth.log."
    if [[ "$TS_SSH" == true ]]; then
        reminder "Tailscale SSH bypasses sshd — PermitRootLogin has no effect over the tailnet." \
            "Restrict it in your ACL policy (https://login.tailscale.com/admin/acls):" \
            "the SSH rule should specify users: [\"$USERNAME\"] and omit root."
    fi
    echo ""
    warn "=== SECURITY FEATURES ENABLED ==="
    info "✓ UFW Firewall (SSH only: $SSH_PORT — add web ports manually if needed)"
    info "✓ Fail2Ban (12h SSH bans)"
    info "✓ Automatic security updates (with reboot when required)"
    info "✓ Kernel security hardening"
    info "✓ Strong password policies (pam_pwquality)"
    info "✓ SSH hardened (key-only, no root, OpenSSH default crypto)"
    info "✓ GitHub host keys pinned; tmux-stable forwarded agent socket"
    info "✓ AppArmor (stock profiles)"
    info "✓ Time synchronization"
    info "✓ Sudo hardening (5-minute credential cache)"
    info "✓ Swap file (${SWAP_SIZE})"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        info "✓ Tailscale VPN installed (snapshot copies get a fresh identity)"
        if [[ "$TS_SSH" == true && "$TS_CONNECTED" == true ]]; then
            info "✓ Tailscale SSH enabled (public SSH port closed)"
        fi
    fi
    echo ""
    info "Run 'lynis audit system' for a detailed security assessment"

    if [[ "$REBOOT_REQUIRED" == true ]]; then
        echo ""
        warn "apt-get upgrade installed a new kernel that is NOT running yet —"
        warn "the system has pending security patches until you reboot."
    fi

    # Repeat anything that needs attention last, so it isn't scrolled off.
    if ((${#SERIOUS_WARNINGS[@]} > 0)); then
        echo ""
        warn "=== NEEDS ATTENTION BEFORE REBOOTING ==="
        local msg
        for msg in "${SERIOUS_WARNINGS[@]}"; do
            warn "• $msg"
        done
    fi
}

# ── Step 23: Reboot ───────────────────────────────────────────────────────────
# Several changes (sshd port on first boot, /dev/shm options, a new kernel)
# are only fully in effect after a reboot, so always offer one. Defaults to
# yes on a clean run, no if anything above needs attention.

offer_reboot() {
    echo ""
    if ! have_tty; then
        info "Next step: reboot with 'systemctl reboot'."
        return 0
    fi

    local prompt="[Y/n]" default="y" answer=""
    if ((${#SERIOUS_WARNINGS[@]} > 0)); then
        prompt="[y/N]"
        default="n"
        warn "Defaulting to NO because of the warnings above."
    fi

    read -rp "Reboot now to apply all changes? $prompt " answer </dev/tty || true
    answer="${answer:-$default}"
    if [[ "$answer" =~ ^[Yy] ]]; then
        info "Rebooting..."
        systemctl reboot
    else
        info "Not rebooting. Run 'systemctl reboot' when you're ready."
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    export DEBIAN_FRONTEND=noninteractive

    parse_args "$@"
    require_root
    require_ubuntu 24.04

    load_state
    print_plan
    ask_ts_authkey

    update_system
    install_security_packages
    configure_password_policies
    create_user
    grant_admin_privileges
    setup_user_ssh_keys
    configure_sshd
    configure_github_ssh_client
    configure_sysctl_hardening
    secure_shared_memory
    configure_ufw
    save_state
    configure_fail2ban
    configure_unattended_upgrades
    configure_swap
    configure_chrony
    disable_unused_services
    configure_apparmor
    harden_sudo
    restart_services

    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        install_tailscale
    fi

    show_security_status
    print_summary
    offer_reboot
}

main "$@"
