# Wisecow on Kubernetes — AccuKnox DevOps Trainee Assessment

**Candidate:** Vaibhav Godse (`vaibhavg16`)
**Email:** godsevaibhav@gmail.com
**Docker Image:** `docker.io/vaibhav161202/wisecow:latest`
**Repository:** Private (access granted to `nyrahul`)

---

## 🎯 Problem Statement

Containerize and deploy the [Wisecow](https://github.com/nyrahul/wisecow) application on Kubernetes with:

1. A Dockerfile for the container image and K8s manifests to deploy it; the Wisecow service exposed as a K8s Service.
2. A GitHub Action that builds a new image whenever changes are pushed to the repo.
3. **[Challenge goal]** Secure TLS communication for the Wisecow app.

Plus Problem 2: two system automation scripts (Bash + Python).

---

## 🏗 Architecture

```
Client (HTTPS)
      │
      ▼
Ingress (nginx)  ── TLS via cert-manager (self-signed ClusterIssuer)
      │
      ▼
Service wisecow :443 (ClusterIP)
      │
      ├──▶ Pod 1 ── nginx sidecar :8443 (TLS) ──▶ wisecow :4499 (HTTP)
      ├──▶ Pod 2 ── nginx sidecar :8443 (TLS) ──▶ wisecow :4499 (HTTP)
      └──▶ Pod 3 ── nginx sidecar :8443 (TLS) ──▶ wisecow :4499 (HTTP)
```

**Key design decisions**

| Decision | Rationale |
|---|---|
| **TLS sidecar pattern** | The upstream Wisecow app speaks plain HTTP only. An nginx sidecar terminates TLS and proxies to `127.0.0.1:4499`, so the app source stays unmodified. This mirrors production sidecar/mesh patterns (Envoy, Istio). |
| **cert-manager + self-signed ClusterIssuer** | Automated issuance and rotation. Self-signed rather than Let's Encrypt because a local `kind` cluster has no public DNS or inbound ACME reachability. Swapping to `letsencrypt-prod` is a one-line `issuerRef` change once a real domain and ingress IP exist. |
| **Debian slim over Alpine** | `fortune-mod` / `cowsay` need glibc-compatible builds; Alpine + musl caused packaging friction. |
| **Fixed UID 10001** | Required for `runAsNonRoot: true` to be enforceable by the kubelet. |
| **`/tmp` emptyDir** | The app creates a FIFO at `/tmp/response`; a read-only root filesystem needs a writable `/tmp`. |

---

## 📦 Quick Start

### Local Docker

```bash
docker build -t vaibhav161202/wisecow:latest .
docker run -d --name wc-test -p 14500:4499 vaibhav161202/wisecow:latest
curl -s localhost:14500
docker rm -f wc-test
```

### Kubernetes (kind)

```bash
# 1. Cluster
kind create cluster --name wisecow
kind load docker-image vaibhav161202/wisecow:latest --name wisecow

# 2. cert-manager (TLS)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

# 3. metrics-server (required for HPA to read CPU/memory)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# 4. Deploy — note: apply -k (kustomize), NOT apply -f
kubectl apply -k k8s/
kubectl -n wisecow rollout status deployment/wisecow --timeout=180s

# 5. Verify HTTPS
kubectl -n wisecow port-forward svc/wisecow 8443:443 &
curl -k https://localhost:8443
```

> **`kind` caveat:** the Deployment uses `imagePullPolicy: Always`, so the kubelet pulls from Docker Hub and ignores `kind load`. Push the image first (`docker push`), otherwise pods run a stale build.

---

## 🔄 CI/CD Pipeline

**Trigger:** push to `main`, pull request, or manual `workflow_dispatch`.

| Stage | Tool | Purpose |
|---|---|---|
| Build | Docker Buildx | Layered, cached image build |
| Security scan | Trivy → SARIF | Vulnerabilities surfaced in the GitHub Security tab |
| Push | Docker Hub | Tags `latest`, `main`, `sha-<commit>` via `docker/metadata-action` |
| Manifest validation | `kubectl apply -k --dry-run=client` | Fails the build on malformed YAML |
| Layer cache | GitHub Actions cache (`type=gha`) | Fast rebuilds |

The assessment requires an Action that *creates a new image on change*, so the pipeline ends at publish. Deployment is a separate concern: a GitHub-hosted runner cannot reach a laptop-hosted `kind` cluster. The `deploy` stage is intentionally omitted; to add it, point the job at a reachable cluster (GKE/EKS or a self-hosted runner) and supply a `KUBECONFIG_DATA` secret.

**Secrets required**

- `DOCKERHUB_USERNAME` = `vaibhav161202`
- `DOCKERHUB_TOKEN` = Docker Hub access token

---

## 🔐 Security Hardening

| Control | Implementation |
|---|---|
| Non-root execution | `runAsNonRoot: true`, `runAsUser: 10001`, shell set to `/usr/sbin/nologin` |
| Read-only root filesystem | `readOnlyRootFilesystem: true` on both containers, with `emptyDir` for `/tmp`, `/var/cache/nginx`, `/var/run` |
| Capability drop | `capabilities.drop: ["ALL"]` |
| No privilege escalation | `allowPrivilegeEscalation: false` |
| Seccomp | `seccompProfile.type: RuntimeDefault` |
| Service account token | `automountServiceAccountToken: false` |
| TLS in transit | cert-manager issued; TLSv1.2/1.3 only on the sidecar |
| Image scanning | Trivy in CI, results in GitHub Security |

---

## 🛠 Problem 2: Automation Scripts

### 1. System Health Monitor — `scripts/system-health-monitor.sh`

Bash, zero dependencies beyond coreutils. Monitors:

| Metric | Threshold | Source |
|---|---|---|
| CPU usage | > 80% | `top -bn1` |
| Memory usage | > 80% | `free` |
| Disk usage (`/`) | > 85% | `df` |
| Running processes | > 300 | `ps` |

Features `set -euo pipefail`, timestamped alerts to console and `~/system-health.log`, and modular per-check functions. Cron-ready:

```cron
*/5 * * * * root /path/to/system-health-monitor.sh
```

### 2. Application Health Checker — `scripts/app-health-checker.py`

Python 3 with `requests`. Configurable retries with exponential backoff, latency measurement, and status classification:

- `up` → expected code (default 200)
- `degraded` → 4xx
- `down` → 5xx, timeout, or connection error

Supports `--json` output and CI-friendly exit codes (`0` all up, `1` any down, `2` degraded).

```bash
python3 scripts/app-health-checker.py https://example.com --json
```

---

## 📁 Repository Structure

```
.
├── Dockerfile
├── wisecow.sh
├── README.md
├── LICENSE
├── .github/
│   └── workflows/ci-cd.yaml
├── k8s/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── 00-selfsigned-issuer.yaml
│   ├── 10-certificate.yaml
│   ├── configmap.yaml
│   ├── nginx-config.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress-tls.yaml
│   └── hpa.yaml
├── scripts/
│   ├── system-health-monitor.sh
│   └── app-health-checker.py
└── docs/
    ├── SUBMISSION_REPORT.md
    └── screenshots/
```

---

## 🧪 Verified on `kind` (2026-11-17)

| Check | Result |
|---|---|
| `docker build` + local run | cowsay fortune served on :4499 |
| Image published | `docker.io/vaibhav161202/wisecow:latest` |
| Pods | 3 × `2/2 Running`, 0 restarts |
| Service | `wisecow` ClusterIP, ports 80/443; headless on 4499 |
| Ingress | class `nginx`, host `wisecow.local`, ports 80/443 |
| Certificate | `READY=True`, issued by cert-manager, renews 2027-01-16 |
| SANs | `DNS:wisecow.local`, `DNS:wisecow.wisecow.svc.cluster.local` |
| HTTPS | `curl -k https://localhost:8443` → cowsay over **TLSv1.3 / TLS_AES_256_GCM_SHA384** |
| Plain HTTP to TLS port | `400` — correctly refused |
| HPA | `cpu: 4%/70%, memory: 5%/80%`, 3→10 replicas, metrics-server live |
| Scripts | Both executed successfully |

---

## ✅ Submission Checklist

- [x] Dockerfile builds, runs, passes HTTP healthcheck
- [x] K8s manifests apply cleanly; pods Ready
- [x] Service exposes the app; Ingress terminates TLS
- [x] HPA scales on CPU and memory
- [x] GitHub Actions builds, scans, and publishes on every push
- [x] Trivy scan integrated, SARIF uploaded to GitHub Security
- [x] Two automation scripts (Bash + Python)
- [x] Documentation: README + `docs/SUBMISSION_REPORT.md`
- [ ] Repository set to **private**
- [ ] `nyrahul` added as collaborator (Read)

---

## 📞 Contact

**Vaibhav Godse** — godsevaibhav@gmail.com
