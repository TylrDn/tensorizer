# Security Policy Snippets (illustrative)

> **Canonical document: [`docs/security.md`](../docs/security.md).** That page
> describes the security posture of the manifests this repository actually
> ships — the RBAC scope granted, the NetworkPolicy posture and its gaps, S3 and
> encryption-key handling, image provenance and scanning reality, and an
> explicit list of what is **not** hardened.
>
> The snippets below are illustrative examples only. They are *not* the
> manifests in `k8s/`, and the Cosign/Syft workflow described at the bottom of
> this page is **not implemented** in this repository.

## RBAC Example

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-runner
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "get", "list"]
```

## NetworkPolicy Example

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              access: object-storage
```

## Image Signing (target state, not implemented)

> Nothing in this repository signs images, generates SBOMs, or verifies
> signatures at admission. `.github/workflows/build-and-deploy.yml` builds,
> Trivy-scans (non-blocking) and pushes. Treat the following as the intended
> destination.

Images are signed with [Cosign](https://github.com/sigstore/cosign).  Generate
SBOMs with [Syft](https://github.com/anchore/syft) and store them alongside the
images.  Admission controllers should verify signatures before allowing pods to
run.
