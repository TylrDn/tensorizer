# Security Posture of the Deployment Layer

**Fork-authored document, and the canonical one for this topic.** It describes
the security properties of the Kubernetes/Helm/GitOps layer added by
[TylrDn/tensorizer](https://github.com/TylrDn/tensorizer). It is deliberately
explicit about what is **not** hardened.

Related pages:

* [`security/policy-notes.md`](../security/policy-notes.md) — illustrative
  Role/NetworkPolicy snippets and image-signing notes. Those snippets are
  *examples*, not the manifests this repo ships.
* [`docs/cks.md`](cks.md) — CKS-objective-oriented checklist.
* [`docs/encryption.md`](encryption.md) — upstream CoreWeave documentation for
  `tensorizer`'s tensor-weight encryption.
* [`docs/full-stack-example.md`](full-stack-example.md) — the deployment path
  these controls apply to.

> Nothing here has been validated by a penetration test, a policy audit, or a
> live cluster deployment. Treat it as a description of the committed manifests
> and their gaps, not as an assurance.
>
> The manifests **render and validate**: `helm lint`, `helm template` with
> defaults and with every feature enabled, and `kubeconform -strict` over both
> renders plus the raw manifests, all run in CI
> (`.github/workflows/manifests.yml`). That is the whole of the evidence. It
> says the YAML is well-formed and schema-valid and carries the fields claimed
> below. It says nothing about whether this serves a model on a GPU.

---

## 1. RBAC — what is actually granted

`k8s/rbac.yaml` contains three objects, all namespace-scoped:

| Object | Name | Content |
| --- | --- | --- |
| ServiceAccount | `tensorizer-sa` | No secrets, no image pull secrets, no annotations (so no cloud workload-identity binding). |
| Role | `tensorizer-role` | Exactly one rule: `apiGroups: [""]`, `resources: ["pods"]`, `verbs: ["get", "list"]`. |
| RoleBinding | `tensorizer-rolebinding` | Binds `tensorizer-sa` to `tensorizer-role`. |

This is a genuinely minimal grant: read-only visibility of Pods in one
namespace. No `create`, no `exec`, no secret access, no cluster-scoped rights.

**Fixed:**

* The RoleBinding's subject now carries an explicit `namespace:`, and every
  object in the file is explicitly namespaced. Previously the subject resolved
  to whichever namespace the RoleBinding landed in, so applying the file across
  namespaces bound the Role to an account that was not there.
* **The chart now sets `serviceAccountName`.** It creates its own
  ServiceAccount (named for the release) and runs the Pod under it, so the
  account the workload uses is no longer the namespace `default`.
* `automountServiceAccountToken: false` is set on the ServiceAccount and on the
  Pod spec, in the chart and in `k8s/rbac.yaml`.

**Deliberate design note.** The chart's ServiceAccount has **no Role bound to
it at all**. A serving container talks to object storage and to its callers,
never to the API server, so it is granted nothing rather than granted a little.
`k8s/rbac.yaml` remains for deployments that do want the read-only pods
`get`/`list` grant: set `serviceAccount.create=false` and
`serviceAccount.name=tensorizer-sa`.

---

## 2. NetworkPolicy — the posture and its holes

`k8s/networkpolicy.yaml` defines `tensorizer-allow`:

```yaml
spec:
  podSelector:
    matchLabels:
      app: tensorizer
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 8000
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 443
```

Read literally:

* **Ingress:** TCP/8000 only — the vLLM port — but from pods in **any**
  namespace (`namespaceSelector: {}` matches all namespaces). This is
  cluster-wide, not namespace-scoped, access.
* **Egress:** TCP/443 only, and again only to pods in cluster namespaces.

**Fixed:**

* **The selector mismatch is gone.** The chart now ships its own
  NetworkPolicy (`helm/tensorizer-vllm/templates/networkpolicy.yaml`),
  templated from the same helper that produces the Deployment's pod labels, so
  the selector cannot drift from what it protects. A CI step asserts the two
  agree — see `.github/workflows/manifests.yml`. It is off by default
  (`networkPolicy.enabled=false`) because the egress rules need your bucket's
  addresses to be useful.
* The standalone `k8s/networkpolicy.yaml` keeps the `app: tensorizer` selector,
  and `k8s/knative-service.yaml` now carries that label, so the raw-manifest
  path selects something.
* **DNS egress added** (UDP/53 and TCP/53 to `kube-system`) in both.
* **External egress added.** Both now carry an `ipBlock` egress rule for
  off-cluster object storage. The standalone file excludes the cloud metadata
  endpoint (`169.254.169.254/32`) and the RFC1918 ranges, so a compromised Pod
  cannot mint credentials from the instance metadata service. The chart's rule
  is empty by default: set `networkPolicy.egressIPBlocks` to your bucket's
  ranges.
* **Ingress is restricted to the ingress-controller namespace**
  (`kubernetes.io/metadata.name: ingress-nginx` by default) rather than every
  namespace in the cluster.

**Still true:** NetworkPolicy is enforced only if your CNI implements it. On a
CNI that ignores NetworkPolicy these files are inert and provide zero
protection.

---

## 3. Secret handling

### S3 credentials

Two consumers, two different variable conventions — worth internalising:

* The `tensorizer` **library** takes `s3_access_key_id` / `s3_secret_access_key`
  arguments, or falls back to parsing `~/.s3cfg` (`_infer_credentials` in
  `tensorizer/stream_io.py`). `examples/hf_serialization.py` reads
  `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` and `S3_ENDPOINT_URL` from the
  environment and passes them down.
* The **serving manifests** inject boto3-style names. Both
  `helm/tensorizer-vllm/templates/deployment.yaml` and
  `k8s/knative-service.yaml` map Secret keys `accessKeyId` and
  `secretAccessKey` to env vars `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

What is good: no credential is committed to this repository. The chart gates the
whole `env:` block behind `{{- if .Values.s3.secretName }}`, and `values.yaml`
ships `s3.secretName: ""`, so the default install injects nothing.

What is not:

* **The Knative manifest hard-codes the Secret name `s3-credentials`.** It is not
  parameterised.
* Credentials land in the container **environment**, where they are visible to
  anything that can read `/proc/<pid>/environ` in the container, and to anyone
  with `kubectl describe`-level access to the Pod spec. A projected volume, or
  short-lived credentials via a cloud identity provider, is stronger.
* There is **no** External Secrets / Sealed Secrets / Vault integration in the
  repo. `docs/cicd.md` states secrets "are provided via External Secrets"; that
  describes an intended design, not something committed here.
* The ArgoCD Application (`gitops/argocd/app.yaml`) sets no Helm values, so the
  Secret must be created out-of-band in the destination namespace. That is the
  correct instinct — but it means the Secret's lifecycle is unmanaged and
  undocumented outside this page.
* **CI holds a full kubeconfig.** `.github/workflows/build-and-deploy.yml` writes
  `secrets.KUBECONFIG_DATA` to `~/.kube/config`, giving the workflow whatever
  rights that kubeconfig carries. Scope that credential to a single namespace
  with a dedicated ServiceAccount; a cluster-admin kubeconfig in GitHub Actions
  is a large blast radius.

### Encryption keys

`tensorizer` can encrypt tensor weights (XSalsa20-Poly1305, 256-bit keys) — see
upstream's [encryption documentation](encryption.md), which also states the
scope: **only tensor weights are encrypted**, not the metadata or module
structure.

This deployment layer provides **no** key management. Nothing in `helm/`, `k8s/`,
or `gitops/` mounts, references, or passes an encryption key, and none of the
example scripts used in the deployment path
(`examples/tensorizer/serialize_and_load.py`,
`examples/vllm/run_vllm_tensorized.sh`) enables encryption. If you serialize with
encryption, wiring the key into the serving container is work you must do
yourself — and the same env-var caveats above apply.

---

## 4. Image provenance and scanning — reality vs. aspiration

**What actually runs.** `.github/workflows/build-and-deploy.yml`, on pushes to
`main`:

1. `docker build -t example/vllm:${{ github.sha }} .`
2. A Trivy scan: `aquasecurity/trivy-action` with
   `image-ref: example/vllm:${{ github.sha }}`
3. `docker/login-action` against `ghcr.io`
4. `docker push example/vllm:${{ github.sha }}`
5. `helm upgrade --install` into namespace `test`

Good: all five third-party actions are pinned to full commit SHAs, not floating
tags — that is meaningful supply-chain hygiene.

**Fixed:**

* **The Trivy step is now blocking**: `exit-code: '1'` with
  `severity: 'CRITICAL,HIGH'` and `ignore-unfixed: true`. A critical or high
  vulnerability with an available fix now fails the job before the image is
  pushed or deployed. Unfixable findings do not wedge every deploy, since this
  pipeline cannot action them.
* **The image tag now names the registry it is pushed to.** It was tagged
  `example/vllm:<sha>` while the login targeted `ghcr.io`, so the push resolved
  to Docker Hub rather than the registry that had been authenticated. A single
  `IMAGE` environment variable — `ghcr.io/<owner>/<repo>/vllm:<sha>` — is now
  used by the build, the scan, the push and the Helm upgrade.

**Still true:** build and deploy remain one job. The scan gates the push, but
there is no separate approval between scanning and deploying to the cluster.

**What is aspirational, not implemented.** `security/policy-notes.md` and
`docs/cks.md` describe Cosign signing, Syft SBOMs, and admission controllers
(OPA/Gatekeeper or Kyverno) verifying signatures. **None of that exists in this
repository.** There is no signing step, no SBOM generation, no attestation, and
no admission policy manifest. Those pages are a target state.

**Linting.** `.pre-commit-config.yaml` runs `black` 24.3.0 and `isort` 5.13.2
locally, excluding `*_pb2.py` and `ATTIC/`. No GitHub Actions workflow runs them,
so formatting is enforced only for contributors who install the pre-commit hook.
(The README badge that implied CI-enforced linting was removed for this reason.)

**Tests.** `.github/workflows/test.yml` runs upstream's Python unit tests on
every push and pull request.

`.github/workflows/manifests.yml` now validates the deployment layer on every
change to `helm/`, `k8s/` or `gitops/`. It runs `helm lint`, renders the chart
with defaults and again with every feature enabled, validates both renders plus
the raw manifests with `kubeconform -strict`, and then asserts the specific
regressions this document was written about: that the NetworkPolicy's selector
matches the Deployment's pod labels, that the Pod spec carries a
`serviceAccountName`, a non-root `securityContext`, dropped capabilities, a GPU
limit and all three probes, and that the Ingress declares an `ingressClassName`
and a TLS block. Previously nothing in CI exercised these files before
`helm upgrade --install` ran against a live cluster — which is after the image
has already been pushed.

---

## 5. Pod-level hardening

Both `helm/tensorizer-vllm/templates/deployment.yaml` and
`k8s/knative-service.yaml` now set the following. The chart's values are the
defaults, so an install with no overrides is hardened.

**Present:**

* `securityContext` at both pod and container level: `runAsNonRoot`,
  `runAsUser`/`runAsGroup`/`fsGroup` 1000, `allowPrivilegeEscalation: false`,
  `privileged: false`, `capabilities.drop: ["ALL"]`, and
  `readOnlyRootFilesystem: true`
* `seccompProfile: RuntimeDefault`
* `resources.requests` and `resources.limits`, including `nvidia.com/gpu: 1`.
  Kubernetes requires an extended resource to appear in `limits`; requests are
  set to match. Tune memory to the model you serve.
* Startup, readiness and liveness probes. Streaming weights from object storage
  into GPU memory takes minutes, so the startup probe carries a 10-minute
  budget (`periodSeconds: 10`, `failureThreshold: 60`) while liveness and
  readiness stay tight. Readiness gates traffic, so a Pod is not routed
  requests while weights are still loading — the failure mode the previous
  no-probe configuration produced.
* `automountServiceAccountToken: false`
* `ingressClassName` and a `tls:` block on the Ingress, both on by default.
  Set `ingress.tls.secretName` to an existing TLS Secret, or leave it empty and
  let cert-manager populate it via `ingress.annotations`.

**A consequence worth knowing:** `readOnlyRootFilesystem: true` means the paths
vLLM and PyTorch write to at runtime must be mounted writable. The chart mounts
`emptyDir` volumes at `/root/.cache`, `/tmp` and `/dev/shm` (the last
memory-backed, 2Gi, for tensor-parallel shared memory). If you serve a model
that writes elsewhere, add the mount or set
`securityContext.readOnlyRootFilesystem=false`.

**Still absent:**

* A PodDisruptionBudget, topology spread constraints, or anti-affinity. The
  chart runs a single replica.
* Credentials still reach the container as environment variables — see §3.

A namespace enforcing the `restricted` Pod Security Standard should now admit
the chart's Pod. That has been checked against the rendered manifest, not
against a live admission controller.

---

## 6. Summary — hardened vs. not

| Area | Status |
| --- | --- |
| Chart runs under its own ServiceAccount, token not mounted | Good |
| RBAC grant is minimal (pods get/list, namespaced), explicitly namespaced | Good — opt-in via `k8s/rbac.yaml`; the chart grants nothing |
| No credentials committed to the repo | Good |
| Credential env block gated behind an explicit value | Good |
| CI actions pinned to commit SHAs | Good |
| Trivy scan runs on every build | Good — blocking on fixable CRITICAL/HIGH |
| Image tag names the registry it is pushed to | Good |
| NetworkPolicy selector matches the workload | Good — templated with the chart, asserted in CI |
| NetworkPolicy DNS + external egress rules | Good — present; the chart's ipBlock needs your bucket's ranges |
| Pod securityContext, seccomp, dropped capabilities | Good |
| GPU and memory limits | Good |
| Startup / readiness / liveness probes | Good |
| Ingress TLS and `ingressClassName` | Good |
| Deployment-layer validation in CI | Good — `helm lint`, `kubeconform -strict`, and regression assertions |
| Secrets in env vars, Knative Secret name hard-coded | **Not hardened** |
| Cosign signing / SBOM / admission verification | **Not implemented** — aspirational only |
| Encryption key management for the serving path | **Not implemented** |
| PodDisruptionBudget / topology constraints | **Not implemented** |
| Python lint enforcement in CI | **Not implemented** (pre-commit only) |
| Validated against a live cluster or a real GPU | **Never done** |

---

## 7. Hardening order — what is done, what is left

Items 1, 2, 3, 4, 6 and 7 of the original list are implemented and validated by
`.github/workflows/manifests.yml`:

1. ~~`serviceAccountName` and `automountServiceAccountToken: false` on the
   chart's Pod spec.~~ Done — the chart creates and uses its own account.
2. ~~NetworkPolicy selector matching the chart's labels, DNS egress, and an
   `ipBlock` egress rule.~~ Done — the chart templates its own policy from the
   same labels the Deployment uses.
3. ~~`securityContext` and resource limits including GPU.~~ Done.
4. ~~Make Trivy blocking.~~ Done — `exit-code: '1'`,
   `severity: 'CRITICAL,HIGH'`, `ignore-unfixed: true`.
6. ~~Readiness and liveness probes.~~ Done, plus a startup probe with a
   10-minute budget for weight streaming.
7. ~~TLS and `ingressClassName` on the Ingress.~~ Done, both on by default.

Still open, in priority order:

1. **Move S3 credentials out of environment variables** into a projected volume
   or short-lived cloud-identity credentials, and parameterise the Knative
   manifest's hard-coded `s3-credentials` Secret name. This was item 5 and is
   now the largest remaining gap in this document.
2. **Scope the CI kubeconfig.** `.github/workflows/build-and-deploy.yml` still
   writes `secrets.KUBECONFIG_DATA` wholesale; a cluster-admin kubeconfig in
   GitHub Actions is a large blast radius.
3. **Implement Cosign signing and SBOM generation**, or remove those claims
   from `security/policy-notes.md` and `docs/cks.md`.
4. **Wire encryption key management** into the serving path, or state plainly
   that encrypted serialization is unsupported by this deployment layer.
5. **Deploy this against a real GPU cluster and record the result.** Every
   statement in this document describes committed manifests that render and
   validate. None of it has been observed running.
