#!/usr/bin/env bash
#
# run-todo.sh — Work through AUDIT_TODO.md one item at a time using pi --print.
#
# Usage:
#   ./run-todo.sh              # list unchecked items and pick one interactively
#   ./run-todo.sh <number>     # run item N directly (1-based index of unchecked items)
#   ./run-todo.sh --list       # just list unchecked items and exit
#
# Prerequisites:
#   - pi must be on PATH and authenticated
#   - run from the repo root (where AUDIT_TODO.md lives)
#
# What this script does:
#   1. Parses unchecked [ ] items from AUDIT_TODO.md
#   2. Prompts you to pick one (or accepts a number argument)
#   3. Runs pi --print with that item as the task
#   4. After pi finishes, shows git diff and asks whether to mark the item done
#   5. Optionally commits with a generated message

set -euo pipefail
IFS=$'\n\t'

# ── Config ──────────────────────────────────────────────────────────────────
TODO_FILE="AUDIT_TODO.md"
PI_MODEL="anthropic/claude-sonnet-4-6"
PI_THINKING="medium"

# ── Colour helpers ───────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[1;33m'
    _C_BLUE=$'\033[0;34m'
    _C_BOLD=$'\033[1m'
    _C_NC=$'\033[0m'
else
    _C_RED="" _C_GREEN="" _C_YELLOW="" _C_BLUE="" _C_BOLD="" _C_NC=""
fi

