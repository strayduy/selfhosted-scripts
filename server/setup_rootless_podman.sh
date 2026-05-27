#!/usr/bin/env bash
# setup_rootless_podman.sh
# Sets up a rootless Podman user with AppArmor configuration on Ubuntu 24.04
# Usage: sudo ./setup_rootless_podman.sh [username]
# Default username: podman

set -euo pipefail
IFS=$'\n\t'

# Source shared helpers (info/success/warn/error, require_root, require_ubuntu, ...)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# ── Configuration ─────────────────────────────────────────────────────────────

PODMAN_USER="podman" # overridden by argument parsing in main()
SUBUID_COUNT=65536  # 65536 UIDs = a full "sub-namespace" range

# PODMAN_UID is set as a side-effect of setup_user() and used by
# setup_storage() and smoke_test(). Declare it here so set -u doesn't
# fire if something calls those functions out of order.
PODMAN_UID=""

# ── Preflight checks ──────────────────────────────────────────────────────────
#
# Run these before touching anything on the system. They catch hard blockers
# that would cause confusing failures deep in the setup process.

preflight_checks() {
    info "Running preflight checks..."

    # Check that unprivileged user namespaces are enabled.
    # DigitalOcean droplets (and other hardened images) sometimes ship with
    # kernel.unprivileged_userns_clone=0, which completely disables rootless
    # containers. Check both the Ubuntu-specific sysctl and the upstream one.
    local userns_clone
    userns_clone=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
    [[ "$userns_clone" -ne 0 ]] ||
        error "Unprivileged user namespaces are disabled (kernel.unprivileged_userns_clone=0). " \
            "Enable with: sysctl -w kernel.unprivileged_userns_clone=1"

    local max_userns
    max_userns=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "1")
    [[ "$max_userns" -ne 0 ]] ||
        error "user.max_user_namespaces=0 — user namespaces are disabled kernel-wide. " \
            "Enable with: sysctl -w user.max_user_namespaces=15000"

    success "Preflight checks passed."
}

# ── Step 1: Install dependencies ──────────────────────────────────────────────

install_dependencies() {
    info "Installing dependencies..."

    # Note: apt-get update failure is now fatal (no -qq suppression on errors).
    apt-get update || error "apt-get update failed. Check your mirror configuration."

    # crun is the default OCI runtime for Podman on Ubuntu 24.04. It must be
    # installed explicitly on minimal droplet images — omitting it causes Podman
    # to silently fall back to runc and leaves the crun AppArmor patch with
    # nothing to reload against.
    #
    # Both passt and slirp4netns are installed here regardless of Podman version.
    # We cannot safely call `podman --version` at this point because AppArmor has
    # not yet been configured — on Ubuntu 24.04 the podman AppArmor profile is
    # strict enough to deny loading libsubid.so.4, causing `podman` to abort with
    # a "Permission denied" shared-library error before printing any output.
    # The correct backend is selected and written to containers.conf in
    # setup_network_backend(), which runs after setup_apparmor().
    # Both packages are small and having both present is harmless.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends uidmap podman fuse-overlayfs crun passt slirp4netns

    # Verify that newuidmap/newgidmap are SUID root after install.
    # On minimal images or custom DigitalOcean snapshots, the uidmap package
    # may install without the SUID bit, silently breaking user namespace setup.
    for bin in /usr/bin/newuidmap /usr/bin/newgidmap; do
        [[ -u "$bin" ]] ||
            error "$bin is not SUID root. Rootless user namespace remapping will fail. " \
                "Fix with: chmod u+s $bin"
    done

    success "Dependencies installed."
}

# ── Step 2: Create user and group ─────────────────────────────────────────────

# Set to "true" if the user already existed before this script ran.
# setup_subids() uses this to decide whether to run `podman system migrate`
# to reconcile any stale UID mappings in Podman's storage database.
PODMAN_USER_PREEXISTED="false"

