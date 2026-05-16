# lib/common.sh
#
# Shared helpers for the scripts in this repo. Source from a script with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=../lib/common.sh
#   . "$SCRIPT_DIR/../lib/common.sh"
#
# This file is meant to be sourced, not executed. It deliberately does NOT
# call `set -euo pipefail` — that's the caller's responsibility, so this
# file can be sourced from scripts with different strictness preferences
# (e.g. test harnesses) without surprising them.

# ── Colours ───────────────────────────────────────────────────────────────────
#
# Gate colours on stdout being a TTY and NO_COLOR not being set, so output
# stays clean in log files, CI, and `journalctl`. See https://no-color.org.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[1;33m'
    _C_BLUE=$'\033[0;34m'
    _C_CYAN=$'\033[0;36m'
    _C_NC=$'\033[0m'
else
    _C_RED=""
    _C_GREEN=""
    _C_YELLOW=""
    _C_BLUE=""
    _C_CYAN=""
    _C_NC=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────
#
# Four severity levels. info/success go to stdout; warn/error go to stderr
# so they can be filtered separately. error() exits the script — callers
# that want to handle a failure themselves should test explicitly instead.

info()    { echo "${_C_BLUE}[INFO]${_C_NC}    $*"; }
success() { echo "${_C_GREEN}[OK]${_C_NC}      $*"; }
warn()    { echo "${_C_YELLOW}[WARN]${_C_NC}   $*" >&2; }
error()   { echo "${_C_RED}[ERROR]${_C_NC} $*" >&2; exit 1; }

# Section banner — used to delimit major phases of a script.
section() { echo -e "\n${_C_CYAN}━━━  $*  ━━━${_C_NC}"; }

# ── Preflight ─────────────────────────────────────────────────────────────────

# Abort unless running as root (EUID 0).
require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)."
}

# Abort unless /etc/os-release reports the given Ubuntu VERSION_ID.
# Usage: require_ubuntu 24.04
require_ubuntu() {
    local want="$1"
    if ! grep -q "VERSION_ID=\"${want}\"" /etc/os-release 2>/dev/null; then
        error "This script requires Ubuntu ${want}. Detected: $(
            grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null \
                | tr '\n' ' ' || echo 'unknown OS'
        )"
    fi
}
