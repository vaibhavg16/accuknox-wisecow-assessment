# Wisecow on Kubernetes — AccuKnox DevOps Trainee Assessment

**Candidate:** Vaibhav Godse (`vaibhavg16`)  
**Email:** godsevaibhav@gmail.com  
**Docker Image:** `docker.io/vaibhav161202/wisecow:latest`  
**Repository:** Private, `nyrahul` collaborator added

---

## 🎯 Problem Statement

Containerize and deploy the [Wisecow](https://github.com/nyrahul/wisecow) application on Kubernetes with:
1. Dockerfile for container image
2. K8s manifests (Deployment, Service, Ingress, HPA)
3. GitHub Actions CI/CD pipeline (build → scan → push → deploy)
4. TLS communication via cert-manager + Let's Encrypt
5. Two automation scripts (System Health Monitor + App Health Checker)

---

## 🏗 Architecture
Client (HTTPS)
│
▼
Ingress (nginx) — TLS termination (cert-manager/Let's Encrypt)
│
▼
Service:443 (ClusterIP)
│
├──▶ Pod 1: wisecow:4499 + nginx-sidecar:8443
├──▶ Pod 2: wisecow:4499 + nginx-sidecar:8443
└──▶ Pod 3: wisecow:4499 + nginx-sidecar:8443

**Key Design Decisions:**
- **Sidecar pattern** for TLS: App stays HTTP-only; nginx sidecar handles TLS termination
- **Non-root containers**: UID 10001, dropped capabilities
- **End-to-end TLS**: Client → Ingress → Service:443 → Sidecar:8443 → App:4499
- **HPA**: Scales on CPU (70%) and Memory (80%)

---

## 📦 Quick Start

### Local Docker Test
```bash
docker build -t vaibhav161202/wisecow:latest .
docker run -d -p 4499:4499 vaibhav161202/wisecow:latest
curl localhost:4499