setup_user() {
    info "Setting up user '$PODMAN_USER'..."

    # Create group if it doesn't exist
    if ! getent group "$PODMAN_USER" &>/dev/null; then
        groupadd "$PODMAN_USER"
        success "Group '$PODMAN_USER' created."
    else
        warn "Group '$PODMAN_USER' already exists, skipping."
    fi

    # Create user if it doesn't exist
    if ! id "$PODMAN_USER" &>/dev/null; then
        useradd \
            --create-home \
            --shell /usr/sbin/nologin \
            --no-user-group \
            --gid "$PODMAN_USER" \
            --comment "Rootless Podman service account" \
            "$PODMAN_USER"
        success "User '$PODMAN_USER' created."

        # Restrict home directory to owner only.
        # Default useradd permissions (755) allow any local user to browse the
        # container image cache and config files. Service accounts should be 700.
        chmod 700 "/home/${PODMAN_USER}"
        success "Home directory permissions set to 700."
    else
        warn "User '$PODMAN_USER' already exists, skipping."
        PODMAN_USER_PREEXISTED="true"
    fi

    # Always assign PODMAN_UID unconditionally, regardless of whether
    # the user was just created or already existed. This variable is a required
    # side-effect consumed by setup_storage() and smoke_test(). Keeping it here
    # (after the if/else) ensures it's always set before those functions run.
    PODMAN_UID=$(id -u "$PODMAN_USER")
    info "User '$PODMAN_USER' has UID $PODMAN_UID."
}

# ── Step 3: Configure subordinate UID/GID ranges ──────────────────────────────
#
# Rootless containers need a bank of "fake" UIDs/GIDs the kernel will remap
# into the container's user namespace. Without these, the container can't
# create users or change ownership of files inside itself.
# /etc/subuid and /etc/subgid hold these ranges per user.

# Find the next free subuid/subgid start to avoid overlapping with
# ranges already allocated to other users. The system default of 100000 is
# commonly used by the first real user account, so hardcoding it risks silent
# namespace mapping conflicts.
find_free_subid_start() {
    local subid_file="$1" # /etc/subuid or /etc/subgid
    local candidate=100000

    if [[ ! -f "$subid_file" ]]; then
        echo "$candidate"
        return
    fi

    # Find the highest end-of-range across all existing entries, then start
    # one past it. Each line is: username:start:count
    local highest_end=0
    while IFS=: read -r _ start count; do
        # Guard against malformed or non-numeric entries (e.g. corrupted lines,
        # usernames containing colons). Under set -e, invalid arithmetic aborts
        # the whole script, so skip any line that doesn't look like two integers.
        [[ "$start" =~ ^[0-9]+$ ]] || continue
        [[ "$count" =~ ^[0-9]+$ ]] || continue
        local end=$((start + count))
        ((end > highest_end)) && highest_end=$end
    done <"$subid_file"

    if ((highest_end > candidate)); then
        candidate=$highest_end
    fi

    echo "$candidate"
}

setup_subids() {
    info "Configuring subordinate UID/GID ranges..."

    local subids_changed=false

    if grep -q "^${PODMAN_USER}:" /etc/subuid 2>/dev/null; then
        warn "subuid entry for '$PODMAN_USER' already exists, skipping."
    else
        local start
        start=$(find_free_subid_start /etc/subuid)
        local end=$((start + SUBUID_COUNT - 1))
        usermod --add-subuids "${start}-${end}" "$PODMAN_USER"
        success "subuid range ${start}-${end} assigned."
        subids_changed=true
    fi

    if grep -q "^${PODMAN_USER}:" /etc/subgid 2>/dev/null; then
        warn "subgid entry for '$PODMAN_USER' already exists, skipping."
    else
        local start
        start=$(find_free_subid_start /etc/subgid)
        local end=$((start + SUBUID_COUNT - 1))
        usermod --add-subgids "${start}-${end}" "$PODMAN_USER"
        success "subgid range ${start}-${end} assigned."
        subids_changed=true
    fi

    # For a pre-existing user whose subid ranges were just written (or who had
    # ranges changed), Podman's storage database may hold stale UID mappings
    # from a prior invocation. `podman system migrate` rewrites the database
    # to match the current subuid/subgid ranges. Skipping this step causes
    # confusing "cannot change ownership" errors on the next container run.
    if [[ "$PODMAN_USER_PREEXISTED" == "true" ]] && [[ "$subids_changed" == "true" ]]; then
        info "Pre-existing user with new subid ranges — running 'podman system migrate'..."
        run_as_user "$PODMAN_USER" podman system migrate &&
            success "podman system migrate completed." ||
            warn "podman system migrate failed or was unnecessary — this is non-fatal if containers have not been used yet."
    fi
}

