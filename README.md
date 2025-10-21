# DevOps Stage 1 — Automated Deployment Script

This repository contains `deploy.sh` — a POSIX-compliant script that automates the setup and deployment of a Dockerized application to a remote Linux server.

## What the script does
1. Prompts for:
   - Git repository HTTPS URL
   - Personal Access Token (PAT)
   - Branch (default: `main`)
   - Remote SSH username
   - Remote server IP/hostname
   - SSH private key path
   - Application internal port (container port)
2. Clones or updates the repository locally (uses PAT for HTTPS repos).
3. Validates presence of `Dockerfile` or `docker-compose.yml`.
4. Rsyncs project files to the remote host.
5. Remotely installs Docker, Docker Compose, and Nginx if missing (detects package manager).
6. Builds / runs container(s) (supports `docker-compose` or single `Dockerfile`).
7. Configures Nginx as a reverse proxy (port 80 -> container internal port).
8. Validates Docker, container status, and performs basic HTTP checks.
9. Writes logs to `deploy_YYYYMMDD_HHMMSS.log`.
10. Supports `--cleanup` flag to remove containers, images and nginx config for the app.

## Usage

Make script executable:

```sh
chmod +x deploy.sh
./deploy.sh
# or cleanup
./deploy.sh --cleanup
