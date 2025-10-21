#!/bin/sh
# POSIX-compliant deployment script for Stage 1 DevOps task
# Usage: ./deploy.sh [--cleanup]
# - Prompts for Git repo, PAT, branch (defaults to main), remote SSH details, container port.
# - Clones/pulls repo, transfers to remote, installs Docker/Docker Compose/Nginx if missing,
#   deploys Docker or docker-compose, configures Nginx reverse proxy, validates deployment.
# - Logs to deploy_YYYYMMDD_HHMMSS.log
# - Idempotent, supports --cleanup to remove deployed resources.
#
# NOTE: This script assumes:
# - Remote server is a modern Debian/Ubuntu/CentOS-like Linux (it attempts to detect package manager).
# - You have SSH access via the provided key.
# - PAT has appropriate scope to clone the repository (repo/read access).
#
# Exit codes:
#  0 - success
#  10 - user input / validation error
#  20 - git/clone error
#  30 - ssh/connection error
#  40 - remote preparation/install error
#  50 - deployment error
#  60 - validation error
#
# Author: Generated for HNG Stage 1 task

# -------------------------
# Utilities / init
# -------------------------
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="deploy_${TIMESTAMP}.log"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
    printf '%s\n' "$1"
}

err() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "ERROR: $1" >> "$LOGFILE"
    printf 'ERROR: %s\n' "$1" 1>&2
}

die() {
    err "$1"
    exit "$2"
}

trap_on_exit() {
    rc=$?
    if [ $rc -ne 0 ]; then
        err "Script exited abnormally with code $rc"
    else
        log "Script finished successfully"
    fi
}
trap 'trap_on_exit' EXIT INT TERM

# Check required commands locally
required_cmds="git ssh scp rsync curl awk sed"
for c in $required_cmds; do
    if ! command -v "$c" >/dev/null 2>&1; then
        die "Local command '$c' is required but not found. Install it and re-run." 10
    fi
done

# -------------------------
# Parse flags
# -------------------------
CLEANUP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cleanup)
            CLEANUP=1
            shift
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--cleanup]
  --cleanup    Remove deployed resources (containers, nginx config) on remote host.
EOF
            exit 0
            ;;
        *)
            die "Unknown option: $1" 10
            ;;
    esac
done

# -------------------------
# Prompt for inputs
# -------------------------
prompt() {
    printf '%s' "$1"
    read val
    printf '%s' "$val"
}

log "Starting deployment script"

printf 'Enter Git repository URL (HTTPS): '
read GIT_URL
if [ -z "$GIT_URL" ]; then
    die "Git repository URL is required." 10
fi

printf 'Enter Personal Access Token (PAT) (input hidden): '
# POSIX sh doesn't have read -s universally, emulate by stty if available
if command -v stty >/dev/null 2>&1; then
    stty -echo
    read PAT
    stty echo
    printf '\n'
else
    read PAT
fi
if [ -z "$PAT" ]; then
    die "PAT is required to authenticate to private repos." 10
fi

printf 'Branch name (default: main): '
read BRANCH
if [ -z "$BRANCH" ]; then
    BRANCH=main
fi

printf 'Remote SSH username: '
read REMOTE_USER
if [ -z "$REMOTE_USER" ]; then
    die "Remote SSH username required." 10
fi

printf 'Remote server IP or hostname: '
read REMOTE_HOST
if [ -z "$REMOTE_HOST" ]; then
    die "Remote host required." 10
fi

printf 'Path to SSH private key (e.g. ~/.ssh/id_rsa): '
read SSH_KEY_PATH
if [ -z "$SSH_KEY_PATH" ]; then
    die "SSH key path required." 10
fi
if [ ! -f "$SSH_KEY_PATH" ]; then
    die "SSH key file '$SSH_KEY_PATH' not found." 10
fi

printf 'Internal application port (container port, e.g. 8000): '
read APP_PORT
if [ -z "$APP_PORT" ]; then
    die "Application port required." 10
fi

# Derive repo name and folder
# Strip .git if present
REPO_NAME=$(basename "$GIT_URL" .git)
LOCAL_CLONE_DIR="$PWD/${REPO_NAME}"

