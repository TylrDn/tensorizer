# Fork Deployment-Layer Changelog

This file tracks changes to the **deployment layer added by this fork**
([TylrDn/tensorizer](https://github.com/TylrDn/tensorizer)) — the Helm chart,
Kubernetes manifests, GitOps assets, security notes, deployment examples, and
fork-authored documentation.

It does **not** track changes to the `tensorizer` Python library itself. Those
are upstream [coreweave/tensorizer](https://github.com/coreweave/tensorizer)
releases and are recorded in [`CHANGELOG.md`](CHANGELOG.md), which is upstream's
file and is not modified here beyond a single pointer line.

**Versioning.** Fork-layer versions use the `deploy-MAJOR.MINOR.PATCH` prefix and
are **independent of upstream `tensorizer` release numbers**. `deploy-0.1.0` has
no relationship to `tensorizer` 0.1.0. Each entry records the upstream tag the
fork layer was based on and validated against, so the two axes stay legible.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the deployment layer adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Scope of "validated".** Validation for this layer means: YAML parses,
`helm lint helm/tensorizer-vllm` passes, and documented commands and values were
read from the committed files. It does **not** mean the stack was deployed to a
live GPU cluster, and no performance claim in this repository was measured by
this fork — see the attribution note in the [README](README.md#about-this-fork).

---

## [deploy-0.2.0] - 2026-09-08

Upstream base: `v2.12.0` (fork branched at commit `92bd5bc`, "Merge pull request
#200 from coreweave/eta/v2.12.0"). Upstream has since released 2.12.1; this fork
has not been rebased onto it.

### Added

- `docs/full-stack-example.md` — a single end-to-end walkthrough: serialize a
  model → publish to S3/HTTP → deploy with Helm, ArgoCD, or Knative → serve with
  vLLM → verify with `curl` and Prometheus metrics. Includes a full table of the
  Helm chart's values with defaults, a troubleshooting table, and an explicit
  "known gaps" list.
- `docs/gitops.md` — documents `gitops/argocd/app.yaml`: every field, the
  prerequisites, exactly what a user must change to target their own fork and
  namespace, and the consequences of `prune: true` / `selfHeal: true`.
- `docs/security.md` — the canonical security document for the deployment layer:
  the RBAC scope actually granted, the NetworkPolicy posture and its selector
  mismatch, S3-credential and encryption-key handling, image provenance and
  scanning reality versus aspiration, and a table of what is **not** hardened.
- `CHANGELOG-FORK.md` — this file.
- "About this fork" section in `README.md` enumerating every fork-owned path.

### Changed

- `README.md` restructured: a single H1, a delimited "About this fork" section
  separating Taylor Dean's deployment layer from CoreWeave's library, and an
  explicit `## Upstream tensorizer documentation` heading before the inherited
  content (upstream's duplicate H1 demoted to H2).
- `README.md` badges: the CI badge now points at this fork's
  `build-and-deploy.yml` workflow instead of coreweave's, and a Tests badge for
  this fork's `test.yml` was added.
- `README.md` Quickstart Map expanded with the new documents and verified so
  every link resolves to a real file.
- `gitops/argocd/app.yaml` — `source.repoURL` corrected from
  `https://github.com/coreweave/tensorizer` (which does not contain
  `helm/tensorizer-vllm`, so the Application could never sync) to
  `https://github.com/TylrDn/tensorizer`.
- `security/policy-notes.md` — retitled as illustrative snippets and pointed at
  `docs/security.md` as the canonical document.
- `docs/overview.md` — clone URL corrected to this fork; new docs cross-linked.
- `docs/tensorizer.md` — the "~5GB/s" throughput expectation is now explicitly
  attributed to CoreWeave's published benchmarks and marked as not independently
  reproduced here.

### Removed

- `README.md` "Lint — black + isort" badge. It linked to a dead `#` anchor and
  implied CI-enforced linting; `black`/`isort` run only via
  `.pre-commit-config.yaml`, not in any GitHub Actions workflow.

### Fixed

- The two dead `#` badge links in `README.md` (Container Scan and Lint). The
  container-scan badge now links to the workflow that genuinely runs Trivy.
- Duplicate `# tensorizer` H1 headings in `README.md`.

### Known limitations

Carried forward and documented rather than silently fixed, since they change
runtime behaviour and are not covered by any test in this repository:

- The Helm chart sets no `serviceAccountName`, so `k8s/rbac.yaml`'s
  `tensorizer-sa` is not bound to the deployed workload.
- `k8s/networkpolicy.yaml` selects `app: tensorizer` while the chart labels pods
  `app: {{ .Release.Name }}`.
- No GPU resource limits, probes, `securityContext`, or Ingress TLS.
- The `vllm serve --model <uri> --tensorizer` argument form used by the chart,
  the Knative manifest, and `examples/vllm/run_vllm_tensorized.sh` has not been
  executed against a live vLLM release here.

All are listed in
[`docs/full-stack-example.md`](docs/full-stack-example.md#known-gaps-in-this-layer)
and [`docs/security.md`](docs/security.md).

---

## [deploy-0.1.0] - 2025-08-29

Upstream base: `v2.12.0`. The initial deployment layer, added across commits
`b1a3bfc`, `bd74c8b` and `758a845`.

### Added

- `helm/tensorizer-vllm/` — Helm chart (`Chart.yaml`, `values.yaml`, and
  `templates/` for Deployment, Service and Ingress) deploying vLLM against a
  tensorized model URI, with optional S3 credentials from a Kubernetes Secret.
- `k8s/knative-service.yaml` — Knative Service with
  `autoscaling.knative.dev/minScale: "0"` for scale-to-zero serving.
- `k8s/rbac.yaml` — `tensorizer-sa` ServiceAccount, a Role granting
  `get`/`list` on pods, and the RoleBinding.
- `k8s/networkpolicy.yaml` — ingress on TCP/8000, egress on TCP/443.
- `gitops/argocd/app.yaml` — ArgoCD Application with automated sync, prune and
  self-heal.
- `security/policy-notes.md` — RBAC/NetworkPolicy snippets and Cosign/Syft
  notes.
- `.github/workflows/build-and-deploy.yml` — build, Trivy scan, push to GHCR,
  and `helm upgrade --install` into a test namespace, with all third-party
  actions pinned to commit SHAs.
- Fork documentation: `docs/overview.md`, `docs/sunk.md`,
  `docs/schedule-k8s-with-slurm.md`, `docs/tensorizer.md`, `docs/vllm.md`,
  `docs/observability.md`, `docs/cicd.md`, `docs/cks.md`, and
  `docs/img/architecture.svg`.
- Examples: `examples/tensorizer/serialize_and_load.py`,
  `examples/vllm/run_vllm_tensorized.sh`,
  `examples/sunk/slurm-pod/` (`pod.sbatch` + README), and
  `examples/observability/grafana/README.md`.
- The fork-added block at the top of `README.md` (badges, architecture diagram,
  Quickstart Map) — restructured in `deploy-0.2.0`.

[deploy-0.2.0]: https://github.com/TylrDn/tensorizer/compare/deploy-0.1.0...main
[deploy-0.1.0]: https://github.com/TylrDn/tensorizer/commits/main
