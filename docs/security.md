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

**Gaps:**

* The RoleBinding's subject has **no `namespace:` field**, so it resolves to the
  namespace the RoleBinding is created in. Applying the file across namespaces
  will not do what you expect unless the ServiceAccount is applied alongside it.
* **The Helm chart does not use this ServiceAccount.**
  `helm/tensorizer-vllm/templates/deployment.yaml` sets no `serviceAccountName`,
  so the vLLM Pod runs as the namespace `default` ServiceAccount and this Role is
  bound to nothing that the chart creates. If you want the workload to run under
  `tensorizer-sa`, add `serviceAccountName: tensorizer-sa` to the Pod spec.
* Nothing sets `automountServiceAccountToken: false`. A token is mounted into the
  Pod that has no need for the API server at all — the recommended posture for a
  pure inference workload is to disable automounting entirely.

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

**Gaps:**

* **The selector does not match the chart's pods.** The policy selects
  `app: tensorizer`; the chart labels pods `app: {{ .Release.Name }}`. Unless the
  release is literally named `tensorizer`, the policy applies to nothing. The
  Knative service (`k8s/knative-service.yaml`) carries Knative's own labels and
  is likewise not selected.
* **`namespaceSelector: {}` does not cover off-cluster destinations.** Object
  storage is almost always external, so with this policy in force and matching, a
  Pod would be unable to reach `s3://` or `https://` endpoints outside the
  cluster. Reaching external S3 requires an egress rule with an `ipBlock` (plus
  DNS egress on UDP/53 to `kube-system`, which is also absent). If model loading
  hangs after you apply this policy, this is why.
* **No DNS egress rule.** Without UDP/53 allowed, name resolution fails.
* Ingress is not restricted to the ingress-controller namespace, which would be
  the tighter posture.
* NetworkPolicy is enforced only if your CNI supports it. On a CNI that ignores
  NetworkPolicy, this file is inert and provides zero protection.

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

Weaknesses in the same workflow:

* The Trivy step sets **no `exit-code`, `severity`, or `ignore-unfixed`**. With
  the action's defaults it reports findings without failing the job, so the scan
  is informational: a critical CVE does not block the push or the deploy.
* The image is tagged `example/vllm:...` while the login targets `ghcr.io`. The
  tag carries no registry prefix, so the push target does not clearly correspond
  to the registry that was authenticated.
* Build and deploy are one job with no gate between scanning and deploying.

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
every push and pull request. Nothing in CI tests the Helm chart, the k8s
manifests, or the ArgoCD Application beyond what `helm upgrade --install`
implicitly exercises.

---

## 5. Pod-level hardening — absent

Neither `helm/tensorizer-vllm/templates/deployment.yaml` nor
`k8s/knative-service.yaml` sets any of the following. All are missing, and all
are things a Pod Security Standards "restricted" profile would require:

* `securityContext` of any kind — no `runAsNonRoot`, `runAsUser`,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, or
  `capabilities.drop: ["ALL"]`
* `seccompProfile: RuntimeDefault`
* `resources.requests` / `resources.limits` (including GPU limits), so there is
  no protection against resource exhaustion
* Liveness or readiness probes
* `automountServiceAccountToken: false`
* A PodDisruptionBudget or any topology constraint
* TLS on the Ingress (`templates/ingress.yaml` has no `tls:` block and no
  `ingressClassName`), so the exposed route is plain HTTP by default

If you deploy into a namespace enforcing the `restricted` Pod Security Standard,
expect the chart's Pod to be rejected until you add a `securityContext`.

---

## 6. Summary — hardened vs. not

| Area | Status |
| --- | --- |
| RBAC grant is minimal (pods get/list, namespaced) | Good — but not attached to the chart's workload |
| No credentials committed to the repo | Good |
| Credential env block gated behind an explicit value | Good |
| CI actions pinned to commit SHAs | Good |
| Trivy scan runs on every build | Present, but non-blocking |
| NetworkPolicy exists | Present, but selector mismatch + no external egress or DNS rules |
| Secrets in env vars, Knative Secret name hard-coded | Not hardened |
| Cosign signing / SBOM / admission verification | **Not implemented** — aspirational only |
| Encryption key management for the serving path | **Not implemented** |
| Pod securityContext, probes, resource limits, TLS | **Not implemented** |
| Lint enforcement in CI | **Not implemented** (pre-commit only) |
| Any deployment-layer test coverage beyond `helm lint` | **Not implemented** |

---

## 7. Suggested hardening order

1. Add `serviceAccountName: tensorizer-sa` and
   `automountServiceAccountToken: false` to the chart's Pod spec, so the
   minimal Role in `k8s/rbac.yaml` actually applies.
2. Fix the NetworkPolicy selector to match the chart's labels, then add DNS
   egress and an `ipBlock` egress rule for your object-storage endpoint.
3. Add a `securityContext` (`runAsNonRoot`, drop all capabilities,
   `allowPrivilegeEscalation: false`) and resource limits including GPU.
4. Make Trivy blocking: set `exit-code: '1'` with an explicit `severity` filter.
5. Move S3 credentials from env vars to a projected volume, or to
   short-lived cloud-identity credentials.
6. Add readiness/liveness probes so a Pod is not routed traffic while weights
   are still streaming.
7. Add TLS and an `ingressClassName` to the Ingress template.
8. Implement Cosign signing + SBOM generation, or remove those claims from
   `security/policy-notes.md` and `docs/cks.md`.
