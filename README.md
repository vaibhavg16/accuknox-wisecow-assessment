# Wisecow on Kubernetes

This is my submission for the AccuKnox DevOps trainee assessment. Two problems: get the
[wisecow](https://github.com/nyrahul/wisecow) app running on Kubernetes with TLS, and write two
system scripts.

Everything here was run against a local `kind` cluster and is reproducible. The parts that broke
along the way are documented too, because I'd rather you see how I work than a cleaned-up version
of it.

- Image: `docker.io/vaibhav161202/wisecow:latest`
- Cluster tested on: kind v1.36.1, single control-plane node
- Date: November 2026

---

## Getting it running

```bash
git clone https://github.com/vaibhavg16/accuknox-wisecow-assessment.git
cd accuknox-wisecow-assessment

kind create cluster --name wisecow

# cert-manager first, or the Certificate/ClusterIssuer manifests won't apply
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

# the HPA needs this; kind has no metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl apply -k k8s/
kubectl -n wisecow rollout status deployment/wisecow --timeout=180s
```

Three pods should come up at `2/2`: the app container and an nginx sidecar in each.

```bash
kubectl -n wisecow port-forward svc/wisecow 8443:443 &
curl -k https://localhost:8443
```

That prints a fortune inside a cow. If it doesn't, jump to the troubleshooting section.

---

## How it fits together

The app itself is a Bash script that opens a netcat listener on 4499 and serves plain HTTP. It has
no TLS support, and I didn't want to rewrite someone else's app to add it, so TLS is terminated by
an nginx sidecar in the same pod. The sidecar listens on 8443, proxies to `127.0.0.1:4499`.

```
client --HTTPS--> Ingress :443 --> Service :443 --> nginx sidecar :8443
                                                        |
                                                   (TLS ends here)
                                                        v
                                                  wisecow :4499
```

Certificates come from cert-manager using a self-signed ClusterIssuer. Let's Encrypt can't validate a hostname on a cluster that only exists on my laptop. There's no public
DNS and no way for the ACME challenge to reach me. On a real cluster with a real domain, swapping
`issuerRef` to `letsencrypt-prod` is a one-line change.

Things I hardened that weren't strictly required: non-root with a fixed UID of 10001, read-only
root filesystem with `emptyDir` for `/tmp`, all capabilities dropped, `automountServiceAccountToken:
false`.

The sidecar bit me during testing. nginx writes to `/var/cache/nginx` and won't start with a
read-only root. Needed two more `emptyDir` mounts before it stayed up.

---

## The CI/CD setup

`.github/workflows/ci-cd.yaml`, three jobs:

**validate** runs first and gates everything. It checks the entrypoint script is actually complete,
renders the kustomization, validates it with kubeconform, and fails if any certificate material got
committed. Nothing publishes until this passes.

**build** runs Trivy, publishes SARIF to the Security tab, builds with Buildx, pushes to Docker Hub,
then starts the image it just built and curls it for a real response before trusting the tag.

**deploy** runs on a self-hosted runner. GitHub's hosted runners can't route to a kind cluster on my
machine, so `runs-on: self-hosted` isn't a preference, it's the only way this works. It decodes a
kubeconfig secret, rewrites the image tag to the commit's sha, applies the manifests, waits for
rollout, then smoke-tests the pod twice: curl against the app on 4499, wget with
`--no-check-certificate` against the sidecar on 8443.

Pull requests build but don't publish, so a branch can't overwrite `latest`.

One wrinkle worth knowing: deploy pins the live Deployment to a sha tag while the committed manifest
stays on `:latest`. Any manual `kubectl apply -k k8s/` will reset it. That's a deliberate trade. Git records intent; the cluster records what actually shipped.

---

## Problem 2: the two scripts

### `scripts/system-health-monitor.sh`

Checks CPU, memory, disk and process count against thresholds of 80/80/85/300. Alerts print to the
console and append to `~/system-health.log`.

Bash, because it has to run on a bare host with nothing installed. `set -euo pipefail`, one
function per metric so a bad parse in one doesn't take out the others, and a `$HOME`-relative log
path so it runs unprivileged.

Cron-ready:

```
*/5 * * * * /path/to/system-health-monitor.sh
```

### `scripts/app-health-checker.py`

Takes URLs, checks HTTP status codes, reports up / degraded / down.

- `up`: got an expected code (200 by default)
- `degraded`: 4xx
- `down`: 5xx, timeout, or connection refused

Retries with exponential backoff, measures latency, `--json` for machine consumption, exit codes
0/1/2 so it drops straight into cron or CI.

```
$ python3 scripts/app-health-checker.py https://example.com
✅ https://example.com → UP (HTTP 200, 60.6ms)
```

I picked one in each language on purpose — the brief allows either, and this shows both.

---

## What broke, and what I'd do differently

Keeping this section because a submission where nothing went wrong usually means nothing was
actually run.

**The script was truncated in the image.** `wisecow.sh` had an unclosed heredoc, so the container
crashed on startup with `syntax error: unexpected end of file, wanted 'EOF'`. My local copy was fine. It was the copy inside the built image that was broken. Cost me a couple of hours chasing the
cluster before I thought to check the image itself.

**`imagePullPolicy: Always` ignores `kind load`.** I kept loading the new image into the cluster and
the pods kept running the old one, because the kubelet pulls from Docker Hub and never looks at the
local tarball. The fix is `docker push`, not `kind load`.

**The smoke test used wget.** The runtime image is debian-slim, which ships curl for the healthcheck
but no wget. The pipeline went red on a healthy container. Now it's curl in the app container, wget
in the Alpine sidecar.

**`kubectl apply -f k8s/`** — that passes `kustomization.yaml` to `-f`, which tries to read it as a
manifest and fails with `no matches for kind "Kustomization"`. It's `-k`.

**HPA showed `cpu: <unknown>`** for a while because kind doesn't ship metrics-server.

If I kept going: ArgoCD instead of imperative `kubectl apply`, Prometheus instead of curl checks,
Kyverno to enforce the security context at admission instead of by convention. And a `kind` cluster
in CI so the manifests get applied to something real rather than just dry-run.

---

## Troubleshooting

| What you see | Why | Fix |
|---|---|---|
| `no matches for kind "Kustomization"` | used `-f` | use `-k` |
| `no matches for kind "Certificate"` | cert-manager not installed yet | install it first |
| `ImagePullBackOff` | local image never pushed | `docker push`, then restart |
| Pods running an old build | `imagePullPolicy: Always` | push, don't rely on `kind load` |
| `cpu: <unknown>` in HPA | no metrics-server | install it, patch `--kubelet-insecure-tls` |
| sidecar `CrashLoopBackOff` | read-only root, nginx needs `/var/cache` | check the `emptyDir` mounts |
| `mkfifo: Permission denied` | `/tmp` not writable | check the `tmp` mount exists |
| `wrong version number` | spoke HTTPS to an HTTP port | 4499 is plain HTTP, 8443 is TLS |
| nothing on 8443 | port-forward died | run it in its own terminal, don't background it |

---

## Repo layout

```
wisecow.sh              the app
Dockerfile
k8s/                    9 manifests + kustomization (apply with -k)
scripts/                the two Problem 2 scripts
docs/SUBMISSION_REPORT.md   longer write-up with test output
```

---

Vaibhav Godse / godsevaibhav@gmail.com

