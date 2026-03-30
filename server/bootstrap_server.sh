#!/bin/bash

# Ubuntu Server Bootstrap Script
# Usage: ./bootstrap_server.sh <username> [ssh_port] [--tailscale] [--ts-authkey <key>] [--ts-ssh]

# Exit on any error, treat unset variables as errors, and fail on pipeline errors
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# Verify this is Ubuntu 24.04 (Noble)
# The script targets 24.04 specifically; behaviour on other versions is untested.
if ! grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
    print_error "This script requires Ubuntu 24.04 (Noble). Detected:"
    grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null || echo "  (unknown OS)"
    exit 1
fi

# Check if username argument is provided
if [ $# -lt 1 ]; then
    print_error "Usage: $0 <username> [ssh_port] [--tailscale] [--ts-authkey <key>] [--ts-ssh]"
    print_error "Example: $0 myuser 2222 --tailscale --ts-authkey tskey-auth-xxx"
    print_error ""
    print_error "Options:"
    print_error "  --tailscale          Install and configure Tailscale"
    print_error "  --ts-authkey <key>   Tailscale auth key for unattended provisioning"
    print_error "                       Generate at https://login.tailscale.com/admin/settings/keys"
    print_error "                       Use ephemeral keys for short-lived droplets"
    print_error "  --ts-ssh             Enable Tailscale SSH (replaces key-based SSH over tailnet)"
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
    print_error "Invalid second argument: '$2'. Expected a numeric SSH port or a --flag."
    exit 1
else
    SSH_PORT="22"  # only username was supplied
    shift 1
fi

# Validate SSH port is a number in the valid range
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
    print_error "Invalid SSH port: '$SSH_PORT'. Must be a number between 1 and 65535."
    exit 1
fi

# Tailscale options (all off by default)
INSTALL_TAILSCALE=false
TS_AUTHKEY=""
TS_SSH=false

# Parse optional flags — $@ now contains only flags (positional args already consumed above)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tailscale)    INSTALL_TAILSCALE=true ;;
        --ts-authkey)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                print_error "--ts-authkey requires a value"
                exit 1
            fi
            TS_AUTHKEY="$2"; shift ;;
        --ts-ssh)       TS_SSH=true ;;
        *) print_warning "Unknown option: $1" ;;
    esac
    shift
done

print_status "Starting Ubuntu server bootstrap process..."
print_status "Creating user: $USERNAME"
print_status "SSH will be configured on port: $SSH_PORT"
if [ "$INSTALL_TAILSCALE" = true ]; then
    print_status "Tailscale: ENABLED"
    [ -n "$TS_AUTHKEY" ] && print_status "  → Unattended auth key provided"
    [ "$TS_SSH" = true ] && print_status "  → Tailscale SSH enabled (SSH port closed to public)"
else
    print_status "Tailscale: not requested (pass --tailscale to enable)"
fi

# 1. Update installed packages first
print_status "Step 1: Updating system packages..."
apt update && apt upgrade -y
print_success "System packages updated successfully"

# 2. Install essential security packages
print_status "Step 2: Installing essential security packages..."
apt install -y \
    fail2ban \
    ufw \
    unattended-upgrades \
    apt-listchanges \
    libpam-pwquality \
    chrony \
    lynis \
    apparmor-utils
print_success "Security packages installed"

# 3. Create new user
print_status "Step 3: Creating new user '$USERNAME'..."
if id "$USERNAME" &>/dev/null; then
    print_warning "User '$USERNAME' already exists, skipping user creation"
else
    # Create user with home directory
    adduser --gecos "" "$USERNAME"
    print_success "User '$USERNAME' created successfully"
fi

# 4. Grant admin privileges to the new user
print_status "Step 4: Granting admin privileges to '$USERNAME'..."
usermod -aG sudo "$USERNAME"
print_success "Admin privileges granted to '$USERNAME'"

