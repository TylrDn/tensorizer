# Overview

This document belongs to the deployment layer added by the
[TylrDn/tensorizer](https://github.com/TylrDn/tensorizer) fork; the `tensorizer`
library itself is upstream
[CoreWeave's](https://github.com/coreweave/tensorizer). See
[About this fork](../README.md#about-this-fork) for the split.

The layer demonstrates a CoreWeave-aligned stack for high performance model serving.
It combines **Slurm on Kubernetes (SUNK)**, **Tensorizer**, **vLLM**, and CoreWeave
observability to provide fast, reproducible, and secure deployments.

**Want the whole path in one page?** Read the
[full-stack example](full-stack-example.md) — serialize, publish, deploy, serve,
verify — including a values table for the Helm chart, a troubleshooting table,
and the layer's known gaps.

## Five‑Minute Quickstart

```bash
# clone and enter the repo
git clone https://github.com/TylrDn/tensorizer
cd tensorizer

# run the Tensorizer demo
python examples/tensorizer/serialize_and_load.py --local-only
```

## Fifteen‑Minute Deep Dive

1. Deploy SUNK to a Kubernetes cluster and schedule a pod from a Slurm job.
2. Serialize and host a model using Tensorizer and CoreWeave Object Storage.
3. Launch vLLM pointing at the tensorized weights via the provided Helm chart.
4. Observe GPU and network metrics in CoreWeave Grafana dashboards.

The following documents provide more detail:

- [SUNK](sunk.md)
- [Schedule K8s Pods with Slurm](schedule-k8s-with-slurm.md)
- [Tensorizer](tensorizer.md)
- [vLLM](vllm.md)
- [Observability](observability.md)
- [CI/CD](cicd.md)
- [GitOps with ArgoCD](gitops.md)
- [Security Posture](security.md)
- [CKS Security Notes](cks.md)
- [Full-Stack Example](full-stack-example.md)
