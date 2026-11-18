#!/usr/bin/env bash
#
# Ubuntu Server Bootstrap Script
#
# Hardens a freshly-provisioned Ubuntu 24.04 droplet: creates an admin user,
# locks down sshd, enables UFW + fail2ban + unattended-upgrades, applies kernel
# hardening, and optionally joins the machine to a Tailscale network.
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
# in shell history or `ps` output. A blank answer means "I'll run tailscale up
# by hand later".
prompt_ts_authkey() {
    [[ "$INSTALL_TAILSCALE" == true ]] || return 0

    if [[ ! -r /dev/tty ]]; then
        warn "No TTY available — skipping Tailscale auth key prompt."
        return 0
    fi

    local key=""
    read -rsp "Tailscale auth key (leave blank to authenticate manually later): " \
        key </dev/tty || true
    echo >/dev/tty
    if [[ -n "$key" && ! "$key" =~ ^tskey- ]]; then
        error "That doesn't look like a Tailscale auth key (expected 'tskey-...')."
    fi
    TS_AUTHKEY="$key"
}

print_plan() {
    info "Starting Ubuntu server bootstrap process..."
    info "Creating user: $USERNAME"
    info "SSH will be configured on port: $SSH_PORT"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        info "Tailscale: ENABLED"
        [[ "$TS_SSH" == true ]] && info "  → Tailscale SSH enabled (SSH port closed to public)"
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
    apt-get install "${APT_OPTS[@]}" --no-install-recommends \
        fail2ban \
        ufw \
        unattended-upgrades \
        apt-listchanges \
        libpam-pwquality \
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

# ── Step 3: Create new user ───────────────────────────────────────────────────

create_user() {
    info "Step 3: Creating new user '$USERNAME'..."
    if id "$USERNAME" &>/dev/null; then
        warn "User '$USERNAME' already exists, skipping user creation"
    else
        adduser --comment "" "$USERNAME"
        success "User '$USERNAME' created successfully"
    fi
}

# ── Step 4: Grant admin privileges ────────────────────────────────────────────

grant_admin_privileges() {
    info "Step 4: Granting admin privileges to '$USERNAME'..."
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

# ── Step 8: Configure kernel security parameters ──────────────────────────────

# Write the complete 99-hardening.conf in one place so that every re-run
# produces the same file.  Both network/kernel params AND swap-tuning params
# live here; that way configure_swap() never needs to append to this file
# (which would silently disappear on any re-run that skips configure_swap).
write_sysctl_hardening() {
    cat >/etc/sysctl.d/99-hardening.conf <<'EOF'
# Kernel / network security and VM tuning (managed by bootstrap_server.sh)
# Network hardening
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv6.conf.all.accept_redirects=0
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
# VM / swap tuning — always set; harmless if no swap is present
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
}

configure_sysctl_hardening() {
    info "Step 8: Configuring kernel security parameters..."
    # Delegate to write_sysctl_hardening() so the file is always written
    # atomically and completely — including swap-related sysctls — on every
    # run.  This prevents configure_swap()'s early-return path from silently
    # dropping vm.swappiness on re-runs.
    write_sysctl_hardening
    sysctl -p /etc/sysctl.d/99-hardening.conf
    success "Kernel security parameters configured"
}

# ── Step 9: Secure shared memory ──────────────────────────────────────────────

secure_shared_memory() {
    info "Step 9: Securing shared memory..."
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

# ── Step 10: Set up UFW firewall ──────────────────────────────────────────────

configure_ufw() {
    info "Step 10: Configuring UFW firewall..."
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

# ── Step 11: Configure Fail2Ban ───────────────────────────────────────────────

configure_fail2ban() {
    info "Step 11: Configuring Fail2Ban..."
    cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 12h
findtime = 10m
maxretry = 3
backend = systemd
destemail = root@localhost
sendername = Fail2Ban
mta = sendmail

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 12h

[apache-auth]
enabled = false

[apache-badbots]
enabled = false

[apache-noscript]
enabled = false

[apache-overflows]
enabled = false
EOF

    systemctl enable fail2ban
    systemctl start fail2ban
    success "Fail2Ban configured and started"
}

# ── Step 12: Configure automatic security updates ─────────────────────────────

configure_unattended_upgrades() {
    info "Step 12: Configuring automatic security updates..."
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

# ── Step 13: Configure swap file ──────────────────────────────────────────────

configure_swap() {
    info "Step 13: Configuring swap file..."
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

# ── Step 14: Configure chrony for time synchronization ────────────────────────

configure_chrony() {
    info "Step 14: Configuring time synchronization..."
    systemctl enable chrony
    systemctl start chrony
    success "Time synchronization configured"
}

# ── Step 15: Disable unused services ──────────────────────────────────────────

disable_unused_services() {
    info "Step 15: Disabling unused services..."
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
    systemctl enable apparmor
    systemctl start apparmor
    # aa-enforce on the glob would also recurse into subdirectories like abstractions/,
    # generating errors for each. Target only top-level files instead.
    find /etc/apparmor.d -maxdepth 1 -type f -exec aa-enforce {} \; 2>/dev/null \
        || warn "Some AppArmor profiles could not be enforced — review 'aa-status' after provisioning"
    success "AppArmor configured and enforcing"
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

install_tailscale() {
    info "Step 20: Installing and configuring Tailscale..."

    # Install Tailscale — pinned to a specific version with a hardcoded checksum.
    # Pinning prevents silent supply-chain updates; you control when to upgrade.
    # The hash is hardcoded (not fetched at runtime) so that a compromised upstream
    # server cannot serve a matching fake .sha256 alongside a malicious .deb.
    #
    # To update the pin:
    #   1. Set TS_VERSION to the desired release from https://pkgs.tailscale.com/stable/
    #   2. Download the .deb and its .sha256 sidecar, verify on a trusted machine:
    #        curl -fsSL https://pkgs.tailscale.com/stable/tailscale_<VER>_amd64.deb     -o /tmp/ts.deb
    #        curl -fsSL https://pkgs.tailscale.com/stable/tailscale_<VER>_amd64.deb.sha256
    #   3. Confirm the hash matches: sha256sum /tmp/ts.deb
    #   4. Paste the verified hash into TS_EXPECTED_HASH below.
    local ts_version="1.96.2"
    local ts_deb="tailscale_${ts_version}_amd64.deb"
    local ts_url="https://pkgs.tailscale.com/stable/${ts_deb}"
    # SHA256 of tailscale_1.96.2_amd64.deb — verify before updating the pin (see above).
    local ts_expected_hash="0431610d988ec54643a6beeae35f943aa3f11362577828138d367ca5aac29bc6"

    # Abort early if the hardcoded hash looks malformed (must be exactly 64 lowercase hex chars).
    if [[ ! "$ts_expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
        error "ts_expected_hash is not a valid SHA-256 hex digest. Follow the instructions in install_tailscale() to obtain and hardcode the SHA256 for tailscale_${ts_version}_amd64.deb."
    fi

    # Skip download and install if this exact version is already installed
    local installed_version
    installed_version=$(tailscale version 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [[ "$installed_version" == "$ts_version" ]]; then
        warn "Tailscale ${ts_version} already installed, skipping download"
    else
        info "Downloading Tailscale ${ts_version}..."
        curl -fsSL "$ts_url" -o "/tmp/${ts_deb}"

        # Verify against the hardcoded hash
        info "Verifying checksum..."
        echo "${ts_expected_hash}  /tmp/${ts_deb}" | sha256sum --check --strict
        success "Checksum verified"

        apt-get install "${APT_OPTS[@]}" --no-install-recommends "/tmp/${ts_deb}"
        rm -f "/tmp/${ts_deb}"
        success "Tailscale ${ts_version} installed"
    fi

    # No unattended-upgrades blacklist needed: the pinned .deb comes from no
    # apt source, so apt has nothing to upgrade it to. Update the pin above.

    # Bring Tailscale up
    if [[ -n "$TS_AUTHKEY" ]]; then
        # Hand the key over via a root-only file (tailscale's 'file:' prefix)
        # rather than argv, so it never shows up in `ps`.
        local key_file
        key_file=$(mktemp)
        chmod 600 "$key_file"
        printf '%s' "$TS_AUTHKEY" >"$key_file"

        # Build tailscale up arguments as an array, not a string — see
        # "Arrays for flag lists" in AGENTS.md.
        local ts_up_args=("--auth-key=file:$key_file")
        [[ "$TS_SSH" == true ]] && ts_up_args+=("--ssh")

        if ! tailscale up "${ts_up_args[@]}"; then
            rm -f "$key_file"
            error "tailscale up failed"
        fi
        rm -f "$key_file"
        TS_AUTHKEY=""
        TS_CONNECTED=true
        success "Tailscale connected"

        # If Tailscale SSH is enabled: close the public SSH port,
        # trust the tailscale0 interface instead.
        # SSH over the tailnet is handled entirely by Tailscale's daemon.
        if [[ "$TS_SSH" == true ]]; then
            info "Locking down public SSH port — access via Tailscale SSH only..."
            ufw delete allow "$SSH_PORT"/tcp 2>/dev/null || true
            ufw allow in on tailscale0
            ufw reload
            success "Public SSH port $SSH_PORT closed; tailscale0 interface trusted"
            warn "Connect with: ssh $USERNAME@<tailscale-hostname-or-ip>"
            warn "Tailscale must be running on your client device"
        fi
    else
        # Start the daemon but defer auth — operator must run 'tailscale up' manually
        systemctl enable --now tailscaled
        warn "Tailscale daemon started but NOT authenticated."
        warn "Run the following to complete setup:"
        echo ""
        if [[ "$TS_SSH" == true ]]; then
            echo "  tailscale up --ssh"
        else
            echo "  tailscale up"
        fi
        echo ""
        warn "Do NOT close this SSH session until Tailscale is authenticated"
        warn "and you have verified connectivity over the tailnet."
        if [[ "$TS_SSH" == true ]]; then
            warn "After verifying tailnet access, manually run:"
            echo "  ufw delete allow $SSH_PORT/tcp"
            echo "  ufw allow in on tailscale0"
            echo "  ufw reload"
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
    success "Server bootstrapping completed successfully!"
    echo ""
    warn "=== CRITICAL REMINDERS ==="
    warn "1. SSH is now on port $SSH_PORT - connect with: ssh -p $SSH_PORT $USERNAME@your_server_ip"
    warn "2. Test SSH connection with new user and port BEFORE closing this session"
    warn "3. Password authentication is DISABLED"
    warn "4. Root login is DISABLED"
    warn "5. Only user '$USERNAME' can SSH to this server"
    warn "6. Automatic security updates are ENABLED (auto-reboot at 11:00 UTC when needed)"
    warn "7. sudo commands are logged by journald (journalctl _COMM=sudo) and /var/log/auth.log"
    if [[ "$INSTALL_TAILSCALE" == true && "$TS_SSH" == true && "$TS_CONNECTED" == true ]]; then
        warn "8. Public SSH port is CLOSED — connect via: ssh $USERNAME@<tailscale-hostname>"
        warn "   Tailscale must be authenticated on your client device"
    fi
    if [[ "$INSTALL_TAILSCALE" == true && "$TS_SSH" == true ]]; then
        warn "9. Tailscale SSH bypasses sshd entirely — PermitRootLogin has no effect over the tailnet."
        warn "   Restrict root login via your Tailscale ACL policy:"
        warn "   https://login.tailscale.com/admin/acls"
        warn "   Ensure your SSH ACL rule specifies users: [\"$USERNAME\"] and omits root."
    fi
    echo ""
    warn "=== SECURITY FEATURES ENABLED ==="
    info "✓ UFW Firewall (SSH only: $SSH_PORT — add web ports manually if needed)"
    info "✓ Fail2Ban (12h SSH bans)"
    info "✓ Automatic security updates"
    info "✓ Kernel security hardening"
    info "✓ Strong password policies (pam_pwquality)"
    info "✓ SSH hardened (key-only, no root, OpenSSH default crypto)"
    info "✓ AppArmor enforcement"
    info "✓ Time synchronization"
    info "✓ Sudo hardening (5-minute credential cache)"
    info "✓ Swap file (${SWAP_SIZE})"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        info "✓ Tailscale VPN installed"
        [[ "$TS_SSH" == true ]] && info "✓ Tailscale SSH enabled (public SSH port closed)"
    fi
    echo ""
    info "Run 'lynis audit system' for a detailed security assessment"

    # Print a highly-visible reboot warning last so it is not scrolled off.
    if [[ "$REBOOT_REQUIRED" == true ]]; then
        echo ""
        warn "╔══════════════════════════════════════════════════════════════════════╗"
        warn "║           *** REBOOT REQUIRED BEFORE FURTHER PROVISIONING ***       ║"
        warn "║                                                                      ║"
        warn "║  apt-get upgrade installed a new kernel that is NOT yet running.     ║"
        warn "║  Some hardening parameters written above apply only to the new       ║"
        warn "║  kernel.  Until you reboot, the system is running an older kernel    ║"
        warn "║  that may be missing security patches.                               ║"
        warn "║                                                                      ║"
        warn "║  Reboot now:   systemctl reboot                                      ║"
        warn "║  Then re-run any app-setup scripts (setup_vaultwarden.sh, etc.).     ║"
        warn "╚══════════════════════════════════════════════════════════════════════╝"
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
    prompt_ts_authkey

    update_system
    install_security_packages
    configure_password_policies
    create_user
    grant_admin_privileges
    setup_user_ssh_keys
    configure_sshd
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
}

main "$@"
