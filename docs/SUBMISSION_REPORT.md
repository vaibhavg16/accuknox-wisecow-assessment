# AccuKnox DevOps Trainee Assessment — Submission Report

**Candidate:** Vaibhav Godse
**GitHub:** `vaibhavg16`
**Email:** godsevaibhav@gmail.com
**Date:** 2026-11-17
**Repository:** `https://github.com/vaibhavg16/accuknox-wisecow-assessment` (private, `nyrahul` has access)
**Docker Image:** `docker.io/vaibhav161202/wisecow:latest`
**Test Cluster:** `kind` v1.36.1 (`wisecow`), single control-plane node

---

## Executive Summary

Problem 1 is delivered end-to-end and verified on a live cluster: the legacy Bash Wisecow app is containerized, deployed as three replicas behind a Service and Ingress, autoscaled by an HPA, and served over **TLSv1.3** using a cert-manager-issued certificate. A GitHub Actions pipeline builds, scans, and publishes a new image on every push. Problem 2 delivers two operational scripts in Bash and Python.

The interesting constraint was the TLS challenge goal: Wisecow is a raw `nc`-based HTTP/1.1 responder with no TLS support and no intention of gaining any. Rather than fork the app, TLS is terminated by an nginx sidecar in the same Pod, which proxies to `127.0.0.1:4499`. The application source remains byte-identical to upstream apart from a one-line path fix (see §1.1).

---

## Problem 1 — Wisecow on Kubernetes

### 1.1 Containerization

**Base image:** `debian:bookworm-slim`. Alpine was tried first and abandoned: `fortune-mod` and `cowsay` pull glibc-oriented packaging, and working around musl added more complexity than the ~50 MB saving was worth on a teaching exercise.

**Dockerfile decisions**

| Decision | Detail |
|---|---|
| Single `RUN` for packages | `fortune-mod`, `fortunes`, `fortunes-min`, `cowsay`, `netcat-openbsd`, `curl`, `ca-certificates` — one layer, then `rm -rf /var/lib/apt/lists/*` |
| `PATH` includes `/usr/games` | Debian installs `cowsay` and `fortune` there, not in `/usr/bin`. This was the first build failure: the image built fine and then died at runtime with `cowsay: command not found`. |
| Non-root, fixed UID | `groupadd -g 10001` / `useradd -u 10001 -s /usr/sbin/nologin`. A fixed numeric UID is required for `runAsNonRoot` to be checkable before the container starts. |
| `HEALTHCHECK` uses `curl` | An earlier `nc -z localhost 4499` check was replaced. Wisecow's single-threaded accept loop makes a TCP connect unreliable as a liveness signal, and the `nc` probe consumed the pending connection. `curl -fsS --max-time 4` exercises the real request path. |
| `ENTRYPOINT ["./wisecow.sh"]` | Exec form so the script is PID 1 and receives signals. |

**Script change vs. upstream:** the FIFO was relocated from `./response` to `/tmp/response`. The app needs a writable directory, and `/tmp` is the only path guaranteed writable under `readOnlyRootFilesystem: true` with an `emptyDir` mount. This is the single functional deviation from upstream `wisecow.sh`; the request-handling logic is untouched.

### 1.2 Kubernetes Manifests

Nine resources, applied with `kubectl apply -k k8s/`:

| File | Purpose |
|---|---|
| `namespace.yaml` | Isolated `wisecow` namespace with tooling labels |
| `00-selfsigned-issuer.yaml` | `ClusterIssuer` for local TLS |
| `10-certificate.yaml` | `Certificate` → `wisecow-tls` Secret; SANs `wisecow.local` and `wisecow.wisecow.svc.cluster.local` |
| `configmap.yaml` | `SRVPORT` and log level injected as env |
| `nginx-config.yaml` | Sidecar `nginx.conf` — TLSv1.2/1.3 only, proxy to `127.0.0.1:4499` |
| `deployment.yaml` | 3 replicas, two containers, probes, resources, hardened `securityContext` |
| `service.yaml` | ClusterIP on 80/443 + headless service on 4499 |
| `ingress-tls.yaml` | `ingressClassName: nginx`, cert-manager annotation, forced HTTPS redirect |
| `hpa.yaml` | min 3 / max 10, CPU 70% / memory 80%, tuned scale-up and scale-down behaviour |

**Hardening applied to both containers**

```yaml
securityContext:            # pod level
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
automountServiceAccountToken: false

# container level
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

**Probe tuning:** the app accepts one connection at a time, so `timeoutSeconds: 5` was set on both probes rather than the defaults. Under-tuned probes were the second observed failure mode during testing — the pod would report healthy locally but flap in-cluster.

### 1.3 TLS — the challenge goal

**Why a sidecar.** Three options were considered:

1. *Modify `wisecow.sh` to use `openssl s_server` or `ncat --ssl`.* Rejected — rewrites the app's transport layer and diverges from upstream.
2. *Ingress-only termination.* Simpler, but leaves Pod-to-Service traffic in plaintext and doesn't demonstrate the in-Pod pattern that production meshes use.
3. *nginx sidecar terminating TLS.* **Chosen.** The app stays HTTP on loopback; TLS is confined to the sidecar; the same container works unchanged whether or not TLS is enabled.

**Flow**

```
curl -k https://localhost:8443
   → Service wisecow:443
   → nginx sidecar :8443   [TLS terminated here, TLSv1.2/1.3]
   → 127.0.0.1:4499        [loopback, plain HTTP]
   → wisecow.sh → fortune | cowsay