# ── Step 4: Systemd cgroup delegation ─────────────────────────────────────────
#
# By default, systemd only allows root sessions to manage cgroups. Rootless
# Podman uses cgroups to enforce resource limits and track container processes.
# The 'Delegate=yes' directive tells systemd to hand ownership of the user's
# slice of the cgroup tree to the user's session manager, so Podman can manage
# its own cgroups without root.

setup_cgroup_delegation() {
    info "Configuring cgroup delegation..."

    local CONF_DIR="/etc/systemd/system/user@.service.d"
    local CONF_FILE="${CONF_DIR}/delegate.conf"

    mkdir -p "$CONF_DIR"

    if [[ -f "$CONF_FILE" ]] && grep -q "Delegate=yes" "$CONF_FILE"; then
        warn "Cgroup delegation already configured, skipping."
    else
        cat >"$CONF_FILE" <<'EOF'
[Service]
Delegate=yes
EOF
        success "Cgroup delegation configured."
        systemctl daemon-reload
        success "systemd daemon reloaded."
    fi
}

# ── Step 5: Enable linger ──────────────────────────────────────────────────────
#
# Normally, a user's systemd session (and all its processes) is torn down the
# moment the user logs out. 'Linger' tells systemd to keep the user's session
# alive even when they have no active login — essential for a service account
# like this one that needs to keep containers running permanently.

setup_linger() {
    info "Enabling linger for '$PODMAN_USER'..."

    if loginctl show-user "$PODMAN_USER" 2>/dev/null | grep -q "Linger=yes"; then
        warn "Linger already enabled for '$PODMAN_USER', skipping."
    else
        loginctl enable-linger "$PODMAN_USER"
        success "Linger enabled for '$PODMAN_USER'."
    fi
}

# ── Step 6: Allow binding to privileged ports ─────────────────────────────────
#
# Linux restricts binding to ports below 1024 to root by default. Rootless
# Podman inherits this restriction, so containers that need to bind to port 443
# (or any other privileged port) will fail with EACCES at startup.
#
# net.ipv4.ip_unprivileged_port_start=443 grants access to port 443 and above
# to unprivileged users, while keeping ports 1-442 root-only. This is more
# conservative than setting it to 0 (which would open all privileged ports).
#
# The sysctl is written to /etc/sysctl.d/ for persistence across reboots and
# applied immediately with `sysctl --system`.

setup_privileged_ports() {
    local SYSCTL_FILE="/etc/sysctl.d/99-unprivileged-ports.conf"
    local SYSCTL_KEY="net.ipv4.ip_unprivileged_port_start"
    local SYSCTL_VALUE="443"

    info "Configuring unprivileged port binding (port ${SYSCTL_VALUE}+)..."

    if [[ -f "$SYSCTL_FILE" ]] && grep -q "^${SYSCTL_KEY}=" "$SYSCTL_FILE"; then
        local current_value
        current_value=$(grep "^${SYSCTL_KEY}=" "$SYSCTL_FILE" | cut -d= -f2 | tr -d ' ')
        if [[ "$current_value" -le "$SYSCTL_VALUE" ]]; then
            warn "${SYSCTL_KEY}=${current_value} already configured in '$SYSCTL_FILE', skipping."
            return
        else
            warn "${SYSCTL_KEY}=${current_value} found but is more restrictive than ${SYSCTL_VALUE} — overwriting."
            sed -i "s|^${SYSCTL_KEY}=.*|${SYSCTL_KEY}=${SYSCTL_VALUE}|" "$SYSCTL_FILE"
        fi
    else
        echo "${SYSCTL_KEY}=${SYSCTL_VALUE}" >>"$SYSCTL_FILE"
    fi

    sysctl --system >/dev/null
    success "Unprivileged port start set to ${SYSCTL_VALUE} (persisted to ${SYSCTL_FILE})."
}