log "Parameters: repo=$GIT_URL branch=$BRANCH remote=$REMOTE_USER@$REMOTE_HOST app_port=$APP_PORT"

# -------------------------
# Prepare authenticated clone URL
# -------------------------
# For HTTPS PAT usage: insert token into URL: https://<PAT>@github.com/owner/repo.git
# Beware: this can expose PAT in process list; we minimize exposure by using git -c instead of env in many cases.
AUTH_GIT_URL="$GIT_URL"
# If URL starts with https://
case "$GIT_URL" in
    https://*)
        # Inject PAT (urlencoded minimally) - PAT may contain '@' or ':'; that is edge-case.
        AUTH_GIT_URL=$(printf '%s' "$GIT_URL" | sed "s#https://#https://${PAT}@#")
        ;;
    git@*|ssh://*)
        # For SSH-based repos assume key has access; do not use PAT
        AUTH_GIT_URL="$GIT_URL"
        ;;
    *)
        AUTH_GIT_URL="$GIT_URL"
        ;;
esac

# -------------------------
# Clone or pull repository locally
# -------------------------
if [ -d "$LOCAL_CLONE_DIR/.git" ]; then
    log "Repository already exists locally at $LOCAL_CLONE_DIR. Attempting git fetch & checkout."
    cd "$LOCAL_CLONE_DIR" || die "Failed to cd into $LOCAL_CLONE_DIR" 20
    # Try to set remote url with PAT if HTTPS
    if printf '%s' "$AUTH_GIT_URL" | grep -q 'https://'; then
        git remote set-url origin "$AUTH_GIT_URL" >>"$LOGFILE" 2>&1 || true
    fi
    if ! git fetch origin >>"$LOGFILE" 2>&1; then
        die "git fetch failed" 20
    fi
    if ! git checkout "$BRANCH" >>"$LOGFILE" 2>&1; then
        # try to create and track
        git checkout -B "$BRANCH" "origin/$BRANCH" >>"$LOGFILE" 2>&1 || die "Failed to checkout branch $BRANCH" 20
    fi
    if ! git pull --ff-only origin "$BRANCH" >>"$LOGFILE" 2>&1; then
        log "git pull returned non-zero; continuing (may be up-to-date or need manual merge)."
    fi
else
    log "Cloning repository into $LOCAL_CLONE_DIR"
    # Create parent dir if necessary
    if ! git clone --depth 1 --branch "$BRANCH" "$AUTH_GIT_URL" "$LOCAL_CLONE_DIR" >>"$LOGFILE" 2>&1; then
        # Try full clone without depth as fallback
        if ! git clone --branch "$BRANCH" "$AUTH_GIT_URL" "$LOCAL_CLONE_DIR" >>"$LOGFILE" 2>&1; then
            die "Failed to clone repository $GIT_URL" 20
        fi
    fi
    cd "$LOCAL_CLONE_DIR" || die "Failed to cd into $LOCAL_CLONE_DIR" 20
fi

# Check for Dockerfile or docker-compose.yml
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    log "Dockerfile or docker-compose found."
else
    err "No Dockerfile or docker-compose.yml found in repo root. Aborting."
    die "Missing Dockerfile or docker-compose.yml" 20
fi

# Derive a container name from repo name
CONTAINER_NAME=$(printf '%s' "$REPO_NAME" | sed 's/[^a-zA-Z0-9_.-]/-/g')
REMOTE_APP_DIR="/opt/${CONTAINER_NAME}"

# -------------------------
# Connectivity check to remote
# -------------------------
SSH_OPTS="-i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
log "Testing SSH connectivity to $REMOTE_USER@$REMOTE_HOST"
if ! ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "printf 'SSH OK\n'" >>"$LOGFILE" 2>&1; then
    die "SSH connectivity test failed. Check network, firewall, and key." 30
fi
log "SSH connectivity OK"

# -------------------------
# Remote helper functions (sent as a heredoc)
# -------------------------
REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
set -eu
# remote helper script fragment
REPO_DIR="$1"
USER="$2"
CONTAINER_NAME="$3"
APP_PORT="$4"

log_remote() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    else
        printf ''
    fi
}