```

The sidecar needed three `emptyDir` mounts (`/tmp`, `/var/cache/nginx`, `/var/run`) to survive `readOnlyRootFilesystem: true`. Without them nginx exits immediately — `/var/cache/nginx` is not optional for the stock image.

**Certificate.** cert-manager v1.13.0, `ClusterIssuer` of type `SelfSigned`, a `Certificate` resource with explicit `dnsNames`. Self-signed rather than Let's Encrypt because a local `kind` cluster has no public DNS name and no inbound path for the ACME HTTP-01 challenge. Swapping to production is a single `issuerRef` change plus a real domain.

### 1.4 CI/CD Pipeline

`.github/workflows/ci-cd.yaml` — triggers on push to `main`, pull requests, and `workflow_dispatch`.

| Step | Action |
|---|---|
| Checkout | `actions/checkout@v4` |
| Buildx | `docker/setup-buildx-action@v3` |
| Docker Hub login | `docker/login-action@v3` with `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets |
| Tag computation | `docker/metadata-action@v5` → `latest`, `main`, `sha-<commit>` |
| Build & push | `docker/build-push-action@v5`, `cache-from/to: type=gha` |
| Vulnerability scan | `aquasecurity/trivy-action` → SARIF |
| SARIF upload | `github/codeql-action/upload-sarif@v3` → Security tab |
| Manifest validation | `kubectl apply -k k8s/ --dry-run=client` |

**Why no deploy job.** The requirement is an Action that *creates a new image when changes are made*. Deployment was prototyped and then removed: a GitHub-hosted runner cannot reach a `kind` cluster running on a laptop, so the job could only ever fail. Wiring it up properly needs either a cloud cluster with a stored `KUBECONFIG_DATA` secret or a self-hosted runner bound to a real cluster — both out of scope for a local assessment. The reasoning is documented in the workflow file rather than silently omitted.

---

## Problem 2 — Automation Scripts

Two of the four options: **System Health Monitor** and **Application Health Checker**.

### 2.1 `scripts/system-health-monitor.sh` (Bash)

Monitors CPU, memory, disk, and process count against configurable thresholds (80% / 80% / 85% / 300). Bash chosen because the script must run on a bare host with no interpreter guarantees.

- `set -euo pipefail` so partial failures don't get swallowed
- Per-metric functions, each independently reportable
- Timestamped output to stdout and `~/system-health.log`
- Cron-ready for 5-minute intervals

### 2.2 `scripts/app-health-checker.py` (Python)

HTTP uptime checker. Python chosen for `requests`, `urllib3` retry semantics, and clean JSON emission.

- Retries with exponential backoff via `HTTPAdapter` + `Retry`
- Latency measured with `time.perf_counter`
- Three-state classification: `up` (expected code), `degraded` (4xx), `down` (5xx/timeout/connection error)
- `--json` for machine consumption, human-readable otherwise
- Exit codes `0` / `1` / `2` so it drops straight into CI or a cron alert

```bash
$ python3 scripts/app-health-checker.py https://example.com --json
[
  {
    "url": "https://example.com",
    "status": "up",
    "http_code": 200,
    "latency_ms": 148.32,
    "timestamp": "2026-11-17T17:40:12Z",
    "error": null
  }
]
```

---

## Verification Evidence

Cluster state at submission (`kind` v1.36.1):

```
$ kubectl -n wisecow get pods -o wide
NAME                       READY   STATUS    RESTARTS   AGE
wisecow-59bb8668d4-2n57x   2/2     Running   0          4m11s
wisecow-59bb8668d4-djgbz   2/2     Running   0          3m58s
wisecow-59bb8668d4-hn62k   2/2     Running   0          4m29s

$ kubectl -n wisecow get svc,ingress,hpa,certificate
service/wisecow            ClusterIP   10.96.10.253   <none>   80/TCP,443/TCP
service/wisecow-headless   ClusterIP   None           <none>   4499/TCP
ingress.networking.k8s.io/wisecow   nginx   wisecow.local   80, 443
horizontalpodautoscaler.autoscaling/wisecow   cpu: 4%/70%, memory: 5%/80%   3   10   3
certificate.cert-manager.io/wisecow-tls      True    wisecow-tls
```

**HTTPS response**

```
$ curl -k https://localhost:8443
<pre> _______________________________________
/ "I'd love to go out with you, but the \
| man on television told me to stay     |
\ tuned."                               /
 ---------------------------------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||</pre>
```

**TLS handshake**

```
$ curl -kv https://localhost:8443 2>&1 | grep "SSL connection"
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519 / RSASSA-PSS
```

**Certificate SANs**