# ── Step 7: Configure Podman storage ──────────────────────────────────────────

setup_storage() {
    info "Configuring Podman storage for '$PODMAN_USER'..."

    [[ -n "$PODMAN_UID" ]] ||
        error "PODMAN_UID is not set — setup_user() must be called before setup_storage()."

    local CONFIG_DIR="/home/${PODMAN_USER}/.config/containers"
    local CONFIG_FILE="${CONFIG_DIR}/storage.conf"
    local GRAPH_ROOT="/home/${PODMAN_USER}/.local/share/containers/storage"

    sudo -u "$PODMAN_USER" mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Storage config already exists at '$CONFIG_FILE', skipping."
        return
    fi

    # Detect whether the running kernel supports native rootless
    # overlay mounts (kernels 5.11+, which Ubuntu 24.04 ships). Native overlay
    # is faster than fuse-overlayfs. If supported, omit mount_program and let
    # Podman use it automatically; only fall back to fuse-overlayfs on older
    # kernels or if native overlay isn't available.
    local KERNEL_VERSION
    KERNEL_VERSION=$(uname -r)
    local KERNEL_MAJOR KERNEL_MINOR
    KERNEL_MAJOR=${KERNEL_VERSION%%.*}
    KERNEL_MINOR=${KERNEL_VERSION#*.}; KERNEL_MINOR=${KERNEL_MINOR%%.*}

    local USE_FUSE_OVERLAYFS=true
    if ((KERNEL_MAJOR > 5 || (KERNEL_MAJOR == 5 && KERNEL_MINOR >= 11))); then
        # Also verify that the kernel was actually compiled with overlay support
        if grep -qw overlay /proc/filesystems 2>/dev/null; then
            USE_FUSE_OVERLAYFS=false
            info "Kernel ${KERNEL_VERSION} supports native overlay — skipping fuse-overlayfs."
        fi
    fi

    # Do not set runroot to /run/user/${PODMAN_UID}. That path is a
    # tmpfs mount created by systemd-logind and may not exist at config-write
    # time (linger may not have fully activated yet). Omit runroot entirely and
    # let Podman use its default, which it resolves correctly at runtime once
    # the XDG_RUNTIME_DIR session is live.
    if [[ "$USE_FUSE_OVERLAYFS" == "true" ]]; then
        sudo -u "$PODMAN_USER" tee "$CONFIG_FILE" >/dev/null <<EOF
[storage]
driver = "overlay"
graphroot = "${GRAPH_ROOT}"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
        success "Storage config written (using fuse-overlayfs) to '$CONFIG_FILE'."
    else
        sudo -u "$PODMAN_USER" tee "$CONFIG_FILE" >/dev/null <<EOF
[storage]
driver = "overlay"
graphroot = "${GRAPH_ROOT}"
EOF
        success "Storage config written (using native kernel overlay) to '$CONFIG_FILE'."
    fi
}

# ── Step 8: Configure container registries ────────────────────────────────────
#
# Podman on Ubuntu ships with no unqualified-search registries configured.
# Running `podman pull nginx` (without a full registry prefix) fails with a
# "short name" error. Writing a registries.conf with docker.io as the default
# search registry restores the behaviour most users expect and matches what
# Docker provides out of the box.

setup_registries() {
    info "Configuring container registries for '$PODMAN_USER'..."

    local CONFIG_DIR="/home/${PODMAN_USER}/.config/containers"
    local REGISTRIES_FILE="${CONFIG_DIR}/registries.conf"

    # CONFIG_DIR is created by setup_storage(), but guard here in case
    # setup_registries() is ever called independently.
    sudo -u "$PODMAN_USER" mkdir -p "$CONFIG_DIR"

    if [[ -f "$REGISTRIES_FILE" ]]; then
        warn "Registries config already exists at '$REGISTRIES_FILE', skipping."
        return
    fi

    sudo -u "$PODMAN_USER" tee "$REGISTRIES_FILE" >/dev/null <<'EOF'
# registries.conf — unqualified-name search registries for rootless Podman.
# Without this file, `podman pull nginx` (no registry prefix) fails with a
# "short name" error. Add or reorder registries to match your pull policy.
unqualified-search-registries = ["docker.io"]
EOF
    success "Registries config written to '$REGISTRIES_FILE'."
}

# ── Step 9: Configure AppArmor ────────────────────────────────────────────────
#
# Ubuntu 24.04 ships AppArmor profiles for podman, crun, and slirp4netns that
# are strict enough to break rootless operation. We want to run each binary
# with flags=(unconfined), which keeps AppArmor tracking the process but stops
# it from actually blocking any operations.
#
# The naive fix — sed-patching the files in /etc/apparmor.d/ — is silently
# undone whenever unattended-upgrades reinstalls the package: the package
# postinst overwrites the profile and calls apparmor_parser to reload it,
# restoring the stock (restricting) configuration.
#
# Robust fix (this implementation):
#   1. Write a complete flags=(unconfined) profile to /etc/apparmor.d/local/.
#      Files in that directory are never owned by any package, so they survive
#      upgrades intact.
#   2. Disable the package-managed profile via a symlink in
#      /etc/apparmor.d/disable/ so AppArmor's init does not load the stock
#      version at boot (which would conflict with ours).
#   3. Install a systemd one-shot service (rootless-podman-apparmor.service)
#      that reloads the local overrides on every boot, after apparmor.service
#      has finished — ensuring our flags=(unconfined) profiles win even when a
#      package postinst reloads the stock profile mid-session.
#
# An alternative hardening approach would be to craft a real permissive
# profile, but flags=(unconfined) is the pragmatic default used upstream for
# rootless Podman on Ubuntu.

# Write a flags=(unconfined) profile for <profile_name> to
# /etc/apparmor.d/local/ and suppress the package-managed version via
# /etc/apparmor.d/disable/.
#
# Usage: setup_apparmor_override <profile-name> <binary-path>
#   e.g.  setup_apparmor_override "podman" "/usr/bin/podman"
setup_apparmor_override() {
    local profile_name="$1"
    local binary_path="$2"
    local upstream_profile="/etc/apparmor.d/${profile_name}"
    local override_file="/etc/apparmor.d/local/${profile_name}"
    local disable_dir="/etc/apparmor.d/disable"
    local disable_symlink="${disable_dir}/${profile_name}"

    command -v apparmor_parser &>/dev/null ||
        error "apparmor_parser not found. Is AppArmor installed? (apt-get install apparmor)"

    mkdir -p /etc/apparmor.d/local "${disable_dir}"

    # Write the override profile unless it already exists and is already
    # unconfined (idempotent re-runs should be a no-op).
    if [[ -f "$override_file" ]] && grep -q "flags=(unconfined)" "$override_file"; then
        warn "AppArmor override already present at '${override_file}', skipping write."
    else
        info "Writing AppArmor override: ${override_file}"
        cat >"$override_file" <<EOF
# AppArmor unconfined override for rootless Podman.
# Managed by setup_rootless_podman.sh — do not edit manually.
#
# This file lives in /etc/apparmor.d/local/ and is not owned by any package,
# so it is never silently overwritten by unattended-upgrades.  The stock
# package profile at ${upstream_profile} is suppressed via a disable symlink
# at ${disable_symlink} so the two profiles do not conflict.
#
# The rootless-podman-apparmor.service systemd unit re-applies this override
# on every boot, ensuring it takes precedence even after a package postinst
# reloads the stock AppArmor profile.
profile ${profile_name} ${binary_path} flags=(unconfined) {
  # Intentionally empty: flags=(unconfined) grants all permissions without
  # enforcing any AppArmor restrictions on this binary.  This is the approach
  # recommended upstream for rootless Podman on Ubuntu.
}
EOF
        success "AppArmor override written to '${override_file}'."
    fi

    # Suppress the package-managed profile at boot by symlinking it into
    # /etc/apparmor.d/disable/.  AppArmor's init scripts skip any profile
    # that has a corresponding symlink in that directory.
    if [[ -f "$upstream_profile" ]]; then
        if [[ ! -e "$disable_symlink" ]]; then
            ln -sf "$upstream_profile" "$disable_symlink"
            info "Package profile '${upstream_profile}' disabled at boot via '${disable_symlink}'."
        else
            info "Package profile '${upstream_profile}' already disabled."
        fi
    else
        warn "Package profile '${upstream_profile}' not found — nothing to disable."
    fi

    # Load (or replace) our override in the running kernel.  --replace works
    # whether the binary currently has no profile, the package's stock profile,
    # or a previous version of our override — making this step idempotent.
    apparmor_parser --replace "$override_file"
    success "AppArmor '${profile_name}' override loaded into running kernel."
}

# Install a systemd one-shot service that reloads the /etc/apparmor.d/local/
# override profiles on every boot, *after* apparmor.service has loaded the
# package-managed profiles.  This ensures our flags=(unconfined) versions
# survive a podman/crun/slirp4netns upgrade whose postinst reloads the stock
# (restricting) AppArmor profile mid-session.
create_apparmor_reload_service() {
    local service_file="/etc/systemd/system/rootless-podman-apparmor.service"

    info "Installing rootless-podman-apparmor.service..."

    cat >"$service_file" <<'EOF'
[Unit]
Description=Reload rootless-Podman AppArmor unconfined overrides
Documentation=https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
# Run after AppArmor so our overrides replace the stock profiles loaded
# by apparmor.service.  This also covers reboots following a package upgrade
# whose postinst restored the stock (restricting) profile.
After=apparmor.service
Wants=apparmor.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Reload each unconfined override.  The leading '-' makes individual failures
# non-fatal so a missing profile (e.g. slirp4netns not installed) does not
# block the other overrides from loading.
ExecStart=-/usr/sbin/apparmor_parser --replace /etc/apparmor.d/local/podman
ExecStart=-/usr/sbin/apparmor_parser --replace /etc/apparmor.d/local/crun
ExecStart=-/usr/sbin/apparmor_parser --replace /etc/apparmor.d/local/slirp4netns

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rootless-podman-apparmor.service
    success "rootless-podman-apparmor.service installed and enabled."
}

setup_apparmor() {
    info "Configuring AppArmor profiles for rootless Podman..."

    setup_apparmor_override "podman"      "/usr/bin/podman"
    setup_apparmor_override "slirp4netns" "/usr/bin/slirp4netns"
    setup_apparmor_override "crun"        "/usr/bin/crun"

    create_apparmor_reload_service

    success "AppArmor configuration complete."
}

# ── Step 10: Configure network backend ────────────────────────────────────────
#
# `network_backend` in containers.conf controls Podman's CNI/Netavark stack
# and is a distinct concept from the rootless networking *helper* process
# (slirp4netns / pasta) that provides network connectivity to rootless
# containers.
#
# Valid network_backend values are "netavark" and "cni" — "slirp4netns" is
# NOT a valid value and will cause Podman to abort on startup. The rootless
# helper is selected automatically by Podman based on which binary is present
# on PATH; it does not need to be set explicitly in containers.conf.
#
# The one case where we do write network_backend is Podman v5+ with pasta:
# v5 changed the default rootless helper from slirp4netns to pasta and may
# emit deprecation warnings if slirp4netns is also present. Writing
# network_backend = "pasta" suppresses this. For v4 we write nothing and let
# Podman auto-detect slirp4netns from PATH.

setup_network_backend() {
    info "Configuring network backend for '$PODMAN_USER'..."

    local CONFIG_DIR="/home/${PODMAN_USER}/.config/containers"
    local CONTAINERS_CONF="${CONFIG_DIR}/containers.conf"

    sudo -u "$PODMAN_USER" mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONTAINERS_CONF" ]] && grep -q "network_backend" "$CONTAINERS_CONF"; then
        warn "network_backend already set in '$CONTAINERS_CONF', skipping."
        return
    fi

    # AppArmor is now patched, so `podman --version` is safe to call.
    local podman_major
    podman_major=$(podman --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)

    if [[ -n "$podman_major" ]] && ((podman_major >= 5)); then
        # v5+: write network_backend = "pasta" to suppress slirp4netns deprecation
        # warnings when both helpers are installed.
        info "Podman v${podman_major}+ detected — pinning network_backend to pasta."
        sudo -u "$PODMAN_USER" tee -a "$CONTAINERS_CONF" >/dev/null <<'EOF'

[network]
# Podman v5+ uses pasta (passt) as the rootless networking helper.
# Pinned here to suppress deprecation warnings when slirp4netns is also present.
network_backend = "pasta"
EOF
        success "Network backend pinned to 'pasta' in '$CONTAINERS_CONF'."
    else
        # v4 and below: slirp4netns is auto-detected from PATH — no containers.conf
        # entry needed. "slirp4netns" is not a valid network_backend value and will
        # cause Podman to abort if written here.
        info "Podman v${podman_major:-unknown} detected — slirp4netns will be auto-detected from PATH, no containers.conf entry needed."
    fi
}

# ── Step 11: Smoke test ───────────────────────────────────────────────────────

smoke_test() {
    info "Running smoke test..."

    [[ -n "$PODMAN_UID" ]] ||
        error "PODMAN_UID is not set — setup_user() must be called before smoke_test()."

    # XDG_RUNTIME_DIR (/run/user/<uid>) is a tmpfs created by systemd-logind
    # when linger activates. The loginctl enable-linger call earlier is
    # asynchronous — the directory may not exist yet by the time we reach here.
    # Poll for up to 10 seconds before giving up.
    local runtime_dir="/run/user/${PODMAN_UID}"
    local waited=0
    while [[ ! -d "$runtime_dir" ]] && ((waited < 10)); do
        info "Waiting for $runtime_dir to be created by systemd-logind... (${waited}s)"
        sleep 1
        ((waited++)) || true
    done

    if [[ ! -d "$runtime_dir" ]]; then
        warn "$runtime_dir still does not exist after ${waited}s."
        warn "Linger may not have fully activated. The smoke test may fail."
        warn "If so, re-run after a few seconds or trigger linger manually:"
        warn "  loginctl enable-linger $PODMAN_USER"
    fi

    # XDG_RUNTIME_DIR is normally set by pam_systemd on login; since we're
    # running as root with sudo -u, we set it manually so Podman can find its
    # socket and runtime files.
    local result
    result=$(
        run_as_user "$PODMAN_USER" \
            podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null ||
            true
    )

    if [[ "$result" == "true" ]]; then
        success "Smoke test passed — Podman is running rootless as '$PODMAN_USER'."
    else
        # Smoke test failure now prints a prominent warning and exits
        # non-zero so callers (CI, provisioning scripts) can detect a broken setup.
        # The original script used warn() and exited 0, silently hiding failures.
        warn "========================================================"
        warn "Smoke test FAILED. Podman does not appear to be working."
        warn "========================================================"
        warn "Debug manually with:"
        warn "  sudo -u $PODMAN_USER XDG_RUNTIME_DIR=/run/user/${PODMAN_UID} podman info"
        warn ""
        warn "Common causes on DigitalOcean droplets:"
        warn "  - kernel.unprivileged_userns_clone=0  (check: sysctl kernel.unprivileged_userns_clone)"
        warn "  - newuidmap/newgidmap not SUID         (check: ls -l /usr/bin/new{uid,gid}map)"
        warn "  - AppArmor override not loaded          (check: grep 'flags=' /etc/apparmor.d/local/podman)"
        warn "  - XDG_RUNTIME_DIR not yet created      (may resolve after first login/linger activates)"
        exit 1
    fi
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: sudo ./setup_rootless_podman.sh [OPTIONS] [USERNAME]

Sets up a rootless Podman user with AppArmor configuration on Ubuntu 24.04.

Arguments:
  USERNAME        System user to create and configure for rootless Podman.
                  Defaults to 'podman' if omitted.

Options:
  -h, --help      Show this help message and exit.

What this script does:
   1. Installs Podman and dependencies (uidmap, crun, passt, slirp4netns, ...).
   2. Creates a dedicated system user (nologin shell, home dir mode 700).
   3. Assigns subordinate UID/GID ranges (/etc/subuid, /etc/subgid).
   4. Configures systemd cgroup delegation (user@.service.d/delegate.conf).
   5. Enables systemd linger so containers survive logout.
   6. Lowers net.ipv4.ip_unprivileged_port_start to 443.
   7. Writes ~/.config/containers/storage.conf (overlay driver).
   8. Writes ~/.config/containers/registries.conf (docker.io search).
   9. Writes flags=(unconfined) AppArmor overrides to /etc/apparmor.d/local/
         and installs rootless-podman-apparmor.service to reload them on boot.
  10. Configures the network backend in containers.conf (pasta on Podman v5+).
  11. Runs a smoke test to verify rootless operation.

Prerequisites:
  - Must be run as root (or via sudo).
  - Ubuntu 24.04 LTS.

Examples:
  sudo ./setup_rootless_podman.sh
  sudo ./setup_rootless_podman.sh vaultwarden
  sudo ./setup_rootless_podman.sh --help
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local _username=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                error "Unknown option: $1"
                ;;
            *)
                if [[ -n "$_username" ]]; then
                    usage >&2
                    error "Unexpected argument: $1"
                fi
                _username="$1"
                ;;
        esac
        shift
    done

    PODMAN_USER="${_username:-podman}"

    # Reject usernames that start with '-'. Such names are syntactically valid
    # to useradd but are almost certainly a mistyped flag (e.g. "--help") and
    # would cause confusing failures in downstream commands that treat the
    # leading dash as an option prefix.
    [[ "$PODMAN_USER" != -* ]] ||
        error "Invalid username '$PODMAN_USER': usernames must not start with '-'."

    require_root
    require_ubuntu "24.04"
    preflight_checks

    info "=== Rootless Podman Setup ==="
    info "Target user: $PODMAN_USER"
    echo

    install_dependencies
    setup_user   # Sets PODMAN_UID / PODMAN_USER_PREEXISTED as side-effects
    setup_subids # Uses PODMAN_USER_PREEXISTED; may run podman system migrate
    setup_cgroup_delegation
    setup_linger
    setup_privileged_ports # Allows rootless containers to bind to port 443+
    setup_storage          # Depends on PODMAN_UID being set by setup_user()
    setup_registries
    setup_apparmor
    setup_network_backend # Depends on AppArmor being patched before calling podman --version
    smoke_test            # Depends on PODMAN_UID being set by setup_user()

    echo
    success "=== Setup complete! ==="
    info "Switch to the user's full session (recommended — sets up PAM/systemd correctly):"
    info "  machinectl shell ${PODMAN_USER}@"
    info ""
    info "Or run a one-off command as '$PODMAN_USER' without a full login session:"
    info "  sudo -u $PODMAN_USER XDG_RUNTIME_DIR=/run/user/${PODMAN_UID} podman <command>"
}

main "$@"
