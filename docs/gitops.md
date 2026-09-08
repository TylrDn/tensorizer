# GitOps with ArgoCD

**Fork-authored document.** ArgoCD delivery is part of the
[TylrDn/tensorizer](https://github.com/TylrDn/tensorizer) deployment layer;
upstream [coreweave/tensorizer](https://github.com/coreweave/tensorizer) ships no
GitOps assets.

The entire GitOps surface of this repo is one file: `gitops/argocd/app.yaml`.

## What the manifest actually declares

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tensorizer-vllm
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  source:
    repoURL: https://github.com/TylrDn/tensorizer
    path: helm/tensorizer-vllm
    targetRevision: main
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Field by field:

| Field | Value | What it means here |
| --- | --- | --- |
| `metadata.name` | `tensorizer-vllm` | The Application object's name. It also becomes the Helm release name ArgoCD uses, so every chart resource is named `tensorizer-vllm` (the templates derive names from `.Release.Name`). |
| `metadata.namespace` | *(absent)* | Defaults to whatever namespace you `kubectl apply` into. ArgoCD only reconciles Applications in the namespace it watches — conventionally `argocd`. Apply it there. |
| `destination.server` | `https://kubernetes.default.svc` | Deploy into the same cluster ArgoCD runs in. Replace with a registered cluster URL (or use `destination.name`) for a remote target. |
| `destination.namespace` | `default` | Where the workload lands. There is **no** `CreateNamespace=true` sync option, so the namespace must already exist if you change this. |
| `source.repoURL` | `https://github.com/TylrDn/tensorizer` | The fork. Point at your own fork if you diverge. |
| `source.path` | `helm/tensorizer-vllm` | ArgoCD auto-detects the Helm chart from `Chart.yaml` at this path. |
| `source.targetRevision` | `main` | A moving branch: every push to `main` is deployed. |
| `source.helm` | *(absent)* | No value overrides. The chart's `values.yaml` defaults are used verbatim — including the placeholder `modelURI` and the empty `s3.secretName`. |
| `project` | `default` | The built-in AppProject, which by default permits any repo, cluster and namespace. |
| `syncPolicy.automated.prune` | `true` | Resources removed from Git are **deleted** from the cluster. |
| `syncPolicy.automated.selfHeal` | `true` | Out-of-band changes (a `kubectl edit`, a manual `helm upgrade`) are **reverted** to the Git state. |

## Prerequisites

* An ArgoCD installation, with the controller watching the namespace you apply
  this Application into (usually `argocd`).
* Network access from ArgoCD's repo-server to `repoURL`, plus credentials if the
  repository is private.
* The target namespace in `destination.namespace` must exist.
* If you keep the default `project: default`, no extra AppProject setup is
  needed. In a locked-down installation, create an AppProject that whitelists
  your `repoURL`, destination cluster and namespace, and set `project` to it.

## Applying it

```bash
kubectl apply -n argocd -f gitops/argocd/app.yaml
argocd app get tensorizer-vllm
argocd app sync tensorizer-vllm      # only needed for the very first sync
```

## What you must change before using it for real

1. **`source.repoURL`** — set it to your own fork if you are not tracking
   `TylrDn/tensorizer`. This is the field most likely to silently deploy someone
   else's code.
2. **`source.targetRevision`** — `main` is a branch, so deployments follow every
   push. For anything you care about, pin a tag or a commit SHA.
3. **`destination.namespace`** — `default` is not where a GPU inference workload
   should live. Create a namespace and set it, e.g.:

   ```yaml
   destination:
     namespace: tensorizer
   syncPolicy:
     syncOptions:
       - CreateNamespace=true
   ```

4. **Chart values.** With no `source.helm` block, the release deploys with
   `modelURI: s3://my-bucket/models/tiny-gpt2.tensors` and no S3 credentials —
   i.e. a placeholder. Add overrides:

   ```yaml
   source:
     helm:
       values: |
         image: ghcr.io/<you>/vllm:<tag>
         modelURI: s3://my-bucket/models/my-model.tensors
         host: vllm.example.com
         s3:
           secretName: s3-credentials
   ```

   The Secret itself must exist in the destination namespace beforehand and is
   deliberately not in Git — see [security.md](security.md).
5. **`project`** — move off `default` if your ArgoCD is multi-tenant.

Every value in the chart is documented in the
[full-stack example, step 3](full-stack-example.md#3-deploy).

## Living with `prune` and `selfHeal`

Both are on. That is the right default for a repo that wants Git to be the
single source of truth, but it has consequences worth stating plainly:

* **`prune: true`** — delete a template from `helm/tensorizer-vllm/templates/`
  and ArgoCD deletes the live object on the next sync. Deleting the Application
  itself does not cascade unless you add the resources-finalizer; deleting the
  chart contents does.
* **`selfHeal: true`** — manual cluster edits are reverted, typically within
  seconds of detection. Do not debug by editing the live Deployment; it will be
  undone. Either change Git, or temporarily disable automation:

  ```bash
  argocd app set tensorizer-vllm --sync-policy none
  # ... debug ...
  argocd app set tensorizer-vllm --sync-policy automated --auto-prune --self-heal
  ```

* There is no `syncOptions` block at all, so no `CreateNamespace`, no
  `ServerSideApply`, no `Replace`. Add them explicitly if you need them.
* There are no `ignoreDifferences` entries, so anything a mutating admission
  controller or autoscaler writes back onto these objects can produce permanent
  `OutOfSync` churn.

## Relationship to the CI pipeline

`.github/workflows/build-and-deploy.yml` runs `helm upgrade --install` directly
against a cluster using a kubeconfig from `secrets.KUBECONFIG_DATA`
(namespace `test`). That is a **push**-based deploy and is separate from this
Application. `docs/cicd.md` describes the intended end state — CI commits updated
chart values for ArgoCD to pick up — but the workflow as committed does not do
that; it deploys directly. If you enable both against the same namespace and
release name, `selfHeal` and the CI job will fight. Keep them on separate
namespaces, or drop the direct `helm upgrade` step. See [cicd.md](cicd.md).

## See also

* [Full-stack example](full-stack-example.md) — the complete path this
  Application sits at the end of.
* [Security notes](security.md) — RBAC, NetworkPolicy, secret handling.
* [CI/CD](cicd.md) — the push-based pipeline.