pkg_mgr=$(detect_pkg_manager)
log_remote "Detected package manager: $pkg_mgr"

install_if_missing() {
    cmd="$1"
    pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_remote "$cmd not found. Attempting to install package $pkg."
        case "$pkg_mgr" in
            apt)
                sudo apt-get update -y && sudo apt-get install -y "$pkg"
                ;;
            yum)
                sudo yum install -y "$pkg"
                ;;
            dnf)
                sudo dnf install -y "$pkg"
                ;;
            *)
                log_remote "No supported package manager found. Please install $pkg manually."
                exit 1
                ;;
        esac
    else
        log_remote "$cmd is present."
    fi
}

# Install Docker (simple path)
if ! command -v docker >/dev/null 2>&1; then
    log_remote "Installing Docker (simple install)."
    if [ "$pkg_mgr" = "apt" ]; then
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        # fallback: try package install
        install_if_missing docker docker
    fi
fi

# Install docker-compose (v2 plugin or python compose)
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    log_remote "Installing docker-compose"
    if [ "$pkg_mgr" = "apt" ]; then
        sudo apt-get install -y docker-compose || true
    else
        install_if_missing docker-compose docker-compose || true
    fi
fi

# Add current user to docker group
if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" || true
fi

# Ensure services are enabled (systemd path)
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable docker || true
    sudo systemctl start docker || true
fi

# Ensure Nginx installed
install_if_missing nginx nginx || true
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable nginx || true
    sudo systemctl start nginx || true
fi

# Make sure REPO_DIR exists
sudo mkdir -p "$REPO_DIR"
sudo chown "$USER":"$USER" "$REPO_DIR"

# Clean up possible old container
if docker ps -a --format '{{.Names}}' | grep -w "$CONTAINER_NAME" >/dev/null 2>&1; then
    log_remote "Stopping and removing existing container $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" || true
fi

# If docker-compose.yml present, run compose; else try docker build/run
cd "$REPO_DIR" || exit 1
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    # Use docker compose (v2) if available
    if docker compose version >/dev/null 2>&1; then
        docker compose down || true
        docker compose up -d --remove-orphans
    else
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose down || true
            docker-compose up -d --remove-orphans
        else
            log_remote "No docker compose available; aborting."
            exit 1
        fi
    fi
else
    # Build image and run
    docker build -t "$CONTAINER_NAME:latest" .
    # Remove old container if exists
    if docker ps -a --format '{{.Names}}' | grep -w "$CONTAINER_NAME" >/dev/null 2>&1; then
        docker rm -f "$CONTAINER_NAME" || true
    fi
    # Run detached, expose port
    docker run -d --name "$CONTAINER_NAME" -p 127.0.0.1:$APP_PORT:$APP_PORT --restart unless-stopped "$CONTAINER_NAME:latest"
fi

# Return success
log_remote "Deployment steps finished on remote host."
exit 0
REMOTE_EOF
)

# -------------------------
# Transfer code to remote
# -------------------------
log "Syncing project to remote $REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR"
# Use rsync for idempotent sync
if ! rsync -az --delete --exclude '.git' -e "ssh $SSH_OPTS" "$LOCAL_CLONE_DIR"/ "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR" >>"$LOGFILE" 2>&1; then
    die "rsync to remote failed" 50
fi
log "Files synced to remote"

# -------------------------
# Option: cleanup remote resources
# -------------------------
if [ "$CLEANUP" -eq 1 ]; then
    log "Cleanup flag set. Attempting to remove containers, docker images, and nginx config for $CONTAINER_NAME on remote."
    CLEANUP_CMD=$(cat <<CLEAN_EOF
set -e
# Stop & remove container
if docker ps -a --format '{{.Names}}' | grep -w "$CONTAINER_NAME" >/dev/null 2>&1; then
  docker rm -f "$CONTAINER_NAME" || true
fi
# Remove image
if docker images -q "$CONTAINER_NAME:latest" >/dev/null 2>&1; then
  docker rmi -f "$CONTAINER_NAME:latest" || true
fi
# Remove nginx conf if exists
NGX_CONF="/etc/nginx/sites-enabled/${CONTAINER_NAME}.conf"
if [ -f "\$NGX_CONF" ]; then
  sudo rm -f "\$NGX_CONF"
  sudo nginx -t || true
  sudo systemctl reload nginx || true
fi
CLEAN_EOF
)
    ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "sh -s" <<EOF >>"$LOGFILE" 2>&1
