# Full-Stack Example: serialize → publish → deploy → serve → verify

**Fork-authored document.** This walkthrough belongs to the
[TylrDn/tensorizer](https://github.com/TylrDn/tensorizer) deployment layer, not to
upstream [coreweave/tensorizer](https://github.com/coreweave/tensorizer). The
`tensorizer` library itself, and every throughput number quoted in the upstream
sections of the top-level [README](../README.md), are CoreWeave's.

It stitches together the pieces that the other fork docs cover individually
([overview](overview.md), [SUNK](sunk.md), [tensorizer](tensorizer.md),
[vLLM](vllm.md), [observability](observability.md), [CI/CD](cicd.md),
[GitOps](gitops.md), [security](security.md)) into one path:

```
serialize a model  →  publish to S3/HTTP  →  deploy with Helm or ArgoCD
        →  vLLM loads the tensorized weights  →  verify with curl + metrics
```

Every command, flag and value below is quoted from a file in this repository.
Where a file's contents have **not** been validated against a live cluster or a
released upstream version, that is called out explicitly rather than smoothed
over.

---

## 0. Prerequisites

| Requirement | Why | Notes |
| --- | --- | --- |
| Kubernetes cluster with a GPU node pool | vLLM serving | The chart in `helm/tensorizer-vllm` does **not** set `resources.limits."nvidia.com/gpu"`; you must schedule onto GPU nodes yourself (nodeSelector/taints) or patch the chart. See [Known gaps](#known-gaps-in-this-layer). |
| S3-compatible bucket + credentials | Hosting `.tensors` artifacts | CoreWeave Object Storage, AWS S3, MinIO, etc. |
| Python 3.10+ with `tensorizer`, `torch`, `transformers` | Step 1 | `python -m pip install -e .` from the repo root, plus `examples/requirements.txt`. |
| `boto3` | Optional S3 upload inside the example script | `examples/tensorizer/serialize_and_load.py` imports it lazily inside `upload_to_s3()`. |
| Helm 3 | Step 3 | `.github/workflows/build-and-deploy.yml` pins `v3.12.3` via `azure/setup-helm`. |
| `kubectl` | Steps 3 and 5 | Same workflow pins `v1.28.3` via `azure/setup-kubectl`. |
| ArgoCD (optional) | Step 3b | Only if you want the GitOps path — see [gitops.md](gitops.md). |
| Slurm / SUNK (optional) | Batch-driven serialization | Only if you serialize as a Slurm job — see [sunk.md](sunk.md) and [schedule-k8s-with-slurm.md](schedule-k8s-with-slurm.md). |

---

## 1. Serialize a model

Three real scripts exist in this repo. Pick the one that matches your case.

### 1a. Smallest end-to-end demo — `examples/tensorizer/serialize_and_load.py`

This is a fork-added script. It downloads `sshleifer/tiny-gpt2`, serializes it
with `TensorSerializer.write_module()`, optionally uploads to S3, and then loads
it back with `TensorDeserializer(..., lazy_load=True, num_readers=N)`.

Its real arguments, as defined in the file's `argparse` block:

| Flag | Default | Meaning (from the script) |
| --- | --- | --- |
| `--local-only` | off | Do not start the built-in HTTP server; load from the local `tiny-gpt2.tensors` path. |
| `--bucket` | `""` | S3 bucket. If set, the script uploads via `boto3` and loads from `s3://<bucket>/<key>`. |
| `--key` | `tiny-gpt2.tensors` | S3 object key. |
| `--device` | `cpu` | Device passed to `TensorDeserializer`. |
| `--num-readers` | `4` | Reader threads passed to `TensorDeserializer`. |

```bash
# purely local round-trip
python examples/tensorizer/serialize_and_load.py --local-only

# serialize, upload to S3, then load from the s3:// URI onto a GPU
python examples/tensorizer/serialize_and_load.py \
  --bucket my-bucket \
  --key models/tiny-gpt2.tensors \
  --device cuda \
  --num-readers 8
```

With neither `--local-only` nor `--bucket`, the script starts a
`ThreadingHTTPServer` on port `8000` and loads from
`http://localhost:8000/tiny-gpt2.tensors`.

The output file is written to `tiny-gpt2.tensors` in the current working
directory (`out_path = "tiny-gpt2.tensors"` in `main()`).

### 1b. A real model straight to S3 — `examples/serialize.py`

Upstream's script. It has **no** command-line flags; you edit the constants at
the top of the file:

```python
model_ref = "EleutherAI/gpt-j-6B"
# For less intensive requirements, swap above with the line below:
# model_ref = "EleutherAI/gpt-neo-125M"
model_name = model_ref.split("/")[-1]
# Change this to your S3 bucket.
s3_bucket = "bucket"
s3_uri = f"s3://{s3_bucket}/{model_name}.tensors"
```

It then does `TensorSerializer(s3_uri)` → `write_module(model)` → `close()`, so
serialization and upload are a single streaming write to S3:

```bash
python examples/serialize.py
```

### 1c. HF models, diffusers pipelines, and encryption — `examples/hf_serialization.py`

Upstream's fuller helper (`df_main` / `hf_main`). It reads S3 configuration from
the environment rather than from constants:

```bash
export S3_ACCESS_KEY_ID=...
export S3_SECRET_ACCESS_KEY=...
export S3_ENDPOINT_URL=...   # optional; falls back to CoreWeave's default
python examples/hf_serialization.py --help
```

If `S3_ENDPOINT_URL` is unset it falls back through
`stream_io._infer_credentials(...)` and finally to
`stream_io.default_s3_read_endpoint`, which is
`accel-object.ord1.coreweave.com` (`tensorizer/stream_io.py`).

---

## 2. Publish the artifact

`tensorizer` accepts, per the docstring of `tensorizer.stream_io.open_stream`:

* a local **file path**,
* an **`http(s)://` URL** (read-only, `"rb"`),
* an **`s3://` URI** (`"rb"`, `"wb[+]"`, `"ab[+]"`).

So the URI form is plain `s3://<bucket>/<key>` — for example
`s3://my-bucket/models/tiny-gpt2.tensors`, which is exactly the default carried
in `helm/tensorizer-vllm/values.yaml`, `k8s/knative-service.yaml`, and
`examples/vllm/run_vllm_tensorized.sh`.

If you serialized locally (step 1a with `--local-only`), upload the file
yourself:

```bash
aws s3 cp tiny-gpt2.tensors s3://my-bucket/models/tiny-gpt2.tensors
```

**Credential handling is split across two consumers, and they do not read the
same variables:**

* The `tensorizer` **library** takes `s3_access_key_id` / `s3_secret_access_key`
  arguments, or parses `~/.s3cfg` when they are omitted
  (`_infer_credentials` in `tensorizer/stream_io.py`). It does not read
  `AWS_ACCESS_KEY_ID` itself.
* The **Helm chart and Knative manifest** in this fork inject
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` into the vLLM container from a
  Kubernetes Secret. Those are the boto3-style names the serving container is
  expected to consume.

Plan your Secret accordingly, and see [security.md](security.md) for how those
secrets are (and are not) protected.

---

## 3. Deploy

### 3a. Direct Helm install

The chart lives at `helm/tensorizer-vllm/`. `Chart.yaml`:

```yaml
apiVersion: v2
name: tensorizer-vllm
version: 0.1.0
appVersion: "0.1.0"
description: Deploy vLLM serving tensorized models
```

The chart has exactly **four** values. There is no `values.schema.json` and no
`_helpers.tpl`; resource names come from `.Release.Name`.

| Value | Default (`values.yaml`) | Used by | Must you set it? |
| --- | --- | --- | --- |
| `image` | `vllm/vllm:0.2.2` | `templates/deployment.yaml` → container `image` | Yes in practice — pin a vLLM image you have verified, and one that supports tensorizer loading. |
| `modelURI` | `s3://my-bucket/models/tiny-gpt2.tensors` | `templates/deployment.yaml` → `args: ["serve", "--model", "<modelURI>", "--tensorizer"]` | Yes — this is the artifact from step 2. |
| `host` | `vllm.example.com` | `templates/ingress.yaml` → `spec.rules[0].host` | Yes if you use the Ingress. The Ingress is rendered unconditionally; there is no `ingress.enabled` toggle. |
| `s3.secretName` | `""` (empty) | `templates/deployment.yaml` — gates the whole `env:` block | Yes for private buckets. When empty, **no** credential env vars are injected at all. |

The Secret referenced by `s3.secretName` must expose exactly these two keys, as
written in `templates/deployment.yaml`:

```bash
kubectl create secret generic s3-credentials \
  --namespace tensorizer \
  --from-literal=accessKeyId="$AWS_ACCESS_KEY_ID" \
  --from-literal=secretAccessKey="$AWS_SECRET_ACCESS_KEY"
```

What the three templates render:

* `templates/deployment.yaml` — one `apps/v1` Deployment, `replicas: 1`,
  a single container named `vllm`, `containerPort: 8000`, label
  `app: {{ .Release.Name }}`. No probes, no resource requests/limits, no
  `serviceAccountName`.
* `templates/service.yaml` — a `v1` Service (default type, i.e. `ClusterIP`)
  with `port: 80` → `targetPort: 8000`, selecting `app: {{ .Release.Name }}`.
* `templates/ingress.yaml` — a `networking.k8s.io/v1` Ingress routing
  `host: {{ .Values.host }}`, path `/` (`pathType: Prefix`) to the Service on
  port `80`. No `ingressClassName`, no TLS block.

Install:

```bash
helm lint helm/tensorizer-vllm

helm upgrade --install tensorizer helm/tensorizer-vllm \
  --namespace tensorizer --create-namespace \
  --set image=ghcr.io/<you>/vllm:<tag> \
  --set modelURI=s3://my-bucket/models/tiny-gpt2.tensors \
  --set host=vllm.example.com \
  --set s3.secretName=s3-credentials
```

Render without installing to inspect the manifests first:

```bash
helm template tensorizer helm/tensorizer-vllm --set s3.secretName=s3-credentials
```

`helm lint helm/tensorizer-vllm` passes on this chart (the only message is the
informational `icon is recommended`).

The CI workflow performs the equivalent install itself
(`.github/workflows/build-and-deploy.yml`):

```yaml
helm upgrade --install tensorizer helm/tensorizer-vllm \
  --set image=example/vllm:${{ github.sha }} \
  --namespace test \
  --create-namespace
```

Note that CI overrides only `image` — it deploys with the placeholder
`modelURI` and no S3 secret. See [cicd.md](cicd.md).

### 3b. GitOps with ArgoCD

`gitops/argocd/app.yaml` points an ArgoCD `Application` at
`helm/tensorizer-vllm` with `prune: true` and `selfHeal: true`. Read
[gitops.md](gitops.md) before applying it — you must change `repoURL`,
`targetRevision` and `destination.namespace` for your own environment, and
automated pruning has real consequences.

### 3c. Serverless with Knative

`k8s/knative-service.yaml` is a standalone alternative to the chart: a
`serving.knative.dev/v1` Service named `tensorizer-knative`, annotated
`autoscaling.knative.dev/minScale: "0"` (scale-to-zero), running
`vllm/vllm:0.2.2` with the same `serve --model … --tensorizer` args and pulling
`accessKeyId` / `secretAccessKey` from a Secret hard-coded as `s3-credentials`.
Values there are literal, not templated — edit the file before applying:

```bash
kubectl apply -f k8s/knative-service.yaml
```

Scale-to-zero is the case where tensorizer's fast loading matters most, which is
the rationale CoreWeave gives in the upstream README.

Also apply the cluster-side guardrails if you want them
(see [security.md](security.md)):

```bash
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/networkpolicy.yaml
```

---

## 4. vLLM serving

`examples/vllm/run_vllm_tensorized.sh` is the local (non-Kubernetes) smoke test.
Its full behaviour, quoted from the file:

```bash
MODEL_URI=${1:-s3://my-bucket/models/tiny-gpt2.tensors}
PORT=${PORT:-8000}

vllm serve --model "$MODEL_URI" --tensorizer --port "$PORT" &
SERVER_PID=$!

sleep 5
curl -sS http://localhost:$PORT/generate -d '{"prompt":"Hello","max_tokens":8}'

kill $SERVER_PID
```

| Input | Default | Notes |
| --- | --- | --- |
| `$1` → `MODEL_URI` | `s3://my-bucket/models/tiny-gpt2.tensors` | First positional argument. |
| `PORT` (env) | `8000` | Matches the `containerPort` used by the chart and the Knative service. |

```bash
bash examples/vllm/run_vllm_tensorized.sh s3://my-bucket/models/tiny-gpt2.tensors
PORT=8001 bash examples/vllm/run_vllm_tensorized.sh /path/to/model.tensors
```

The script sets `set -euo pipefail`, sleeps a fixed 5 seconds rather than polling
for readiness, and kills the server afterwards — it is a smoke test, not a
supervisor.

> **Honest caveat about `--tensorizer`.** The `serve --model <uri> --tensorizer`
> argument form appears in this fork's Helm deployment template, its Knative
> manifest, and this script, all of which were authored together. It has **not**
> been executed against a live vLLM release as part of this repository's tests,
> and no CI job runs it. Before relying on it, check the tensorizer loading flags
> documented for the exact vLLM version you pin in `values.image`, and adjust the
> `args` list in `helm/tensorizer-vllm/templates/deployment.yaml` (and
> `k8s/knative-service.yaml`) to match. Treat the pinned `vllm/vllm:0.2.2` as a
> placeholder, not a recommendation.

---

## 5. Verify

**Reachability.** With the chart installed, the Service listens on port 80:

```bash
kubectl -n tensorizer port-forward svc/tensorizer 8000:80
curl -sS http://localhost:8000/generate -d '{"prompt":"Hello","max_tokens":8}'
```

Through the Ingress instead, use the host you set in `values.host`.

**Pod health.** There are no readiness/liveness probes in the chart, so a Pod
reports `Running` before the model has finished streaming. Watch the logs to see
loading progress and confirm the weights came from your URI:

```bash
kubectl -n tensorizer get pods -l app=tensorizer
kubectl -n tensorizer logs -l app=tensorizer -f
```

**Metrics.** Per [observability.md](observability.md), vLLM exposes Prometheus
metrics on `/metrics` on port `8000`, Prometheus must be configured to scrape the
vLLM service on that port, and Loki logs are searchable by `app=vllm`. Metrics
worth checking after a deploy:

* `vllm_engine_execution_time` (named explicitly in `observability.md`)
* GPU utilisation / framebuffer: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`
  (from `examples/observability/grafana/README.md`)
* Network receive throughput: `container_network_receive_bytes_total` — this is
  the one that shows the model actually streaming in from object storage.

A local Prometheus + Grafana stack is described in
[`examples/observability/grafana/README.md`](../examples/observability/grafana/README.md).

> **On speed.** Do not treat any number you see in the top-level README as a
> target this stack has hit. The `~5GB/s` GPT-J figure and the letter-value
> deserialization plot are CoreWeave's published benchmarks (release 2.5.0
> methodology, `examples/benchmark_buffer_size`). They have **not** been
> independently reproduced in this fork, and this deployment layer ships no
> benchmark of its own. Measure your own cluster.

---

## Troubleshooting

| Symptom | Likely cause | Where to look / what to do |
| --- | --- | --- |
| Pod `CrashLoopBackOff` immediately, logs mention credentials or `403`/`AccessDenied` | `s3.secretName` left at its `""` default, so the whole `env:` block was skipped | `helm get manifest <release>` — if there is no `env:` on the container, re-install with `--set s3.secretName=...`. |
| Secret exists but creds still missing | Wrong key names | The Deployment reads keys `accessKeyId` and `secretAccessKey` exactly. `kubectl get secret <name> -o jsonpath='{.data}'`. |
| `NoSuchKey` / 404 fetching the model | `modelURI` still the placeholder `s3://my-bucket/models/tiny-gpt2.tensors` | Set `--set modelURI=...`; confirm the object exists (`aws s3 ls`). |
| Unknown/unsupported argument at vLLM startup | The `--tensorizer` arg form does not match your pinned vLLM version | See the caveat in [step 4](#4-vllm-serving); edit the `args` list in the Deployment template and re-lint. |
| Pod stuck `Pending` | No GPU node available, or no GPU request to schedule on | The chart sets no `resources`, `nodeSelector` or tolerations. `kubectl describe pod` and add scheduling constraints. |
| Ingress returns 404 / never routes | No `ingressClassName` and no TLS in `templates/ingress.yaml`; controller may ignore it | Add the class your controller requires, or use `kubectl port-forward` for verification. |
| Model loads but egress to S3 is blocked | `k8s/networkpolicy.yaml` allows egress only on TCP/443, and only to pods in namespaces (`namespaceSelector: {}`) — not to arbitrary external endpoints | See [security.md](security.md). Non-443 or off-cluster endpoints need an explicit rule. |
| Requests time out right after deploy | No readiness probe; the model is still streaming | Watch `kubectl logs -f` until loading completes. |
| ArgoCD keeps reverting your manual `kubectl edit` | `selfHeal: true` | Expected. Change Git, not the cluster — [gitops.md](gitops.md). |
| ArgoCD deleted resources you wanted to keep | `prune: true` | Expected. [gitops.md](gitops.md). |
| CI deploys a release with the placeholder model | `build-and-deploy.yml` overrides only `image` | [cicd.md](cicd.md). |

---

## Known gaps in this layer

Recorded here so a reviewer does not have to discover them by deploying:

* No GPU resource requests/limits, `nodeSelector`, or tolerations in the chart.
* No liveness or readiness probes, and `replicas` is fixed at `1`.
* No `serviceAccountName` on the Deployment, so `k8s/rbac.yaml`'s
  `tensorizer-sa` is **not** actually bound to the workload the chart creates.
* The Ingress renders unconditionally, with no class and no TLS.
* `k8s/networkpolicy.yaml` selects `app: tensorizer`, whereas the chart labels
  pods `app: {{ .Release.Name }}` — the policy only applies if you name the
  release `tensorizer`.
* `docs/img/architecture.svg` is a four-box sketch (Dev → CI/CD → Object Storage
  → K8s/vLLM, plus Grafana). It is directionally right but predates and does not
  depict SUNK/Slurm, ArgoCD, Knative, or the NetworkPolicy/RBAC assets. Read it
  as a sketch, not as an inventory.
* Nothing in this layer has been executed against a live GPU cluster as part of
  this repository, and no automated test covers the chart beyond `helm lint`.
