# Security Notes

These guidelines align with the Kubernetes Certified Security Specialist (CKS)
objectives. They are a checklist of good practice, not a description of what
this repository implements — for that, see [security.md](security.md), which is
the canonical account of the manifests actually shipped here and of what is not
hardened.

## Five‑Minute Quickstart

1. Apply the provided RBAC and NetworkPolicy manifests before deploying.
2. Use signed container images and verify SBOMs during admission.
3. Limit service accounts to the minimum required permissions.

## Fifteen‑Minute Deep Dive

- RBAC: see [security.md](security.md#1-rbac--what-is-actually-granted) for the
  scope `k8s/rbac.yaml` really grants, and `security/policy-notes.md` for
  illustrative Role/RoleBinding examples.
- NetworkPolicies restrict pod egress to Object Storage and required services.
- Admission policies (OPA/Gatekeeper or Kyverno) enforce image signatures.
  (Not implemented in this repository — no signing, SBOM, or admission policy
  is committed here.)
- Enable audit logging and ship logs to a secure location.

Security is continuous; integrate checks into CI/CD as shown in
[docs/cicd.md](cicd.md).
