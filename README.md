# 🚀 Automated Deployment Bash Script — HNG Stage 1 DevOps Task

## 📘 Overview

This project is part of the **HNG 13 DevOps Internship (Stage 1)**.  
The goal is to build a **production-ready Bash script (`deploy.sh`)** that automates the setup, configuration, and deployment of a **Dockerized application** to a **remote Linux server**.

The script performs all the necessary DevOps steps such as cloning a repository, installing dependencies, deploying containers, setting up Nginx, and validating the deployment — all without manual intervention.

---

## 🎯 Objective

- Automate deployment of a Dockerized application to a remote server.
- Handle setup, configuration, and environment preparation end-to-end.
- Implement robust error handling, validation, and logging.
- Ensure idempotency — the script can be safely re-run without breaking anything.

---

## 🧠 Features

✅ Interactive user input and validation  
✅ Secure SSH connection to remote server  
✅ Automatic environment setup (Docker, Nginx, Docker Compose)  
✅ Application deployment and verification  
✅ Nginx reverse proxy configuration  
✅ Detailed logging and error handling  
✅ Safe cleanup and idempotent operations  

---

## ⚙️ Script Workflow

### **1. Collect User Input**
Prompts for:
- GitHub repository URL  
- Personal Access Token (PAT)  
- Branch name (default: `main`)  
- SSH details (username, server IP, key path)  
- Application port (internal container port)

### **2. Clone or Update Repository**
- Authenticates with PAT  
- Clones the repository or updates it if already cloned  
- Switches to the specified branch  
- Checks for `Dockerfile` or `docker-compose.yml`

###