$CLEANUP_CMD
EOF
    if [ $? -ne 0 ]; then
        die "Remote cleanup failed" 50
    fi
    log "Remote cleanup completed successfully"
    exit 0
fi

# -------------------------
# Execute remote preparation + deploy
# -------------------------
log "Running remote preparation and deployment script"
ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "sh -s" <<EOF >>"$LOGFILE" 2>&1
# create a temp script and run it with args: remote_dir user container_name app_port
cat > /tmp/deploy_helper.sh <<'INNER'
$REMOTE_SCRIPT
INNER
chmod +x /tmp/deploy_helper.sh
/tmp/deploy_helper.sh "$REMOTE_APP_DIR" "$REMOTE_USER" "$CONTAINER_NAME" "$APP_PORT"
EOF

if [ $? -ne 0 ]; then
    die "Remote deployment failed. Check $LOGFILE for details." 50
fi
log "Remote deployment executed"

# -------------------------
# Configure Nginx on remote
# -------------------------
log "Writing Nginx configuration on remote to proxy port 80 => localhost:$APP_PORT"

NGINX_CONF="server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    access_log /var/log/nginx/${CONTAINER_NAME}_access.log;
    error_log /var/log/nginx/${CONTAINER_NAME}_error.log;
}
"

# Upload nginx conf
echo "$NGINX_CONF" | ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "sudo tee /etc/nginx/sites-available/${CONTAINER_NAME}.conf > /dev/null && sudo ln -sf /etc/nginx/sites-available/${CONTAINER_NAME}.conf /etc/nginx/sites-enabled/${CONTAINER_NAME}.conf && sudo nginx -t && sudo systemctl reload nginx" >>"$LOGFILE" 2>&1

if [ $? -ne 0 ]; then
    err "Nginx config test or reload failed. Check logs on remote."
    # Not fatal; continue to validation with warning
else
    log "Nginx configured and reloaded successfully on remote"
fi

# -------------------------
# Validation checks
# -------------------------
log "Validating services on remote"

# 1) Check Docker service
ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "docker info >/dev/null 2>&1" >>"$LOGFILE" 2>&1 || die "Docker does not appear to be running on remote" 60
log "Docker running on remote"

# 2) Check container is running (by name)
if ! ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "docker ps --format '{{.Names}}' | grep -w '$CONTAINER_NAME' >/dev/null 2>&1"; then
    err "Container $CONTAINER_NAME is not running on remote. Check docker logs."
    ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "docker ps -a --filter name=$CONTAINER_NAME --format 'Name: {{.Names}} Status: {{.Status}}' || true" >>"$LOGFILE" 2>&1
    die "Target container not active" 60
fi
log "Container $CONTAINER_NAME is running"

# 3) Test local curl on remote via nginx (port 80)
log "Testing HTTP endpoint via Nginx on remote (curl http://127.0.0.1/)"
if ! ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "curl -sS -I http://127.0.0.1/ | head -n 5" >>"$LOGFILE" 2>&1; then
    err "HTTP test failed on remote. See $LOGFILE"
    die "HTTP test failed" 60
fi
log "HTTP endpoint responded on remote"

# 4) Test from local to remote public IP:80
log "Testing endpoint from local machine to http://$REMOTE_HOST/"
if ! (curl -sS -I "http://$REMOTE_HOST/" -m 10 | head -n 5) >>"$LOGFILE" 2>&1; then
    err "Public HTTP test failed. Network or firewall may block port 80."
    # Not fatal - only warn
    log "Warning: remote public HTTP test failed. Container may still be accessible internally."
else
    log "Public HTTP test succeeded"
fi

# -------------------------
# Final success
# -------------------------
log "Deployment completed. Review $LOGFILE for full output."
printf 'Deployment successful. Log: %s\n' "$LOGFILE"
exit 0