# 5. Configure password policies
print_status "Step 5: Configuring password policies..."
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

print_success "Password policies configured"

# 6. Set up SSH key directory for new user and copy root's authorized_keys
print_status "Step 6: Setting up SSH key directory for '$USERNAME'..."
USER_HOME="/home/$USERNAME"
SSH_DIR="$USER_HOME/.ssh"

if [ ! -d "$SSH_DIR" ]; then
    sudo -u "$USERNAME" mkdir -p "$SSH_DIR"
    sudo -u "$USERNAME" chmod 700 "$SSH_DIR"
fi

# Copy root's authorized_keys if present, otherwise create an empty file.
# Copying allows the same key used to access the droplet as root to immediately
# work for the new user — no need to re-add it manually.
ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
if [ -s "$ROOT_AUTHORIZED_KEYS" ]; then
    cp "$ROOT_AUTHORIZED_KEYS" "$SSH_DIR/authorized_keys"
    chown "$USERNAME:$USERNAME" "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    KEY_COUNT=$(wc -l < "$SSH_DIR/authorized_keys")
    print_success "Copied $KEY_COUNT key(s) from root's authorized_keys to $SSH_DIR/authorized_keys"
else
    sudo -u "$USERNAME" touch "$SSH_DIR/authorized_keys"
    sudo -u "$USERNAME" chmod 600 "$SSH_DIR/authorized_keys"
    print_warning "No keys found in $ROOT_AUTHORIZED_KEYS — authorized_keys created empty"
    print_warning "Remember to add your public key to $SSH_DIR/authorized_keys before disconnecting"
fi

# 7. Configure SSH security settings
print_status "Step 7: Configuring SSH security settings..."
SSH_CONFIG="/etc/ssh/sshd_config"

# Always restore from the original pristine backup if one exists,
# otherwise create it now. This makes the step safe to re-run —
# we never layer sed edits or appended blocks on top of each other.
PRISTINE_BACKUP="/etc/ssh/sshd_config.pristine"
if [ ! -f "$PRISTINE_BACKUP" ]; then
    cp "$SSH_CONFIG" "$PRISTINE_BACKUP"
    print_status "Saved pristine sshd_config backup to $PRISTINE_BACKUP"
fi

# Take a timestamped backup for this run, then reset to pristine
cp "$SSH_CONFIG" "$SSH_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
cp "$PRISTINE_BACKUP" "$SSH_CONFIG"

# Configure SSH settings
sed -i -E "s/^#?Port 22$/Port $SSH_PORT/" "$SSH_CONFIG"
sed -i -E 's/^#?PasswordAuthentication\s+\S+/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i -E 's/^#?PermitRootLogin\s+\S+/PermitRootLogin no/' "$SSH_CONFIG"
sed -i -E 's/^#?PubkeyAuthentication\s+\S+/PubkeyAuthentication yes/' "$SSH_CONFIG"

# Add additional security settings (safe to append — we always start from pristine)
cat >> "$SSH_CONFIG" << EOF

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
    print_error "sshd config validation failed — restoring backup and aborting"
    cp "$PRISTINE_BACKUP" "$SSH_CONFIG"
    exit 1
fi

print_success "SSH configuration updated (Port: $SSH_PORT)"

# 8. Configure kernel security parameters
print_status "Step 8: Configuring kernel security parameters..."
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
print_success "Kernel security parameters configured"

# 9. Secure shared memory
print_status "Step 9: Securing shared memory..."
# Mount /dev/shm (the canonical path; /run/shm is just a symlink to it on Ubuntu 24.04).
# noexec: prevent executing binaries from shared memory
# nosuid: prevent setuid/setgid bits from taking effect
# nodev:  prevent device files in shared memory
if ! grep -q "tmpfs.*/dev/shm" /etc/fstab; then
    echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
    # Apply immediately without requiring a reboot
    mount -o remount,noexec,nosuid,nodev /dev/shm
    print_success "Shared memory secured and remounted"
