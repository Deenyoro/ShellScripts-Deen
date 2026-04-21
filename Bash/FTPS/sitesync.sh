#!/usr/bin/env bash
# sitesync.sh — mirror an FTPS site into a local Git repo and push to origin.
#
# Flow:
#   1. Load config from sitesync.env (same directory as this script).
#   2. Ensure SSH key exists and is loaded in a script-scoped ssh-agent.
#   3. Ensure the Git working copy exists and is on the correct branch.
#   4. Mirror FTPS → a staging directory, then rsync into the working copy
#      (this keeps .git safe from lftp's --delete).
#   5. Commit any changes and push (never force-push by default).

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/sitesync.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Environment file not found: ${ENV_FILE}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

REQUIRED_VARS=(
    FTPS_SERVER FTPS_USER FTPS_PASS FTPS_REMOTE_DIR
    LOCAL_REPO SSH_KEY_PATH
    GIT_REMOTE_URL GIT_USER_NAME GIT_USER_EMAIL BRANCH
)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required env var: ${var}" >&2
        exit 1
    fi
done

# Optional tuning (with defaults)
SSH_KEY_EMAIL="${SSH_KEY_EMAIL:-${GIT_USER_EMAIL}}"
FTPS_PARALLEL="${FTPS_PARALLEL:-2}"
ALLOW_FORCE_PUSH="${ALLOW_FORCE_PUSH:-0}"   # set to 1 to permit --force fallback

SSH_AUTH_SOCK_FILE=""
SSH_AGENT_PID_FILE=""

cleanup() {
    # Kill the ssh-agent we started, if any.
    if [[ -n "${SSH_AGENT_PID:-}" ]] && kill -0 "${SSH_AGENT_PID}" 2>/dev/null; then
        kill "${SSH_AGENT_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# SSH key + agent
# ---------------------------------------------------------------------------
ensure_ssh_key() {
    if [[ ! -f "${SSH_KEY_PATH}" ]]; then
        log "SSH key not found at ${SSH_KEY_PATH}. Generating a new ed25519 key..."
        mkdir -p "$(dirname -- "${SSH_KEY_PATH}")"
        chmod 700 "$(dirname -- "${SSH_KEY_PATH}")"
        ssh-keygen -t ed25519 -C "${SSH_KEY_EMAIL}" -f "${SSH_KEY_PATH}" -N ""
        log "Key generated. Add the following public key as a deploy key on your Git host:"
        cat "${SSH_KEY_PATH}.pub"
        die "Re-run the script after adding the deploy key."
    fi

    log "Using SSH key ${SSH_KEY_PATH}"
    # Start a script-scoped ssh-agent so the trap can tear it down.
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add "${SSH_KEY_PATH}" </dev/null
}

# ---------------------------------------------------------------------------
# Git working copy
# ---------------------------------------------------------------------------
ensure_git_repo() {
    if [[ ! -d "${LOCAL_REPO}" ]]; then
        log "${LOCAL_REPO} does not exist. Cloning..."
        git clone --branch "${BRANCH}" "${GIT_REMOTE_URL}" "${LOCAL_REPO}"
    fi

    cd "${LOCAL_REPO}"

    if [[ ! -d .git ]]; then
        log ".git directory missing; re-initializing and attaching to origin..."
        git init
        git remote add origin "${GIT_REMOTE_URL}" 2>/dev/null || \
            git remote set-url origin "${GIT_REMOTE_URL}"
        git fetch origin "${BRANCH}"
        git checkout -B "${BRANCH}" --track "origin/${BRANCH}"
    else
        git fetch origin "${BRANCH}"
        git checkout -B "${BRANCH}" "origin/${BRANCH}" 2>/dev/null || git checkout -B "${BRANCH}"
        git pull --ff-only origin "${BRANCH}" || log "Fast-forward pull failed; continuing."
    fi

    git config user.name  "${GIT_USER_NAME}"
    git config user.email "${GIT_USER_EMAIL}"
}

# ---------------------------------------------------------------------------
# FTPS download (staging → rsync into working copy)
# ---------------------------------------------------------------------------
download_ftps() {
    command -v lftp  >/dev/null 2>&1 || die "lftp is required."
    command -v rsync >/dev/null 2>&1 || die "rsync is required."

    local staging
    staging="$(mktemp -d -t sitesync.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '${staging}'" RETURN

    log "Mirroring FTPS → staging at ${staging}"
    # Password comes from LFTP_PASSWORD so it never appears in the process table.
    LFTP_PASSWORD="${FTPS_PASS}" lftp -u "${FTPS_USER}" --env-password "ftps://${FTPS_SERVER}" <<EOF
set ssl:verify-certificate yes
set net:max-retries 3
set net:timeout 30
mirror --verbose --continue --delete --parallel=${FTPS_PARALLEL} \
       --exclude-glob .git --exclude-glob .git/* \
       --exclude-glob .ssh --exclude-glob .ssh/* \
       "${FTPS_REMOTE_DIR}" "${staging}"
quit
EOF

    log "Syncing staging → working copy (preserving .git)"
    rsync -a --delete \
        --exclude='.git' --exclude='.git/**' \
        --exclude='.ssh' --exclude='.ssh/**' \
        "${staging}/" "${LOCAL_REPO}/"
}

# ---------------------------------------------------------------------------
# Git commit + push
# ---------------------------------------------------------------------------
perform_git_operations() {
    cd "${LOCAL_REPO}"

    git add --all
    if git diff --cached --quiet; then
        log "No changes to commit."
        return 0
    fi

    git commit -m "Automated update from FTPS $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Prefer fast-forward rebase over the previous "-X ours" merge,
    # which silently discards remote changes.
    if ! git pull --rebase origin "${BRANCH}"; then
        log "Rebase failed; aborting so you can resolve conflicts manually."
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    if git push origin "${BRANCH}"; then
        log "Push succeeded."
        return 0
    fi

    if [[ "${ALLOW_FORCE_PUSH}" == "1" ]]; then
        log "Standard push failed. ALLOW_FORCE_PUSH=1 set — force-pushing with --force-with-lease."
        git push --force-with-lease origin "${BRANCH}"
    else
        die "Push failed. Set ALLOW_FORCE_PUSH=1 to allow --force-with-lease fallback."
    fi
}

# ---------------------------------------------------------------------------
# Skip prompt
# ---------------------------------------------------------------------------
maybe_skip_ftps() {
    if [[ ! -t 0 ]]; then
        # Non-interactive: never skip.
        return 1
    fi
    echo "Press any key within 5 seconds to SKIP the FTPS download."
    if read -r -t 5 -n 1 _ </dev/tty; then
        echo
        log "Skipping FTPS download."
        return 0
    fi
    echo
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    ensure_ssh_key
    ensure_git_repo

    if maybe_skip_ftps; then
        log "FTPS download skipped by user."
    else
        download_ftps
    fi

    perform_git_operations
    log "Sync completed successfully."
}

main "$@"
