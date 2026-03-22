#!/bin/bash
set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Configuration from environment variables
MOUNT_PATH="${MOUNT_PATH:-/pvc-mount}"
REMOTE_URL="${GIT_URL}"
BRANCH="${GIT_BRANCH:-main}"
SYNC_MODE="${SYNC_STRATEGY:-polling}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
AUTH_TYPE="${AUTH_TYPE:-none}"

log "=== Git Sync Container Starting ==="
log "Mount path: $MOUNT_PATH"
log "Remote URL: $REMOTE_URL"
log "Branch: $BRANCH"
log "Sync mode: $SYNC_MODE"
log "Poll interval: ${POLL_INTERVAL}s"
log "Auth type: $AUTH_TYPE"

setup_ssh_auth() {
    log "Setting up SSH authentication"
    mkdir -p /tmp/.ssh
    if [ -f /root/.ssh/id_rsa ]; then
        cp /root/.ssh/id_rsa /tmp/.ssh/id_rsa
        chmod 600 /tmp/.ssh/id_rsa
        if [ -f /root/.ssh/known_hosts ]; then
            cp /root/.ssh/known_hosts /tmp/.ssh/known_hosts
        else
            : > /tmp/.ssh/known_hosts
        fi
        cat > /tmp/.ssh/config <<EOF
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /tmp/.ssh/known_hosts
  IdentityFile /tmp/.ssh/id_rsa
EOF
        chmod 600 /tmp/.ssh/config
        export GIT_SSH_COMMAND="ssh -F /tmp/.ssh/config"
        log "SSH authentication configured"
    else
        log "WARNING: SSH key not found at /root/.ssh/id_rsa"
    fi
}

setup_http_auth() {
    log "Setting up HTTP authentication"
    mkdir -p /tmp/git-auth
    cat > /tmp/git-auth/askpass.sh <<'EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s' "$GIT_USERNAME" ;;
    *Password*) printf '%s' "$GIT_PASSWORD" ;;
    *) printf '%s' "$GIT_PASSWORD" ;;
esac
EOF
    chmod 700 /tmp/git-auth/askpass.sh
    export GIT_ASKPASS=/tmp/git-auth/askpass.sh
    export GIT_TERMINAL_PROMPT=0
    log "HTTP authentication configured"
}

perform_sync() {
    log "=== Starting sync operation ==="
    
    # Check mount path
    if [ ! -d "$MOUNT_PATH" ]; then
        log "Creating mount directory: $MOUNT_PATH"
        mkdir -p "$MOUNT_PATH"
    fi
    
    log "Changing to mount directory: $MOUNT_PATH"
    cd "$MOUNT_PATH"
    
    # Check if git repo exists
    if [ ! -d ".git" ]; then
        log "No git repository found, initializing"
        if [ -n "$(ls -A . 2>/dev/null || true)" ]; then
            log "Directory not empty, initializing git repo in place"
            git init
            if git remote get-url origin >/dev/null 2>&1; then
                git remote set-url origin "$REMOTE_URL"
            else
                git remote add origin "$REMOTE_URL"
            fi
        else
            log "Cloning repository: $REMOTE_URL (branch: $BRANCH)"
            git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" .
        fi
    fi
    
    log "Fetching latest changes from origin/$BRANCH"
    git fetch --depth 1 origin "$BRANCH"
    
    log "Checking out branch: $BRANCH"
    git checkout -B "$BRANCH" "origin/$BRANCH" 2>/dev/null || git checkout -B "$BRANCH" FETCH_HEAD
    
    log "Resetting to origin/$BRANCH"
    git reset --hard "origin/$BRANCH" 2>/dev/null || git reset --hard FETCH_HEAD
    
    local current_commit
    current_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "Sync completed successfully. Current commit: $current_commit"
    log "=== Sync operation finished ==="
}

# Main execution
log "Setting up authentication"
case "$AUTH_TYPE" in
    ssh_key) setup_ssh_auth ;;
    token|basic) setup_http_auth ;;
    none) log "No authentication configured" ;;
    *) log "WARNING: Unknown auth type: $AUTH_TYPE" ;;
esac

# Initial sync
perform_sync

# Run according to sync mode
case "$SYNC_MODE" in
    polling)
        log "Polling mode enabled. Interval: ${POLL_INTERVAL}s"
        while true; do
            sleep "$POLL_INTERVAL"
            log "=== Polling sync triggered ==="
            perform_sync || log "Polling sync failed, will retry next interval"
        done
        ;;
    webhook)
        log "Webhook mode enabled. Waiting for manual triggers..."
        # In webhook mode, container stays running
        # Manual sync can be triggered via kubectl exec
        tail -f /dev/null
        ;;
    oneshot)
        log "Oneshot mode completed. Exiting."
        ;;
    *)
        log "ERROR: Unknown sync mode: $SYNC_MODE"
        exit 1
        ;;
esac