else
    print_warning "Shared memory already configured"
fi

# 10. Set up UFW firewall
print_status "Step 10: Configuring UFW firewall..."
# NOTE: Only SSH is opened by default. If this server runs a web application,
# manually open the required ports after provisioning:
#   ufw allow 80/tcp
#   ufw allow 443/tcp
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable
print_success "UFW firewall configured (SSH port: $SSH_PORT only — add web ports manually if needed)"

# 11. Configure Fail2Ban
print_status "Step 11: Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
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
bantime = 24h

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
print_success "Fail2Ban configured and started"

# 12. Configure automatic security updates
print_status "Step 12: Configuring automatic security updates..."
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
print_success "Automatic security updates configured"

# 13. Configure swap file
print_status "Step 13: Configuring swap file..."
SWAP_SIZE="2G"
if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
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
    print_success "Swap file created ($SWAP_SIZE) and enabled"
else
    print_warning "Swap file already exists, skipping"
fi

# 14. Configure chrony for time synchronization
print_status "Step 14: Configuring time synchronization..."
systemctl enable chrony
systemctl start chrony
print_success "Time synchronization configured"

# 15. Disable unused services
print_status "Step 15: Disabling unused services..."
services_to_disable=("avahi-daemon" "cups" "isc-dhcp-server" "isc-dhcp-server6" "rpcbind" "nfs-server")

for service in "${services_to_disable[@]}"; do
    if systemctl is-enabled "$service" &>/dev/null; then
        systemctl disable "$service"
        systemctl stop "$service" 2>/dev/null || true
        print_status "Disabled service: $service"
    fi
done
print_success "Unused services disabled"

# 16. Set proper file permissions
print_status "Step 16: Setting secure file permissions..."
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/passwd
chmod 644 /etc/group
chmod 600 /etc/shadow
chmod 600 /etc/gshadow
chmod 644 /etc/ssh/ssh_host_*_key.pub
print_success "File permissions secured"

