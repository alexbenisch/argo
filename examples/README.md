# Examples

Vendored tutorial repos, adapted to run on this playground. Each subdirectory has its own
README covering what changed and why.

- `kustom-webapp/` + `helm-webapp/` — Kustomize vs. Helm, from `devopsjourney1/argo-examples`
  (documented below).
- `vault-external-secrets/` — Vault + the External Secrets Operator, from
  `rslim087a/vault-kubernetes-external-secrets-tutorial`. See
  [`vault-external-secrets/README.md`](vault-external-secrets/README.md).

## Kustomize vs. Helm webapp

Two variants of the same trivial webapp (`devopsjourney1/mywebapp:latest`, listens on
container port 80), adapted from the `devopsjourney1/argo-examples` tutorial repo, showing
Argo CD deploying a Kustomize-managed app and a Helm-managed app side by side.

- `kustom-webapp/` — a Kustomize base + `dev`/`prod` overlays.
- `helm-webapp/` — a Helm chart with `values.yaml` + per-environment `values-dev.yaml` /
  `values-prod.yaml`.

Each is deployed twice (dev and prod namespaces) via the four Application manifests in
`manifests/apps/`:

- `webapp-kustom-dev.yaml` -> https://kustom-dev.kubetest.uk
- `webapp-kustom-prod.yaml` -> https://kustom-prod.kubetest.uk
- `webapp-helm-dev.yaml` -> https://helm-dev.kubetest.uk
- `webapp-helm-prod.yaml` -> https://helm-prod.kubetest.uk

### What was fixed vs. upstream

The upstream tutorial examples don't render as-is with current kustomize/helm and don't fit
this cluster. Fixes applied (see the top-of-file comment on each changed file for detail):

1. **Kustomize overlays failed outright** — `overlays/{dev,prod}/kustomization.yaml` used the
   deprecated `bases:` key and the old `patches:\n - replicas.yaml` shorthand, which the
   current kustomize patches API rejects
   (`invalid Kustomization: json: cannot unmarshal string into Go struct field
   Kustomization.patches`). Changed to `resources:` and `patches:\n - path: replicas.yaml`.

2. **`commonLabels` is deprecated** in `base/kustomization.yaml`. Migrated to `labels:`.
   Plain `labels:` does not inject into `spec.selector` the way `commonLabels` did, and
   `base/deployment.yaml`/`base/service.yaml` have no selector of their own (that's the point
   of the example), so `includeSelectors: true` is required to preserve that behavior.
   `commonAnnotations` was left as-is.

3. **Helm chart broke with default values** — `values.yaml` never defined `replicas`, so
   `{{ .Values.replicas }}` rendered a bare (null) `replicas:` when the chart was templated
   without an environment values file. Added `replicas: 1` as a safe default.
   `values-dev.yaml` (5) and `values-prod.yaml` (4) were left as they were.

### Adaptations for this cluster

- **Service type NodePort -> ClusterIP** in both examples. The tutorial used NodePort with
  `minikube service`, but this minikube runs on a remote VM whose firewall only allows
  22/80/443/6443, so NodePort is unreachable. Ingress replaces it as the entry point.
- **Ingress added** (not present upstream):
  - Kustomize: a separate `ingress.yaml` in each overlay (not in `base/`), so dev and prod
    each declare their own host/TLS secret. Points at `kustom-mywebapp-v1` (the base name
    `mywebapp` plus the base's `namePrefix: kustom-` / `nameSuffix: -v1`), port 80.
  - Helm: `templates/ingress.yaml`, driven by a new `ingress.host` / `ingress.tlsSecret` in
    values. Points at `{{ .Values.appName }}` (`myhelmapp`), port 80.
  - Both use `ingressClassName: nginx` and
    `cert-manager.io/cluster-issuer: letsencrypt` (the ClusterIssuer already exists in this
    cluster).

### Verifying locally

```
kubectl kustomize examples/kustom-webapp/overlays/dev/
kubectl kustomize examples/kustom-webapp/overlays/prod/

# helm is not installed on this workstation; run over ssh on argo-playground, or wherever helm is available
helm template test examples/helm-webapp -f examples/helm-webapp/values-dev.yaml
helm template test examples/helm-webapp -f examples/helm-webapp/values-prod.yaml
helm template test examples/helm-webapp   # no values file -> replicas defaults to 1
```
