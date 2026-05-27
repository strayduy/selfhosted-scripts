#!/usr/bin/env bash
#
# Ubuntu Server Bootstrap Script
#
# Hardens a freshly-provisioned Ubuntu 24.04 droplet: creates an admin user,
# locks down sshd, enables UFW + fail2ban + unattended-upgrades, applies kernel
# hardening, and optionally joins the machine to a Tailscale network.
#
# Usage:
#   ./bootstrap_server.sh <username> [ssh_port] [--tailscale] [--ts-authkey <key>] [--ts-ssh]
#
# Example:
#   ./bootstrap_server.sh myuser 2222 --tailscale --ts-authkey tskey-auth-xxx --ts-ssh
#
# Options:
#   --tailscale          Install and configure Tailscale
#   --ts-authkey <key>   Tailscale auth key for unattended provisioning
#                        Generate at https://login.tailscale.com/admin/settings/keys
#                        Use ephemeral keys for short-lived droplets
#   --ts-ssh             Enable Tailscale SSH (replaces key-based SSH over tailnet)

set -euo pipefail

# Source shared helpers (info/success/warn/error, require_root, require_ubuntu, ...)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# Preserve the colour-variable names used in the final summary block.
# Back-compat aliases for the colour vars used in this script's banners.
# RED is intentionally omitted — error() handles red output itself.
GREEN="$_C_GREEN"; YELLOW="$_C_YELLOW"; NC="$_C_NC"

# ── Configuration ─────────────────────────────────────────────────────────────
# Populated by parse_args(); declared up here so set -u doesn't fire if any
# function is somehow called before parsing.

USERNAME=""
SSH_PORT="22"
INSTALL_TAILSCALE=false
TS_AUTHKEY=""
TS_SSH=false
SWAP_SIZE="2G"

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $0 <username> [ssh_port] [--tailscale] [--ts-authkey <key>] [--ts-ssh]
Example: $0 myuser 2222 --tailscale --ts-authkey tskey-auth-xxx

Options:
  --tailscale          Install and configure Tailscale
  --ts-authkey <key>   Tailscale auth key for unattended provisioning
                       Generate at https://login.tailscale.com/admin/settings/keys
                       Use ephemeral keys for short-lived droplets
  --ts-ssh             Enable Tailscale SSH (replaces key-based SSH over tailnet)
EOF
}

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 1
    fi

    USERNAME="$1"

    # The second positional argument is optional and must be numeric (SSH port).
    # We check it explicitly here rather than using a fragile inline shift trick,
    # so that a non-numeric $2 is rejected with a clear error rather than silently
    # treated as a flag or ignored.
    if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        SSH_PORT="$2"
        shift 2  # consume username + port; flags start at $1
    elif [[ $# -ge 2 && "$2" == --* ]]; then
        SSH_PORT="22"  # $2 is a flag — no port supplied, leave it for flag parsing
        shift 1        # consume username only
    elif [[ $# -ge 2 ]]; then
        error "Invalid second argument: '$2'. Expected a numeric SSH port or a --flag."
    else
        SSH_PORT="22"  # only username was supplied
        shift 1
    fi

    # Validate SSH port is a number in the valid range
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        error "Invalid SSH port: '$SSH_PORT'. Must be a number between 1 and 65535."
    fi

    # Parse optional flags — $@ now contains only flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tailscale)    INSTALL_TAILSCALE=true ;;
            --ts-authkey)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "--ts-authkey requires a value"
                fi
                TS_AUTHKEY="$2"; shift ;;
            --ts-ssh)       TS_SSH=true ;;
            --help|-h)      usage; exit 0 ;;
            *) warn "Unknown option: $1" ;;
        esac
        shift
    done
}

print_plan() {
    info "Starting Ubuntu server bootstrap process..."
    info "Creating user: $USERNAME"
    info "SSH will be configured on port: $SSH_PORT"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        info "Tailscale: ENABLED"
        [[ -n "$TS_AUTHKEY" ]] && info "  → Unattended auth key provided"
        [[ "$TS_SSH" == true ]] && info "  → Tailscale SSH enabled (SSH port closed to public)"
    else
        info "Tailscale: not requested (pass --tailscale to enable)"
    fi
}

# ── Step 1: Update installed packages ─────────────────────────────────────────

update_system() {
    info "Step 1: Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    success "System packages updated successfully"
}

# ── Step 2: Install essential security packages ───────────────────────────────

