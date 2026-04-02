#!/bin/bash

# Vaultwarden Setup Script (Podman + Tailscale edition)
#
# Sets up a Vaultwarden instance (self-hosted Bitwarden-compatible password
# manager) running in a Podman container, with TLS provided directly by
# Tailscale. No nginx or Let's Encrypt required — the droplet must already
# be joined to a Tailscale network with MagicDNS and HTTPS certificates
# enabled in the Tailscale admin console.
#
# What this script does:
#   1. Installs Podman and dependencies
#   2. Creates a persistent data directory at /srv/vaultwarden
#   3. Fetches a TLS certificate for the Tailscale hostname
#   4. Installs a daily cert-refresh cron job
#   5. Writes an env config file at /etc/vaultwarden/vaultwarden.conf
#   6. Writes a docker-compose.yml at /etc/vaultwarden/docker-compose.yml
#   7. Creates a systemd service to manage the container
#   8. Pulls the Vaultwarden image and starts the container
#
# Prerequisites:
#   - Tailscale is installed, running, and the machine is joined to your tailnet
#   - MagicDNS is enabled in the Tailscale admin console (DNS → Enable MagicDNS)
#   - HTTPS certificates are enabled in the Tailscale admin console (DNS → Enable HTTPS)
#   - UFW (or equivalent) is already configured
#
# Usage:
#   sudo ./setup_vaultwarden.sh <tailscale-hostname> [options]
#
#   <tailscale-hostname> is the full MagicDNS name of this machine, e.g.:
#     my-droplet.tail1234.ts.net
#
# Options:
#   --port        Port to bind Vaultwarden on the Tailscale interface (default: 443)
#   --admin-token Token for the /admin interface (default: randomly generated)
#
# Examples:
#   sudo ./setup_vaultwarden.sh my-droplet.tail1234.ts.net
#   sudo ./setup_vaultwarden.sh my-droplet.tail1234.ts.net --port 8443
#
# After setup:
#   1. Visit https://<tailscale-hostname> and create your account
#   2. Visit https://<tailscale-hostname>/admin (using your admin token) to configure
#   3. Once your account is created, disable signups and the admin interface:
#        sudo ./setup_vaultwarden.sh harden
#      or edit /etc/vaultwarden/vaultwarden.conf manually and restart:
#        systemctl restart vaultwarden

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
print_section() { echo -e "\n${CYAN}━━━  $1  ━━━${NC}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
# Pin to a specific version for reproducible deploys. To update, change this
# value and re-run: podman compose -f $VW_COMPOSE_FILE pull && systemctl restart vaultwarden
# v1.32.7 ships Vaultwarden 1.32.7; WebSockets are on the main port (v1.29+).
VW_IMAGE="docker.io/vaultwarden/server:1.32.7"

# Dedicated unprivileged system user — Podman runs rootless under this account
# so a container escape cannot yield root on the host.
VW_SYSTEM_USER="vaultwarden"

VW_DATA_DIR="/srv/vaultwarden"
VW_CERT_DIR="/srv/vaultwarden/certs"
VW_CONF_DIR="/etc/vaultwarden"
VW_ENV_FILE="$VW_CONF_DIR/vaultwarden.conf"
VW_COMPOSE_FILE="$VW_CONF_DIR/docker-compose.yml"
VW_SYSTEMD_SERVICE="/etc/systemd/system/vaultwarden.service"
CERT_REFRESH_SCRIPT="/usr/local/bin/vaultwarden-cert-refresh"

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

# ── Tailscale check ───────────────────────────────────────────────────────────
check_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        print_error "Tailscale is not installed. Install and join your tailnet first."
        exit 1
    fi

    local ts_status
    ts_status=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState',''))" 2>/dev/null || echo "")
    if [[ "$ts_status" != "Running" ]]; then
        print_error "Tailscale is not running or not authenticated (state: ${ts_status:-unknown})"
        print_error "Run: tailscale up"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# CERT REFRESH — fetch/renew Tailscale TLS cert and copy into the data dir
# ══════════════════════════════════════════════════════════════════════════════
cmd_cert_refresh() {
    local hostname="$1"

    print_info "Fetching Tailscale TLS certificate for $hostname..."

    # Snapshot the fingerprint of the cert already in place (if any) so we can
    # detect whether tailscale cert actually issued a new one.
    local old_fingerprint=""
    if [ -f "$VW_CERT_DIR/fullchain.pem" ]; then
        old_fingerprint=$(openssl x509 -noout -fingerprint -sha256 \
            -in "$VW_CERT_DIR/fullchain.pem" 2>/dev/null || true)
    fi

    # Ensure the cert dir exists and has correct ownership/permissions whether
    # this is called from setup or standalone (e.g. cert-refresh subcommand).
    mkdir -p "$VW_CERT_DIR"
    chown root:"$VW_SYSTEM_USER" "$VW_CERT_DIR"
    chmod 750 "$VW_CERT_DIR"

    tailscale cert --cert-file "/var/lib/tailscale/certs/${hostname}.crt" \
                   --key-file  "/var/lib/tailscale/certs/${hostname}.key" \
                   "$hostname"

    cp "/var/lib/tailscale/certs/${hostname}.crt" "$VW_CERT_DIR/fullchain.pem"
    cp "/var/lib/tailscale/certs/${hostname}.key" "$VW_CERT_DIR/privkey.pem"

    # The key must be readable by the vaultwarden user (which runs the rootless
    # container) but not world-readable. The cert is public so 644 is fine.
    chown root:"$VW_SYSTEM_USER" "$VW_CERT_DIR/privkey.pem" "$VW_CERT_DIR/fullchain.pem"
    chmod 640 "$VW_CERT_DIR/privkey.pem"
    chmod 644 "$VW_CERT_DIR/fullchain.pem"

    print_success "Certificate copied to $VW_CERT_DIR"

    # Only restart if the cert actually changed — avoids a needless service
    # interruption on days when tailscale cert returns the cached cert unchanged.
    local new_fingerprint
    new_fingerprint=$(openssl x509 -noout -fingerprint -sha256 \
        -in "$VW_CERT_DIR/fullchain.pem" 2>/dev/null || true)

    if [ "$old_fingerprint" = "$new_fingerprint" ] && [ -n "$new_fingerprint" ]; then
        print_info "Certificate unchanged — skipping Vaultwarden restart"
    elif systemctl is-active --quiet vaultwarden 2>/dev/null; then
        systemctl restart vaultwarden
        print_success "Vaultwarden restarted to pick up new certificate"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# HARDEN — disable signups and admin interface post-setup
# ══════════════════════════════════════════════════════════════════════════════
cmd_harden() {
    print_section "Hardening Vaultwarden"

    if [ ! -f "$VW_ENV_FILE" ]; then
        print_error "Vaultwarden config not found at $VW_ENV_FILE"
        print_error "Has Vaultwarden been set up yet?"
        exit 1
    fi

    # Disable signups
    if grep -q '^SIGNUPS_ALLOWED=false' "$VW_ENV_FILE"; then
        print_info "SIGNUPS_ALLOWED already false — skipping"
    else
        sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=false/' "$VW_ENV_FILE"
        print_success "Signups disabled"
    fi

    # Disable admin interface
    if grep -q '^#ADMIN_TOKEN=' "$VW_ENV_FILE"; then
        print_info "Admin interface already disabled — skipping"
    elif grep -q '^ADMIN_TOKEN=' "$VW_ENV_FILE"; then
        sed -i 's/^ADMIN_TOKEN=/#ADMIN_TOKEN=/' "$VW_ENV_FILE"
        print_success "Admin interface disabled"
    else
        print_warning "ADMIN_TOKEN line not found in $VW_ENV_FILE — check manually"
    fi

    systemctl restart vaultwarden
    print_success "Vaultwarden restarted with hardened config"
    print_info "To re-enable the admin interface, edit $VW_ENV_FILE,"
    print_info "uncomment ADMIN_TOKEN, and run: systemctl restart vaultwarden"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════════════
cmd_setup() {
    # ── Parse arguments ───────────────────────────────────────────────────────
    local hostname="$1"; shift
    local port=443 admin_token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)         port="$2";         shift 2 ;;
            --admin-token)  admin_token="$2";  shift 2 ;;
            --help|-h)      cmd_help; exit 0 ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    [ -z "$hostname" ] && { print_error "Tailscale hostname is required"; exit 1; }

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        print_error "Invalid port '$port' — must be an integer between 1 and 65535"
        exit 1
    fi

    # ── Preflight checks ──────────────────────────────────────────────────────
    check_tailscale

    # Resolve the Tailscale IP for this machine — used to bind Rocket to the
    # Tailscale interface only, so Vaultwarden is not reachable on the public IP
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
    if [ -z "$ts_ip" ]; then
        print_error "Could not determine Tailscale IPv4 address. Is the machine on the tailnet?"
        exit 1
    fi
    print_info "Tailscale IPv4: $ts_ip"

    # Validate that the supplied hostname matches this machine's actual Tailscale
    # MagicDNS name. A mismatch means the cert will be for the wrong host.
    local actual_hostname
    actual_hostname=$(tailscale status --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Self']['DNSName'].rstrip('.'))" \
        2>/dev/null || echo "")
    if [ -z "$actual_hostname" ]; then
        print_warning "Could not verify Tailscale hostname (MagicDNS may not be enabled)."
        print_warning "Continuing with supplied hostname: $hostname"
    elif [ "$hostname" != "$actual_hostname" ]; then
        print_error "Supplied hostname '$hostname' does not match this machine's Tailscale hostname '$actual_hostname'."
        print_error "The TLS certificate would be for the wrong host. Did you mean:"
        print_error "  sudo $0 $actual_hostname"
        exit 1
    else
        print_info "Hostname verified: $hostname"
    fi

    # Check for existing installation before doing anything destructive
    if [ -f "$VW_ENV_FILE" ] || [ -f "$VW_SYSTEMD_SERVICE" ]; then
        print_error "Vaultwarden appears to already be installed."
        print_error "To remove it, stop and disable the service, then remove $VW_CONF_DIR and $VW_DATA_DIR."
        exit 1
    fi

    # Generate the raw admin token now (before any installs) so we can fail
    # fast on bad input. The actual Argon2 hashing happens after Step 1
    # installs the argon2 package.
    if [ -z "$admin_token" ]; then
        admin_token=$(openssl rand -hex 32)
    fi

    print_section "Setting up Vaultwarden on $hostname (port $port)"

    # ── Step 1: Install dependencies ──────────────────────────────────────────
    print_info "Step 1: Installing podman-compose and argon2..."
    apt-get update -qq
    apt-get install -y podman-compose argon2
    print_success "Dependencies installed"

    # Hash the admin token now that argon2 is available.
    # Vaultwarden expects an Argon2id hash in ADMIN_TOKEN — storing plaintext
    # works but triggers a startup warning and exposes the token in the config.
    # The raw token goes into a root-only reveal file; never to the terminal.
    local salt
    salt=$(openssl rand -base64 16)
    local admin_token_hash
    admin_token_hash=$(echo -n "$admin_token" | argon2 "$salt" -id -t 3 -m 17 -p 4 -l 32 -e)

    # Write the raw token to a one-time reveal file, never to the terminal.
    local token_reveal_file="/root/vaultwarden-admin-token.txt"
    if [ -f "$token_reveal_file" ]; then
        print_error "$token_reveal_file already exists from a previous (partial?) run."
        print_error "Remove it first: sudo rm $token_reveal_file"
        print_error "If you still have the token it contained, that's fine — it won't be reused."
        exit 1
    fi
    cat > "$token_reveal_file" << EOF
Vaultwarden admin token — delete this file after noting the token down.
Generated: $(date)

Raw token (paste this into the /admin login page):
$admin_token

The Argon2 hash of this token is stored in $VW_ENV_FILE.
EOF
    chmod 600 "$token_reveal_file"
    print_info "Admin token written to $token_reveal_file (root-only)"
    print_warning "Read it with: sudo cat $token_reveal_file"
    print_warning "Delete it after noting the token: sudo rm $token_reveal_file"

    # ── Step 2: Create system user and directories ────────────────────────────
    print_info "Step 2: Creating directories..."

    mkdir -p "$VW_DATA_DIR"
    mkdir -p "$VW_CERT_DIR"
    mkdir -p "$VW_CONF_DIR"
    # Data dir is owned by the system user.
    chown -R "$VW_SYSTEM_USER:$VW_SYSTEM_USER" "$VW_DATA_DIR"
    # Config dir stays root-owned (it holds the admin token hash) but the
    # vaultwarden user needs execute permission to enter it so it can read
    # the group-readable env and compose files within (fixes systemd
    # WorkingDirectory access and podman compose file reads).
    chown root:"$VW_SYSTEM_USER" "$VW_CONF_DIR"
    chmod 750 "$VW_CONF_DIR"
    print_success "Directories created"

    # ── Step 3: Fetch TLS certificate ─────────────────────────────────────────
    print_section "Step 3: Fetching Tailscale TLS certificate"
    print_info "This requires HTTPS certificates to be enabled in your Tailscale admin console"
    print_info "(DNS → Enable HTTPS)"
    cmd_cert_refresh "$hostname"

    # ── Step 4: Install cert-refresh cron and script ──────────────────────────
    print_info "Step 4: Installing certificate refresh cron job..."

    cat > "$CERT_REFRESH_SCRIPT" << 'REFRESH_EOF'
#!/bin/bash
# Vaultwarden Tailscale cert refresh
# Fetches a renewed cert from Tailscale and restarts Vaultwarden only if the
# cert actually changed. Installed by setup_vaultwarden.sh — do not edit the
# variable values below. Inlines all logic so it works even if
# setup_vaultwarden.sh is moved or deleted.
set -euo pipefail

REFRESH_EOF

    # Emit the variable values baked in at install time, then the rest of the
    # script logic as a literal heredoc (single-quoted delimiter avoids
    # expansion of \${} inside the logic block).
    cat >> "$CERT_REFRESH_SCRIPT" << EOF
HOSTNAME="$hostname"
VW_CERT_DIR="$VW_CERT_DIR"
VW_SYSTEM_USER="$VW_SYSTEM_USER"
EOF

    cat >> "$CERT_REFRESH_SCRIPT" << 'REFRESH_EOF'

# Ensure cert dir exists with correct ownership/permissions — makes this script
# self-contained even if called on a machine with a wiped cert dir.
mkdir -p "$VW_CERT_DIR"
chown root:"$VW_SYSTEM_USER" "$VW_CERT_DIR"
chmod 750 "$VW_CERT_DIR"

# Snapshot the fingerprint of the cert currently in place (if any).
old_fingerprint=""
if [ -f "$VW_CERT_DIR/fullchain.pem" ]; then
    old_fingerprint=$(openssl x509 -noout -fingerprint -sha256 \
        -in "$VW_CERT_DIR/fullchain.pem" 2>/dev/null || true)
fi

tailscale cert --cert-file "/var/lib/tailscale/certs/${HOSTNAME}.crt" \
               --key-file  "/var/lib/tailscale/certs/${HOSTNAME}.key" \
               "$HOSTNAME"

cp "/var/lib/tailscale/certs/${HOSTNAME}.crt" "$VW_CERT_DIR/fullchain.pem"
cp "/var/lib/tailscale/certs/${HOSTNAME}.key" "$VW_CERT_DIR/privkey.pem"

chown root:"$VW_SYSTEM_USER" "$VW_CERT_DIR/privkey.pem" "$VW_CERT_DIR/fullchain.pem"
chmod 640 "$VW_CERT_DIR/privkey.pem"
chmod 644 "$VW_CERT_DIR/fullchain.pem"

new_fingerprint=$(openssl x509 -noout -fingerprint -sha256 \
    -in "$VW_CERT_DIR/fullchain.pem" 2>/dev/null || true)

if [ "$old_fingerprint" = "$new_fingerprint" ] && [ -n "$new_fingerprint" ]; then
    echo "$(date): Certificate unchanged — Vaultwarden restart skipped"
elif systemctl is-active --quiet vaultwarden 2>/dev/null; then
    systemctl restart vaultwarden
    echo "$(date): Certificate refreshed and Vaultwarden restarted"
else
    echo "$(date): Certificate refreshed (Vaultwarden not running — skipped restart)"
fi
REFRESH_EOF

    chmod 700 "$CERT_REFRESH_SCRIPT"

    # Run daily at 04:00 — Tailscale certs are valid for ~90 days so this is
    # ample headroom. tailscale cert is a no-op if the cert is still fresh.
    echo "0 4 * * * root $CERT_REFRESH_SCRIPT >> /var/log/vaultwarden-cert-refresh.log 2>&1" \
        > /etc/cron.d/vaultwarden-cert-refresh

    print_success "Cert refresh script installed at $CERT_REFRESH_SCRIPT"
    print_success "Cron job installed: daily at 04:00"

    # ── Step 5: Write env config ──────────────────────────────────────────────
    print_info "Step 5: Writing Vaultwarden config to $VW_ENV_FILE..."

    cat > "$VW_ENV_FILE" << EOF
# Vaultwarden environment configuration
# Managed by setup_vaultwarden.sh
#
# After creating your account, run: sudo ./setup_vaultwarden.sh harden
# This will set SIGNUPS_ALLOWED=false and disable the admin interface.

# Bind Rocket to all interfaces inside the container.
ROCKET_ADDRESS=0.0.0.0

# Port Vaultwarden's web server (Rocket) listens on.
ROCKET_PORT=$port

# TLS certificate and key — provided by Tailscale, refreshed daily by cron.
# These paths are inside the container (mounted from $VW_CERT_DIR on the host).
ROCKET_TLS={certs="/data/certs/fullchain.pem",key="/data/certs/privkey.pem"}

# Allow new user registrations. Set to false after creating your account
# by running: sudo ./setup_vaultwarden.sh harden
SIGNUPS_ALLOWED=true

# Require email verification on signup (requires SMTP config below)
SIGNUPS_VERIFY=false

# Prevent users from creating organisations (and thus inviting others).
# Set to a comma-separated list of email addresses to whitelist specific users,
# or leave empty ("") to allow all users to create orgs.
ORG_CREATION_USERS=none

# Admin interface token — treat this like a password.
# Stored as an Argon2id hash; paste the RAW token (from /root/vaultwarden-admin-token.txt)
# into the browser, NOT the hash. Comment out to disable the /admin interface entirely.
ADMIN_TOKEN=ADMIN_TOKEN_PLACEHOLDER

# Don't show password hints on the login page
SHOW_PASSWORD_HINT=false

# --- Optional: SMTP for email notifications and signup verification ---
# Uncomment and fill in to enable email support.
#SMTP_HOST=smtp.example.com
#SMTP_PORT=587
#SMTP_SECURITY=starttls
#SMTP_USERNAME=you@example.com
#SMTP_PASSWORD=yourpassword
#SMTP_FROM=vaultwarden@example.com
EOF

    # Protect the config — it contains the admin token hash.
    # Group-readable so the vaultwarden user (which runs podman) can read it;
    # root-owned so only root can modify it.
    chown root:"$VW_SYSTEM_USER" "$VW_ENV_FILE"
    chmod 640 "$VW_ENV_FILE"

    # Substitute the placeholder with the Argon2 hash. Use | as the sed
    # delimiter since the hash contains / characters. The hash may also
    # contain & which sed treats specially in the replacement — escape it.
    local safe_hash
    safe_hash=$(echo "$admin_token_hash" | sed 's/[&/\]/\\&/g')
    sed -i "s|ADMIN_TOKEN_PLACEHOLDER|${safe_hash}|" "$VW_ENV_FILE"

    print_success "Config written (permissions: root-only read)"

    # ── Step 6: Write docker-compose.yml ──────────────────────────────────────
    print_info "Step 6: Writing docker-compose.yml..."

    cat > "$VW_COMPOSE_FILE" << EOF
# Vaultwarden — managed by setup_vaultwarden.sh
# Start:   systemctl start vaultwarden
# Stop:    systemctl stop vaultwarden
# Logs:    journalctl -u vaultwarden -f
# Update:  change VW_IMAGE in setup_vaultwarden.sh, then:
#            sudo -u $VW_SYSTEM_USER podman compose -f $VW_COMPOSE_FILE pull
#            systemctl restart vaultwarden
#            sudo -u $VW_SYSTEM_USER podman image prune -f

services:
  vaultwarden:
    image: $VW_IMAGE
    container_name: vaultwarden
    env_file: $VW_ENV_FILE
    volumes:
      # Persistent data (SQLite DB, attachments, etc.) and TLS certs
      - $VW_DATA_DIR:/data:Z
    ports:
      # Bind only to the Tailscale interface — not reachable on the public IP
      - "$ts_ip:$port:$port"
    restart: unless-stopped
EOF

    chmod 640 "$VW_COMPOSE_FILE"
    chown root:"$VW_SYSTEM_USER" "$VW_COMPOSE_FILE"
    print_success "docker-compose.yml written"

    # ── Step 7: Pull image ────────────────────────────────────────────────────
    print_info "Step 7: Pulling Vaultwarden image ($VW_IMAGE)..."
    sudo -u "$VW_SYSTEM_USER" podman compose -f "$VW_COMPOSE_FILE" pull
    print_success "Image pulled"

    # ── Step 8: Create systemd service ────────────────────────────────────────
    print_info "Step 8: Creating systemd service..."

    cat > "$VW_SYSTEMD_SERVICE" << EOF
[Unit]
Description=Vaultwarden password manager (Podman + Tailscale)
Documentation=https://github.com/dani-garcia/vaultwarden
# Ensure Tailscale is up before starting — Vaultwarden binds to the
# Tailscale interface and will fail to start if it isn't available yet.
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Run as the unprivileged system user — rootless Podman means a container
# escape cannot yield root on the host.
User=$VW_SYSTEM_USER
Group=$VW_SYSTEM_USER
WorkingDirectory=$VW_DATA_DIR
ExecStart=/usr/bin/podman compose -f $VW_COMPOSE_FILE up -d --remove-orphans
ExecStop=/usr/bin/podman compose -f $VW_COMPOSE_FILE down
StandardOutput=journal
StandardError=journal
# Resource limits — defense-in-depth in case of container escape or runaway process.
MemoryMax=512M
TasksMax=512
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vaultwarden
    systemctl start vaultwarden
    print_success "Systemd service created, enabled, and started"

    # ── Step 9: Health check ──────────────────────────────────────────────────
    print_info "Waiting for Vaultwarden to be ready..."
    local healthy=false
    local retries=12  # 12 × 5s = 60s timeout
    for (( i=1; i<=retries; i++ )); do
        # Use --resolve to map the Tailscale hostname to its IP so curl can
        # verify the TLS certificate's SAN properly — avoids --insecure.
        if curl -sf --resolve "${hostname}:${port}:${ts_ip}" \
                "https://${hostname}:${port}/alive" &>/dev/null; then
            healthy=true
            print_success "Vaultwarden is responding on $hostname:$port"
            break
        fi
        print_info "  Not ready yet (attempt $i/$retries) — waiting 5s..."
        sleep 5
    done

    if [ "$healthy" = false ]; then
        print_warning "Vaultwarden didn't respond after 60s"
        print_warning "Check logs with: journalctl -u vaultwarden -n 50"
    fi

    # ── Done ──────────────────────────────────────────────────────────────────
    print_section "Vaultwarden setup complete"
    echo ""
    echo -e "  ${GREEN}https://$hostname${NC}"
    echo ""
    print_warning "Next steps:"
    echo -e "  ${YELLOW}1. Visit https://$hostname and create your account${NC}"
    echo -e "  ${YELLOW}2. Visit https://$hostname/admin to configure Vaultwarden${NC}"
    echo -e "     ${YELLOW}Admin token: sudo cat $token_reveal_file${NC}"
    echo -e "     ${YELLOW}Delete after use: sudo rm $token_reveal_file${NC}"
    echo -e "  ${YELLOW}3. Once your account is set up, lock down the instance:${NC}"
    echo -e "     ${YELLOW}sudo $0 harden${NC}"
    echo ""
    print_info "Useful commands:"
    print_info "  Logs:          journalctl -u vaultwarden -f"
    print_info "  Restart:       systemctl restart vaultwarden"
    print_info "  Config:        $VW_ENV_FILE"
    print_info "  Data:          $VW_DATA_DIR"
    print_info "  Cert refresh:  $CERT_REFRESH_SCRIPT"
    echo ""
    print_info "To update Vaultwarden in future:"
    print_info "  sudo -u $VW_SYSTEM_USER podman compose -f $VW_COMPOSE_FILE pull"
    print_info "  systemctl restart vaultwarden"
    print_info "  sudo -u $VW_SYSTEM_USER podman image prune -f   # clean up the old image"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# HELP
# ══════════════════════════════════════════════════════════════════════════════
cmd_help() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
}

# ══════════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
    harden)       cmd_harden ;;
    cert-refresh) cmd_cert_refresh "${2:-}" ;;
    --help|-h)    cmd_help ;;
    "")
        print_error "Usage: $0 <tailscale-hostname> [options]"
        print_error "       $0 harden"
        print_error "       $0 cert-refresh <tailscale-hostname>"
        exit 1
        ;;
    *)
        cmd_setup "$@"
        ;;
esac