```
$ echo | openssl s_client -connect localhost:8443 -servername wisecow.local 2>/dev/null \
    | openssl x509 -noout -ext subjectAltName
X509v3 Subject Alternative Name: critical
    DNS:wisecow.local, DNS:wisecow.wisecow.svc.cluster.local
```

**TLS enforcement** — plain HTTP sent to the TLS port is refused:

```
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8443
400
```

**HPA live metrics**

```
$ kubectl top nodes
wisecow-control-plane   293m   2%   1029Mi   13%

$ kubectl -n wisecow top pods
wisecow-59bb8668d4-2n57x   4m   3Mi
wisecow-59bb8668d4-djgbz   6m   3Mi
wisecow-59bb8668d4-hn62k   5m   9Mi
```

**HPA scale-out under load** (`kubectl get hpa -w` while 40 concurrent request
loops ran against the service):

```
cpu:   4%/70%   memory: 5%/80%   REPLICAS 3   ...   idle
cpu:  20%/70%   memory: 6%/80%   REPLICAS 3   ...   load ramping
cpu: 294%/70%   memory: 7%/80%   REPLICAS 3   ...   threshold breached
cpu: 290%/70%   memory: 5%/80%   REPLICAS 7   ...   scaled 3 -> 7
```

Reproducer:

```bash
kubectl -n wisecow run loadgen --image=busybox:1.36 --restart=Never -- \
  sh -c 'for i in $(seq 1 40); do while true; do wget -q -O /dev/null http://wisecow/; done & done; wait'
kubectl -n wisecow delete pod loadgen
```

Worth noting *why* 40 concurrent loops produce a 294% spike: `wisecow.sh`
accepts one connection at a time per Pod (`nc -lN`), so the load does not
parallelise — it queues. The CPU cost is `fortune` and `cowsay` fork/exec per
request, not concurrent throughput. The HPA is reporting and reacting correctly;
the workload behind it is serial by design.

Screenshots for each of the above are in `docs/screenshots/`.

---

## Problems Encountered and Resolutions

| Symptom | Root cause | Fix |
|---|---|---|
| `cowsay: command not found` at runtime | Debian places it in `/usr/games`, absent from default `PATH` | `ENV PATH="/usr/games:${PATH}"` |
| `mkfifo: Permission denied` | `readOnlyRootFilesystem: true` blocked the FIFO in `/app` | Moved FIFO to `/tmp`, mounted `emptyDir` at `/tmp` |
| nginx sidecar `CrashLoopBackOff` | `/var/cache/nginx` not writable under read-only rootfs | `emptyDir` at `/var/cache/nginx` and `/var/run` |
| App container `CrashLoopBackOff`, log said `unexpected end of file` wanting `EOF` | `wisecow.sh` in the image was truncated — the heredoc was never closed | Rewrote the script, added `bash -n` as a pre-commit check, rebuilt and repushed |
| Pods kept running the old broken image after `kind load` | `imagePullPolicy: Always` — kubelet pulls from Docker Hub and ignores the loaded tarball | `docker push` before rollout restart |
| `kubectl apply -f k8s/` failed with `no matches for kind "Kustomization"` | `kustomization.yaml` was passed to `-f`, which treats it as a manifest | `kubectl apply -k k8s/` |
| HPA showed `cpu: <unknown>` | `kind` ships no metrics-server | Installed metrics-server, patched `--kubelet-insecure-tls` for self-signed kubelet certs |
| `docker run` failed with `port is already allocated` | A stale container still held 4499 | Test on a free port (`-p 14500:4499`) and clean up with `docker rm -f` |

The truncated-script episode is the one worth calling out: the local file passed syntax checks while the image carried an older broken copy, so every cluster-side fix looked ineffective. It's why the verification order in the README is *build → run locally → push → deploy*, not *build → deploy*.

---

## What I'd Do Differently / Next

| Area | Improvement |
|---|---|
| Deployment automation | Add the `deploy` job back against a real cluster (GKE/EKS) or a self-hosted runner, gated on `main` |
| GitOps | ArgoCD or Flux instead of imperative `kubectl apply` |
| Certificate | Replace the self-signed issuer with Let's Encrypt once a real domain and ingress IP exist |
| Observability | Prometheus + Grafana; the health-check script becomes a blackbox exporter probe instead of a cron job |
| Policy | Kyverno or OPA Gatekeeper to enforce the security context at admission rather than by convention |
| Secrets | External Secrets Operator or Sealed Secrets — the CI currently uses long-lived Docker Hub tokens |
| Testing | `kubeconform` + `kind` in CI to actually apply manifests to a throwaway cluster, instead of `--dry-run` only |

---

## Checklist

- [x] Dockerfile builds, runs, passes healthcheck
- [x] K8s manifests apply cleanly; 3 pods `2/2 Running`
- [x] Service exposes the app; Ingress terminates TLS
- [x] HPA scales on CPU and memory, metrics confirmed
- [x] GitHub Actions builds, scans, and publishes on push
- [x] Trivy integrated, SARIF uploaded
- [x] Two automation scripts, both executed
- [x] README + this report
- [ ] Repository set to private
- [ ] `nyrahul` granted access

---

**Vaibhav Godse** — godsevaibhav@gmail.com