install_security_packages() {
    info "Step 2: Installing essential security packages..."
    apt-get install -y \
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

# ── Step 3: Create new user ───────────────────────────────────────────────────

create_user() {
    info "Step 3: Creating new user '$USERNAME'..."
    if id "$USERNAME" &>/dev/null; then
        warn "User '$USERNAME' already exists, skipping user creation"
    else
        adduser --gecos "" "$USERNAME"
        success "User '$USERNAME' created successfully"
    fi
}

# ── Step 4: Grant admin privileges ────────────────────────────────────────────

grant_admin_privileges() {
    info "Step 4: Granting admin privileges to '$USERNAME'..."
    usermod -aG sudo "$USERNAME"
    success "Admin privileges granted to '$USERNAME'"
}

# ── Step 5: Configure password policies ───────────────────────────────────────

configure_password_policies() {
    info "Step 5: Configuring password policies..."
    cat > /etc/security/pwquality.conf << EOF
# Password quality requirements
minlen = 12
minclass = 3
maxrepeat = 2
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
EOF

    # Configure account lockout policy using pam_faillock.
    # We configure via /etc/security/faillock.conf and let pam-auth-update manage
    # the PAM stack — this avoids overwriting /etc/pam.d/common-auth wholesale,
    # which would break other PAM modules and conflict with package upgrades.
    #
    # On Ubuntu 24.04, pam_faillock is included in the default pam-auth-update
    # profile; enabling it here is safe and non-destructive.
    cat > /etc/security/faillock.conf << EOF
deny = 3
unlock_time = 1800
silent
EOF

    # Enable pam_faillock via pam-auth-update (idempotent — safe to re-run)
    pam-auth-update --enable faillock --force

    success "Password policies configured"
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
                  "Add your public key to /root/.ssh/authorized_keys and re-run, or pass --ts-ssh."
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

    # Always restore from the original pristine backup if one exists,
    # otherwise create it now. This makes the step safe to re-run —
    # we never layer sed edits or appended blocks on top of each other.
    local pristine_backup="/etc/ssh/sshd_config.pristine"
    if [[ ! -f "$pristine_backup" ]]; then
        cp "$sshd_config" "$pristine_backup"
        info "Saved pristine sshd_config backup to $pristine_backup"
    fi

    # Take a timestamped backup for this run, then reset to pristine
    cp "$sshd_config" "$sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$pristine_backup" "$sshd_config"

    # Configure SSH settings
    sed -i -E "s/^#?Port 22$/Port $SSH_PORT/" "$sshd_config"
    sed -i -E 's/^#?PasswordAuthentication\s+\S+/PasswordAuthentication no/' "$sshd_config"
    sed -i -E 's/^#?PermitRootLogin\s+\S+/PermitRootLogin no/' "$sshd_config"
    sed -i -E 's/^#?PubkeyAuthentication\s+\S+/PubkeyAuthentication yes/' "$sshd_config"

    # Add additional security settings (safe to append — we always start from pristine)
    cat >> "$sshd_config" << EOF

# Additional Security Settings
# Note: 'Protocol 2' was removed in OpenSSH 7.6 — SSHv1 is gone, no directive needed
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
PermitEmptyPasswords no
X11Forwarding no
UseDNS no
AllowUsers $USERNAME
MaxStartups 10:30:100
LoginGraceTime 30
PermitUserEnvironment no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
EOF

    # sshd -t requires the privilege separation directory to exist,
    # but it may not be present on a fresh droplet before sshd's first start.
    mkdir -p /run/sshd
    chmod 755 /run/sshd

    # Validate config before restarting — catches errors before they lock you out
    if ! sshd -t; then
        warn "sshd config validation failed — restoring backup and aborting"
        cp "$pristine_backup" "$sshd_config"
        exit 1
    fi

    success "SSH configuration updated (Port: $SSH_PORT)"
}

# ── Step 8: Configure kernel security parameters ──────────────────────────────

configure_sysctl_hardening() {
    info "Step 8: Configuring kernel security parameters..."
    # Write to a dedicated drop-in file instead of appending to sysctl.conf —
    # idempotent because we overwrite the same file each run, never accumulate duplicates.
    cat > /etc/sysctl.d/99-hardening.conf << EOF
# Network Security Parameters (managed by bootstrap_server.sh)
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
EOF

    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-hardening.conf
    success "Kernel security parameters configured"
}

# ── Step 9: Secure shared memory ──────────────────────────────────────────────

secure_shared_memory() {
    info "Step 9: Securing shared memory..."
    # Mount /dev/shm (the canonical path; /run/shm is just a symlink to it on Ubuntu 24.04).
    # noexec: prevent executing binaries from shared memory
    # nosuid: prevent setuid/setgid bits from taking effect
    # nodev:  prevent device files in shared memory
    if ! grep -q "tmpfs.*/dev/shm" /etc/fstab; then
        echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
        # Apply immediately without requiring a reboot
        mount -o remount,noexec,nosuid,nodev /dev/shm
        success "Shared memory secured and remounted"
    else
        warn "Shared memory already configured"
    fi
}

# ── Step 10: Set up UFW firewall ──────────────────────────────────────────────

configure_ufw() {
    info "Step 10: Configuring UFW firewall..."
    # NOTE: Only SSH is opened by default. If this server runs a web application,
    # manually open the required ports after provisioning:
    #   ufw allow 80/tcp
    #   ufw allow 443/tcp
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp
    ufw --force enable
    success "UFW firewall configured (SSH port: $SSH_PORT only — add web ports manually if needed)"
}

# ── Step 11: Configure Fail2Ban ───────────────────────────────────────────────

configure_fail2ban() {
    info "Step 11: Configuring Fail2Ban..."
    cat > /etc/fail2ban/jail.local << EOF
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
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
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
    if [[ -f /swapfile ]]; then
        warn "Swap file already exists, skipping"
        return
    fi

    # fallocate is fast but unsupported on some filesystems (e.g. btrfs, some XFS configs).
    # Fall back to dd, which is universally compatible, if fallocate fails.
    if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
        warn "fallocate failed (unsupported filesystem?), falling back to dd..."
        # Derive block count (MiB) from SWAP_SIZE so dd honours the configured size.
        # Accepted formats: <N>G / <N>g  →  N*1024 MiB
        #                   <N>M / <N>m  →  N MiB
        local swap_mib
        if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
            swap_mib=$(( BASH_REMATCH[1] * 1024 ))
        elif [[ "$SWAP_SIZE" =~ ^([0-9]+)[Mm]$ ]]; then
            swap_mib=${BASH_REMATCH[1]}
        else
            error "Cannot derive dd block count from SWAP_SIZE='$SWAP_SIZE'; expected format like '2G' or '512M'"
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mib" status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Tune swappiness — 10 is a good default for a server (swap only under memory pressure)
    # Written to the drop-in file, not sysctl.conf, to avoid duplicates on re-runs
    cat >> /etc/sysctl.d/99-hardening.conf << EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p /etc/sysctl.d/99-hardening.conf
    success "Swap file created ($SWAP_SIZE) and enabled"
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

# ── Step 16: Set secure file permissions ──────────────────────────────────────

secure_file_permissions() {
    info "Step 16: Setting secure file permissions..."
    find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' -exec chmod 600 {} +
    chmod 644 /etc/passwd
    chmod 644 /etc/group
    chmod 600 /etc/shadow
    chmod 600 /etc/gshadow
    find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key.pub' -exec chmod 644 {} +
    success "File permissions secured"
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
    # Require a real TTY for sudo (prevents certain privilege escalation via cron/scripts)
    # NOTE: this can break cron jobs that themselves shell out to sudo — remove if you
    # need that pattern.
    cat > /etc/sudoers.d/hardening << 'EOF'
Defaults requiretty
Defaults timestamp_timeout=5
Defaults logfile=/var/log/sudo.log
Defaults log_input,log_output
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 440 /etc/sudoers.d/hardening
    # Validate the sudoers file before proceeding
    visudo -c -f /etc/sudoers.d/hardening
    success "Sudo hardening configured"
}

# ── Step 19: Restart services to apply changes ────────────────────────────────

restart_services() {
    info "Step 19: Restarting services..."
    systemctl restart ssh
    systemctl restart chrony
    systemctl restart fail2ban
    success "Services restarted"
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

    # Abort early if the hardcoded hash placeholder has not been replaced
    if [[ "$ts_expected_hash" == REPLACE_WITH_* ]]; then
        error "TS_EXPECTED_HASH has not been set. Follow the instructions in install_tailscale() to obtain and hardcode the SHA256 for tailscale_${ts_version}_amd64.deb."
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

        apt-get install -y "/tmp/${ts_deb}"
        rm -f "/tmp/${ts_deb}"
        success "Tailscale ${ts_version} installed"
    fi

    # Prevent unattended-upgrades from silently upgrading Tailscale.
    # You decide when to upgrade — update the pin above deliberately.
    if ! grep -q "tailscale" /etc/apt/apt.conf.d/50unattended-upgrades; then
        sed -i '/Unattended-Upgrade::Package-Blacklist {/a\    "tailscale";' \
            /etc/apt/apt.conf.d/50unattended-upgrades
        success "Tailscale pinned — excluded from automatic upgrades"
    fi

    # Build tailscale up arguments as an array, not a string — see #6 in
    # AGENTS.md for the rationale.
    local ts_up_args=()
    [[ -n "$TS_AUTHKEY" ]] && ts_up_args+=("--authkey=$TS_AUTHKEY")
    [[ "$TS_SSH" == true ]] && ts_up_args+=("--ssh")

    # Bring Tailscale up
    if [[ -n "$TS_AUTHKEY" ]]; then
        tailscale up "${ts_up_args[@]}"
        success "Tailscale connected (unattended)"

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
    echo -e "${YELLOW}1. SSH is now on port $SSH_PORT - connect with: ssh -p $SSH_PORT $USERNAME@your_server_ip${NC}"
    echo -e "${YELLOW}2. Test SSH connection with new user and port BEFORE closing this session${NC}"
    echo -e "${YELLOW}3. Password authentication is DISABLED${NC}"
    echo -e "${YELLOW}4. Root login is DISABLED${NC}"
    echo -e "${YELLOW}5. Only user '$USERNAME' can SSH to this server${NC}"
    echo -e "${YELLOW}6. Automatic security updates are ENABLED${NC}"
    echo -e "${YELLOW}7. sudo commands are fully logged to /var/log/sudo.log${NC}"
    if [[ "$INSTALL_TAILSCALE" == true && "$TS_SSH" == true && -n "$TS_AUTHKEY" ]]; then
        echo -e "${YELLOW}8. Public SSH port is CLOSED — connect via: ssh $USERNAME@<tailscale-hostname>${NC}"
        echo -e "${YELLOW}   Tailscale must be authenticated on your client device${NC}"
    fi
    if [[ "$INSTALL_TAILSCALE" == true && "$TS_SSH" == true ]]; then
        echo -e "${YELLOW}9. Tailscale SSH bypasses sshd entirely — PermitRootLogin has no effect over the tailnet.${NC}"
        echo -e "${YELLOW}   Restrict root login via your Tailscale ACL policy:${NC}"
        echo -e "${YELLOW}   https://login.tailscale.com/admin/acls${NC}"
        echo -e "${YELLOW}   Ensure your SSH ACL rule specifies users: [\"$USERNAME\"] and omits root.${NC}"
    fi
    echo ""
    warn "=== SECURITY FEATURES ENABLED ==="
    echo -e "${GREEN}✓${NC} UFW Firewall (SSH only: $SSH_PORT — add web ports manually if needed)"
    echo -e "${GREEN}✓${NC} Fail2Ban (12h SSH bans)"
    echo -e "${GREEN}✓${NC} Automatic security updates"
    echo -e "${GREEN}✓${NC} Kernel security hardening"
    echo -e "${GREEN}✓${NC} Strong password policies (pam_faillock)"
    echo -e "${GREEN}✓${NC} SSH hardened (modern ciphers/MACs/KEX only)"
    echo -e "${GREEN}✓${NC} AppArmor enforcement"
    echo -e "${GREEN}✓${NC} Time synchronization"
    echo -e "${GREEN}✓${NC} Secure file permissions"
    echo -e "${GREEN}✓${NC} Sudo hardening (TTY required, logging enabled)"
    echo -e "${GREEN}✓${NC} Swap file (${SWAP_SIZE})"
    if [[ "$INSTALL_TAILSCALE" == true ]]; then
        echo -e "${GREEN}✓${NC} Tailscale VPN installed"
        [[ "$TS_SSH" == true ]] && echo -e "${GREEN}✓${NC} Tailscale SSH enabled (public SSH port closed)"
    fi
    echo ""
    info "Sudo logs: /var/log/sudo.log"
    info "Run 'lynis audit system' for a detailed security assessment"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    require_root
    require_ubuntu 24.04

    parse_args "$@"
    print_plan

    update_system
    install_security_packages
    create_user
    grant_admin_privileges
    configure_password_policies
    setup_user_ssh_keys
    configure_sshd
    configure_sysctl_hardening
    secure_shared_memory
    configure_ufw
    configure_fail2ban
    configure_unattended_upgrades
    configure_swap
    configure_chrony
    disable_unused_services
    secure_file_permissions
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