# 17. Configure AppArmor
print_status "Step 17: Configuring AppArmor..."
systemctl enable apparmor
systemctl start apparmor
# aa-enforce can fail for individual broken profiles; continue rather than aborting the run.
aa-enforce /etc/apparmor.d/* || print_warning "Some AppArmor profiles could not be enforced — review 'aa-status' after provisioning"
print_success "AppArmor configured and enforcing"

# 18. Configure sudo hardening
print_status "Step 18: Configuring sudo hardening..."
# Require a real TTY for sudo (prevents certain privilege escalation via cron/scripts)
echo "Defaults requiretty" > /etc/sudoers.d/hardening
# Set a short sudo credential cache timeout (default is 15 min)
echo "Defaults timestamp_timeout=5" >> /etc/sudoers.d/hardening
# Log all sudo commands to syslog
echo "Defaults logfile=/var/log/sudo.log" >> /etc/sudoers.d/hardening
echo "Defaults log_input,log_output" >> /etc/sudoers.d/hardening
# Prevent sudo from inheriting the user's environment variables
echo "Defaults env_reset" >> /etc/sudoers.d/hardening
echo "Defaults secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" >> /etc/sudoers.d/hardening
chmod 440 /etc/sudoers.d/hardening
# Validate the sudoers file before proceeding
visudo -c -f /etc/sudoers.d/hardening
print_success "Sudo hardening configured"

# 19. Restart services to apply changes
print_status "Step 19: Restarting services..."
systemctl restart ssh
systemctl restart chrony
systemctl restart fail2ban
print_success "Services restarted"

# 20. Install and configure Tailscale (optional)
if [ "$INSTALL_TAILSCALE" = true ]; then
    print_status "Step 20: Installing and configuring Tailscale..."

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
    TS_VERSION="1.96.2"
    TS_DEB="tailscale_${TS_VERSION}_amd64.deb"
    TS_URL="https://pkgs.tailscale.com/stable/${TS_DEB}"
    # SHA256 of tailscale_1.96.2_amd64.deb — verify before updating the pin (see above).
    TS_EXPECTED_HASH="0431610d988ec54643a6beeae35f943aa3f11362577828138d367ca5aac29bc6"

    # Abort early if the hardcoded hash placeholder has not been replaced
    if [[ "$TS_EXPECTED_HASH" == REPLACE_WITH_* ]]; then
        print_error "TS_EXPECTED_HASH has not been set. Follow the instructions in the script"
        print_error "to obtain and hardcode the SHA256 for tailscale_${TS_VERSION}_amd64.deb."
        exit 1
    fi

    # Skip download and install if this exact version is already installed
    INSTALLED_VERSION=$(tailscale version 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [ "$INSTALLED_VERSION" = "$TS_VERSION" ]; then
        print_warning "Tailscale ${TS_VERSION} already installed, skipping download"
    else
        print_status "Downloading Tailscale ${TS_VERSION}..."
        curl -fsSL "$TS_URL" -o "/tmp/${TS_DEB}"

        # Verify against the hardcoded hash
        print_status "Verifying checksum..."
        echo "${TS_EXPECTED_HASH}  /tmp/${TS_DEB}" | sha256sum --check --strict
        print_success "Checksum verified"

        apt install -y "/tmp/${TS_DEB}"
        rm -f "/tmp/${TS_DEB}"
        print_success "Tailscale ${TS_VERSION} installed"
    fi

    # Prevent unattended-upgrades from silently upgrading Tailscale.
    # You decide when to upgrade — update the pin above deliberately.
    if ! grep -q "tailscale" /etc/apt/apt.conf.d/50unattended-upgrades; then
        sed -i '/Unattended-Upgrade::Package-Blacklist {/a\    "tailscale";' \
            /etc/apt/apt.conf.d/50unattended-upgrades
        print_success "Tailscale pinned — excluded from automatic upgrades"
    fi

    # Build tailscale up arguments
    TS_UP_ARGS=""
    [ -n "$TS_AUTHKEY" ] && TS_UP_ARGS="$TS_UP_ARGS --authkey=$TS_AUTHKEY"
    [ "$TS_SSH" = true ] && TS_UP_ARGS="$TS_UP_ARGS --ssh"

    # Bring Tailscale up
    if [ -n "$TS_AUTHKEY" ]; then
        tailscale up $TS_UP_ARGS
        print_success "Tailscale connected (unattended)"

        # If Tailscale SSH is enabled: close the public SSH port,
        # trust the tailscale0 interface instead.
        # SSH over the tailnet is handled entirely by Tailscale's daemon.
        if [ "$TS_SSH" = true ]; then
            print_status "Locking down public SSH port — access via Tailscale SSH only..."
            ufw delete allow "$SSH_PORT"/tcp 2>/dev/null || true
            ufw allow in on tailscale0
            ufw reload
            print_success "Public SSH port $SSH_PORT closed; tailscale0 interface trusted"
            print_warning "Connect with: ssh $USERNAME@<tailscale-hostname-or-ip>"
            print_warning "Tailscale must be running on your client device"
        fi
    else
        # Start the daemon but defer auth — operator must run 'tailscale up' manually
        systemctl enable --now tailscaled
        print_warning "Tailscale daemon started but NOT authenticated."
        print_warning "Run the following to complete setup:"
        echo ""
        if [ "$TS_SSH" = true ]; then
            echo "  tailscale up --ssh"
        else
            echo "  tailscale up"
        fi
        echo ""
        print_warning "Do NOT close this SSH session until Tailscale is authenticated"
        print_warning "and you have verified connectivity over the tailnet."
        if [ "$TS_SSH" = true ]; then
            print_warning "After verifying tailnet access, manually run:"
            echo "  ufw delete allow $SSH_PORT/tcp"
            echo "  ufw allow in on tailscale0"
            echo "  ufw reload"
        fi
    fi

    print_success "Tailscale configuration complete"
fi

# 21. Display security status
print_status "=== SECURITY STATUS ==="
echo ""
print_status "UFW Firewall Status:"
ufw status

echo ""
print_status "Fail2Ban Status:"
fail2ban-client status

echo ""
print_status "AppArmor Status:"
aa-status --enabled

echo ""
print_status "Swap Status:"
swapon --show

echo ""
print_status "Time Synchronization:"
chronyc sources

# 22. Final security summary
print_success "Server bootstrapping completed successfully!"
echo ""
print_warning "=== CRITICAL REMINDERS ==="
echo -e "${YELLOW}1. SSH is now on port $SSH_PORT - connect with: ssh -p $SSH_PORT $USERNAME@your_server_ip${NC}"
echo -e "${YELLOW}2. Test SSH connection with new user and port BEFORE closing this session${NC}"
echo -e "${YELLOW}3. Password authentication is DISABLED${NC}"
echo -e "${YELLOW}4. Root login is DISABLED${NC}"
echo -e "${YELLOW}5. Only user '$USERNAME' can SSH to this server${NC}"
echo -e "${YELLOW}6. Automatic security updates are ENABLED${NC}"
echo -e "${YELLOW}7. sudo commands are fully logged to /var/log/sudo.log${NC}"
if [ "$INSTALL_TAILSCALE" = true ] && [ "$TS_SSH" = true ] && [ -n "$TS_AUTHKEY" ]; then
    echo -e "${YELLOW}8. Public SSH port is CLOSED — connect via: ssh $USERNAME@<tailscale-hostname>${NC}"
    echo -e "${YELLOW}   Tailscale must be authenticated on your client device${NC}"
fi
if [ "$INSTALL_TAILSCALE" = true ] && [ "$TS_SSH" = true ]; then
    echo -e "${YELLOW}9. Tailscale SSH bypasses sshd entirely — PermitRootLogin has no effect over the tailnet.${NC}"
    echo -e "${YELLOW}   Restrict root login via your Tailscale ACL policy:${NC}"
    echo -e "${YELLOW}   https://login.tailscale.com/admin/acls${NC}"
    echo -e "${YELLOW}   Ensure your SSH ACL rule specifies users: [\"$USERNAME\"] and omits root.${NC}"
fi
echo ""
print_warning "=== SECURITY FEATURES ENABLED ==="
echo -e "${GREEN}✓${NC} UFW Firewall (SSH only: $SSH_PORT — add web ports manually if needed)"
echo -e "${GREEN}✓${NC} Fail2Ban (24h SSH bans)"
echo -e "${GREEN}✓${NC} Automatic security updates"
echo -e "${GREEN}✓${NC} Kernel security hardening"
echo -e "${GREEN}✓${NC} Strong password policies (pam_faillock)"
echo -e "${GREEN}✓${NC} SSH hardened (modern ciphers/MACs/KEX only)"
echo -e "${GREEN}✓${NC} AppArmor enforcement"
echo -e "${GREEN}✓${NC} Time synchronization"
echo -e "${GREEN}✓${NC} Secure file permissions"
echo -e "${GREEN}✓${NC} Sudo hardening (TTY required, logging enabled)"
echo -e "${GREEN}✓${NC} Swap file (${SWAP_SIZE})"
if [ "$INSTALL_TAILSCALE" = true ]; then
    echo -e "${GREEN}✓${NC} Tailscale VPN installed"
    [ "$TS_SSH" = true ] && echo -e "${GREEN}✓${NC} Tailscale SSH enabled (public SSH port closed)"
fi
echo ""
print_status "Sudo logs: /var/log/sudo.log"
print_status "Run 'lynis audit system' for a detailed security assessment"
