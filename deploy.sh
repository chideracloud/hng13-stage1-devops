#!/bin/bash


# -------------------------------------------------------------------
# deploy.sh
# Automated deployment script for Dockerized apps on remote servers
# Author: chidera cloud
# -------------------------------------------------------------------

set -euo pipefail

# --- EARLY CLEANUP CHECK ---
if [ "${1:-}" = "--cleanup" ]; then
  read -rp "Enter remote server username: " REMOTE_USER
  read -rp "Enter remote server IP address: " REMOTE_HOST
  read -rp "Enter SSH key path: " SSH_KEY

  if [ ! -f "$SSH_KEY" ]; then
    echo "[ERROR] SSH key not found at $SSH_KEY"
    exit 1
  fi

  echo "[INFO] Running cleanup on $REMOTE_HOST..."
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<'CLEAN'
  docker stop app || true
  docker rm app || true
  docker system prune -af
  sudo rm -f /etc/nginx/sites-enabled/app /etc/nginx/sites-available/app
  sudo systemctl reload nginx
CLEAN
  echo "[INFO] Cleanup completed successfully."
  exit 0
fi

# --- CONFIGURATION ---
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# --- LOGGING FUNCTIONS ---
log() {
  echo "[INFO] $1" | tee -a "$LOG_FILE"
}

err() {
  echo "[ERROR] $1" | tee -a "$LOG_FILE" >&2
}

trap 'err "Unexpected error occurred on line $LINENO"; exit 99' ERR

# --- STEP 1: COLLECT PARAMETERS ---

read -rp "Enter Git repository URL: " GIT_URL
read -rp "Enter your Personal Access Token (PAT): " PAT
read -rp "Enter branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -rp "Enter remote server username: " REMOTE_USER
read -rp "Enter remote server IP address: " REMOTE_HOST
read -rp "Enter SSH key path: " SSH_KEY
read -rp "Enter internal application port (e.g., 5000): " APP_PORT

# Validate SSH key
if [ ! -f "$SSH_KEY" ]; then
  err "SSH key not found at $SSH_KEY"
  exit 1
fi

log "Parameters collected successfully."

# --- STEP 2: CLONE OR UPDATE REPOSITORY ---

REPO_DIR=$(basename "$GIT_URL" .git)

if [ -d "$REPO_DIR" ]; then
  log "Repository exists. Pulling latest changes..."
  cd "$REPO_DIR"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
else
  log "Cloning repository..."
  git clone "https://${PAT}@${GIT_URL#https://}" "$REPO_DIR"
  cd "$REPO_DIR"
  git checkout "$BRANCH"
fi

log "Repository ready on branch '$BRANCH'."

# --- STEP 3: VERIFY DOCKER FILES EXIST ---
HAS_DOCKERFILE=0
HAS_COMPOSE=0

if [ -f "Dockerfile" ]; then
  HAS_DOCKERFILE=1
fi

if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
  HAS_COMPOSE=1
fi

if [ "$HAS_DOCKERFILE" -eq 0 ] && [ "$HAS_COMPOSE" -eq 0 ]; then
  err "Neither Dockerfile nor docker-compose.yml found in repository root."
  exit 21
fi

log "Project ready (Dockerfile: $HAS_DOCKERFILE, docker-compose: $HAS_COMPOSE)"

# --- STEP 4: VERIFY SSH CONNECTION ---
log "Testing SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_HOST" 'echo connected' >/dev/null 2>&1; then
  err "Unable to connect to remote server via SSH."
  exit 2
fi
log "SSH connectivity confirmed."

# --- STEP 5: PREPARE REMOTE ENVIRONMENT ---

log "Preparing remote environment (installing Docker, Docker Compose, Nginx)..."

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<'EOF'
set -e

sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common nginx

# Install Docker if missing
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker $USER
fi

# Install Docker Compose if missing
if ! command -v docker-compose &>/dev/null; then
  sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

EOF

log "Remote environment prepared successfully."

# --- STEP 6: DEPLOY DOCKERIZED APPLICATION ---

log "Deploying My Dockerized application to the remote server..."

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<EOF
set -e
cd ~
rm -rf ~/app || true
mkdir -p ~/app
EOF

log "Transferring my project files..."
scp -i "$SSH_KEY" -r ./* "$REMOTE_USER@$REMOTE_HOST":~/app

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<EOF
set -e
cd ~/app

if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
  echo "[INFO] Using docker-compose..."
  docker-compose down || true
  docker-compose pull || true
  docker-compose up -d --build
else
  echo "[INFO] Using Dockerfile..."
  docker stop app || true
  docker rm app || true
  docker build -t myapp:latest .
  docker run -d --name app -p ${APP_PORT}:${APP_PORT} myapp:latest
fi

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

log "Application deployed successfully."

# --- STEP 7: CONFIGURE NGINX REVERSE PROXY ---
log "Configuring Nginx reverse proxy..."

# Validate APP_PORT is set
if [ -z "${APP_PORT:-}" ]; then
  err "APP_PORT is empty. Please provide a valid internal container port."
  exit 3
fi

# Build the config locally with the correct port substituted
NGINX_CONF=$(cat <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
)

# Stream the config to the remote server safely
printf '%s\n' "$NGINX_CONF" | ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" "sudo tee /etc/nginx/sites-available/app >/dev/null"

# Enable and reload nginx
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<'REMOTE'
set -e
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
sudo nginx -t
sudo systemctl reload nginx
REMOTE

log "Nginx reverse proxy configured (port 80 → ${APP_PORT})."

# --- STEP 8: VALIDATE DEPLOYMENT ---
log "Validating deployment..."

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<EOF
set -e
docker ps
curl -I http://127.0.0.1:${APP_PORT} || true
EOF

log "Deployment validation complete."

# --- EARLY CLEANUP CHECK ---
if [ "${1:-}" = "--cleanup" ]; then
  read -rp "Enter remote server username: " REMOTE_USER
  read -rp "Enter remote server IP address: " REMOTE_HOST
  read -rp "Enter SSH key path: " SSH_KEY

  if [ ! -f "$SSH_KEY" ]; then
    echo "[ERROR] SSH key not found at $SSH_KEY"
    exit 1
  fi

  echo "[INFO] Running cleanup on $REMOTE_HOST..."
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" bash <<'CLEAN'
  docker stop app || true
  docker rm app || true
  docker system prune -af
  sudo rm -f /etc/nginx/sites-enabled/app /etc/nginx/sites-available/app
  sudo systemctl reload nginx
CLEAN
  echo "[INFO] Cleanup completed successfully."
  exit 0
fi

log "✅ My Deployment script finished successfully!"
