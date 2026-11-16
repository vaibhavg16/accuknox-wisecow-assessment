# AccuKnox DevOps Trainee Assessment — Submission Report

**Candidate:** Vaibhav Godse  
**GitHub:** `vaibhavg16`  
**Email:** godsevaibhav@gmail.com  
**Date:** 2026-11-16  
**Repository:** `https://github.com/vaibhavg16/accuknox-wisecow-assessment` (Private, `nyrahul` added)  
**Docker Image:** `docker.io/vaibhav161202/wisecow:latest`

---

## 🎯 Executive Summary

This submission demonstrates end-to-end DevOps competency: containerizing a legacy Bash application, deploying it securely on Kubernetes with GitOps-ready manifests, implementing a production-grade CI/CD pipeline with security scanning, and automating operational tasks with monitoring scripts.

**Time invested:** ~6 hours across two evenings  
**Cluster used for testing:** kind (local) + GKE (validation)  
**Key challenge:** TLS termination without modifying the original application

---

## 📦 Problem 1: Wisecow on Kubernetes

### 1.1 Containerization (`Dockerfile`)

**Base Image:** `debian:bookworm-slim` (~80MB) — chosen over Alpine for glibc compatibility with `fortune-mod`/`cowsay`.

**Key Decisions:**
- **Multi-package install** in single RUN layer: `fortune-mod`, `fortunes`, `fortunes-min`, `cowsay`, `netcat-openbsd`, `ca-certificates`
- **PATH fix**: Added `/usr/games` to PATH since Debian installs `cowsay`/`fortune` there
- **Non-root user**: UID/GID 10001, created before copying app
- **Healthcheck**: TCP port check every 30s, 10s start period
- **Cleanup**: `rm -rf /var/lib/apt/lists/*` for minimal image (~55MB final)

**Build Command:**
```bash
docker build -t vaibhav161202/wisecow:latest .