info()    { echo "${_C_BLUE}[INFO]${_C_NC}  $*"; }
success() { echo "${_C_GREEN}[OK]${_C_NC}    $*"; }
warn()    { echo "${_C_YELLOW}[WARN]${_C_NC}  $*" >&2; }
error()   { echo "${_C_RED}[ERROR]${_C_NC} $*" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Extract all unchecked items from the TODO file.
# An "item" is one logical bullet: it may span multiple continuation lines
# (lines that start with whitespace and don't start a new bullet).
# Output: one item per line, with internal newlines replaced by ↵ for display,
# plus a NUL-terminated raw form written to a temp file for the prompt.
ITEMS_FILE=""   # temp file holding raw items (NUL-separated)

parse_items() {
    ITEMS_FILE="$(mktemp)"
    # Use awk to collect multi-line bullets that start with "- [ ]"
    awk '
    /^- \[ \]/ {
        if (item != "") printf "%s\0", item
        item = $0
        next
    }
    /^- \[/ {
        # a checked item — flush current and reset
        if (item != "") printf "%s\0", item
        item = ""
        next
    }
    /^[ \t]+/ {
        # continuation of current item (indent-continuation)
        if (item != "") item = item " " $0
        next
    }
    /^##/ || /^---/ || /^$/ {
        # section boundary — flush current
        if (item != "") printf "%s\0", item
        item = ""
        next
    }
    END {
        if (item != "") printf "%s\0", item
    }
    ' "$TODO_FILE" > "$ITEMS_FILE"
}

# Read items into a bash array (one element per item).
declare -a ITEMS=()

load_items() {
    parse_items
    local item
    while IFS= read -r -d '' item; do
        # Collapse whitespace runs (multi-line → single readable string)
        item="$(echo "$item" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//')"
        ITEMS+=("$item")
    done < "$ITEMS_FILE"
    rm -f "$ITEMS_FILE"
}

list_items() {
    if [[ ${#ITEMS[@]} -eq 0 ]]; then
        success "No unchecked items remain in $TODO_FILE — all done!"
        exit 0
    fi
    echo
    echo "${_C_BOLD}Unchecked items in $TODO_FILE:${_C_NC}"
    echo
    local i=1
    for item in "${ITEMS[@]}"; do
        # Show first ~120 chars for readability
        local display="${item:0:120}"
        [[ ${#item} -gt 120 ]] && display+="…"
        printf "  %s%2d)%s %s\n" "$_C_YELLOW" "$i" "$_C_NC" "$display"
        (( i++ ))
    done
    echo
}

# CHOSEN_N is set by pick_item() instead of echoing, so pick_item must NOT be
# called inside $() — command substitution would capture list_items' stdout and
# feed the entire printed list into arithmetic expansion downstream.
CHOSEN_N=""

pick_item() {
    local n="$1"
    local total="${#ITEMS[@]}"
    if [[ -z "$n" ]]; then
        list_items
        read -r -p "Enter item number (1-${total}): " n
    fi
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= total )) \
        || error "Invalid item number: $n (must be 1-${total})"
    CHOSEN_N="$n"
}

# Mark the Nth unchecked item as checked in AUDIT_TODO.md.
# We do this by finding the Nth occurrence of "- [ ]" in the file.
mark_done() {
    local n="$1"
    local count=0
    local tmpfile
    tmpfile="$(mktemp)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ \[\ \] ]]; then
            (( ++count ))  # pre-increment: avoids (( 0 )) → exit 1 under set -e
            if [[ "$count" -eq "$n" ]]; then
                echo "${line/- \[ \]/- [x]}"
                continue
            fi
        fi
        echo "$line"
    done < "$TODO_FILE" > "$tmpfile"
    mv "$tmpfile" "$TODO_FILE"
    success "Marked item $n as done in $TODO_FILE"
}

# ── Main ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage:
  ./run-todo.sh              list unchecked items, pick one interactively
  ./run-todo.sh <number>     run item N (1-based) directly
  ./run-todo.sh --list       list unchecked items and exit
  ./run-todo.sh --help       show this help
EOF
}

main() {
    [[ -f "$TODO_FILE" ]] || error "$TODO_FILE not found. Run from the repo root."
    command -v pi &>/dev/null || error "'pi' not found on PATH."
    command -v git &>/dev/null || error "'git' not found on PATH."

    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --list)
            load_items
            list_items
            exit 0
            ;;
    esac

    load_items

    if [[ ${#ITEMS[@]} -eq 0 ]]; then
        success "No unchecked items remain — all done!"
        exit 0
    fi

    # Pick item
    # Call directly — NOT inside $(); see CHOSEN_N comment above.
    pick_item "${1:-}"
    local chosen_n="$CHOSEN_N"
    local chosen_item="${ITEMS[$(( chosen_n - 1 ))]}"

    echo
    echo "${_C_BOLD}Selected item $chosen_n:${_C_NC}"
    echo "  $chosen_item"
    echo

    read -r -p "Run pi on this item? [Y/n] " confirm
    [[ "${confirm,,}" =~ ^(y|yes|)$ ]] || { info "Aborted."; exit 0; }

    # ── Build the prompt ──────────────────────────────────────────────────────
    # We pass the full TODO file as context (@AUDIT_TODO.md) so pi can see
    # the surrounding notes, then give a precise single-item instruction.
    local prompt
    prompt="$(cat <<EOF
You are working in the selfhosted-scripts repository. I need you to implement **one specific fix** from AUDIT_TODO.md and nothing else.

The item to implement is:

  $chosen_item

Rules:
- Implement only this single item. Do not touch anything else.
- Follow the AGENTS.md conventions (strict mode, 4-space indent, \`[[ ]]\` tests, quoting, etc.).
- Do NOT modify AUDIT_TODO.md — I will update the checklist separately.
- After making changes, run \`bash -n <file>\` on every script you touched to verify syntax.
- If shellcheck is available, run it on changed files too.
- Do NOT create a git commit — the calling script will handle the commit.
- Summarise what you changed and why at the end.
EOF
)"

    # ── Run pi ───────────────────────────────────────────────────────────────
    info "Running: pi --print --no-session --model $PI_MODEL --thinking $PI_THINKING"
    echo

    # @AUDIT_TODO.md gives pi the full file as context before the prompt text
    pi --print \
       --no-session \
       --model "$PI_MODEL" \
       --thinking "$PI_THINKING" \
       "@${TODO_FILE}" \
       "$prompt"

    local pi_exit=$?

    echo
    if [[ $pi_exit -ne 0 ]]; then
        warn "pi exited with status $pi_exit — review output above before proceeding."
    fi

    # ── Review ───────────────────────────────────────────────────────────────
    echo "${_C_BOLD}── Git diff ──────────────────────────────────────────────────────────${_C_NC}"
    git diff || true
    echo "${_C_BOLD}──────────────────────────────────────────────────────────────────────${_C_NC}"
    echo

    read -r -p "Mark item $chosen_n as done in $TODO_FILE? [Y/n] " mark_confirm
    if [[ "${mark_confirm,,}" =~ ^(y|yes|)$ ]]; then
        mark_done "$chosen_n"
    fi

    read -r -p "Create a git commit for these changes? [Y/n] " commit_confirm
    if [[ "${commit_confirm,,}" =~ ^(y|yes|)$ ]]; then
        # Derive a short subject from the item text
        local short
        short="$(echo "$chosen_item" | sed 's/^- \[ \] \*\*\[.*\]\*\* //' | cut -c1-72)"
        git add -A
        git commit -m "${short}

Co-authored-by: Claude <noreply@anthropic.com>"
        success "Committed."
    fi

    echo
    success "Done with item $chosen_n. Run the script again for the next item."
}

main "$@"
