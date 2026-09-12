---
title: "Argo Playground — minikube on Hetzner"
author: "Alex Benisch"
date: 2026-09-08
geometry: "margin=1.5cm"
papersize: a4
---

## What this is

A disposable Hetzner VM running minikube, used as a playground for learning
Argo CD and Argo Workflows. Everything past the initial bootstrap is managed
declaratively via an app-of-apps GitOps pattern: Argo CD watches this public
repo and reconciles cert-manager, Argo Workflows, cluster config (ClusterIssuers,
Ingresses), Vault + the External Secrets Operator, and a handful of example
workloads from it.

The whole point is that it's cheap to blow away and recreate — see "Cost"
below.

> **Warning:** `.env` holds live credentials (a Hetzner API token and a
> Cloudflare API token). This repo is public. `.env` must stay gitignored —
> never commit it, and double-check before pushing if you ever touch
> `.gitignore`.

## Prerequisites

- `hcloud`, `kubectl`, `helm`, `dig`, `python3`, `ssh` installed locally.
- Copy `.env.example` to `.env` and fill in:
  - `HCLOUD_TOKEN` — Hetzner Cloud API token (Read+Write) for the dedicated
    `argo-playground` project.
  - `CLOUDFLARE_KUBETEST_API_TOKEN` — Cloudflare API token scoped to the
    `kubetest.uk` zone with `Zone:DNS:Edit`.

## Quick start

Run in order:

1. `scripts/00-provision.sh` — creates the SSH key, Hetzner firewall, and the
   `argo-playground` VM; adds it to `~/.ssh/config`.
2. `scripts/10-dns.sh` — points `argo.kubetest.uk` and `argo-wf.kubetest.uk`
   at the VM's public IP in Cloudflare.
3. `scripts/20-bootstrap-host.sh` — installs Docker/kubectl/helm/minikube on
   the VM and starts the cluster.
4. `scripts/30-kubeconfig.sh` — pulls the cluster's client certs and merges
   an `argo-playground` context into your local `~/.kube/config`.
5. `scripts/40-argocd.sh` — installs Argo CD, seeds the Cloudflare token
   secret, and applies the app-of-apps root `Application` — from here on the
   cluster is managed by Argo CD from this repo.
6. `scripts/60-vault-seed.sh` — once Argo CD has synced the `vault` and
   `external-secrets` apps: enables the `org/kv` mount in the (dev-mode,
   in-memory) Vault, writes the demo API keys, and creates the token Secret the
   `ClusterSecretStore` authenticates with. Re-run it after any `vault-0`
   restart. See [`examples/vault-external-secrets/`](examples/vault-external-secrets/README.md).

## URLs

| Service        | URL                             |
|----------------|----------------------------------|
| Argo CD        | https://argo.kubetest.uk        |
| Argo Workflows | https://argo-wf.kubetest.uk     |

## Argo CD admin password

```
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

(`scripts/40-argocd.sh` also prints this once, right after install.)

## Daily use

- Switch to this cluster: `kubectl config use-context argo-playground`
- If your home/office IP changes and you lose access to SSH or the k8s API:
  `scripts/update-firewall.sh` re-points the firewall's SSH (22) and API
  (6443) rules at your current public IP. Ports 80/443 stay world-open for
  ingress regardless.

## Cost

The VM (`cpx32`) runs at roughly €9/month, billed hourly. Since this is just
a learning playground, run `scripts/99-teardown.sh` when you're done for the
day — it deletes the server, firewall, ssh-key, DNS records, and local
kube/ssh state (tolerating anything already absent), which brings the cost
for a session down to a few cents. Re-run the quick start above to bring it
all back.

## Learning exercises

- Edit the `replicas:` line in `manifests/demo/deployment.yaml`, commit, and
  push — watch Argo CD notice the drift from the live cluster and reconcile
  it back (self-heal), or notice your pushed change sync automatically.
- Submit the example workflow (not managed by Argo CD — Workflows are
  ephemeral runs, not declarative state):
  ```
  kubectl create -n argo -f manifests/workflows/hello-world.yaml
  ```
  then watch it run at https://argo-wf.kubetest.uk.
- Rotate a secret in Vault (re-run `scripts/60-vault-seed.sh`) and watch
  External Secrets propagate the new value into the `dev` and `prod` namespaces
  within a minute — no commit, no sync, no secret in git. More exercises in
  [`examples/vault-external-secrets/README.md`](examples/vault-external-secrets/README.md).

## Repo layout

```
.
├── manifests/
│   ├── root-app.yaml        # app-of-apps root Application (apply by hand once)
│   ├── apps/                # one Argo CD Application per managed component
│   ├── config/              # ClusterIssuers, ingresses for the two UIs
│   ├── demo/                # trivial nginx Deployment + Service
│   └── workflows/           # example Workflow, submitted manually
├── examples/                # vendored tutorial repos, adapted (see its README)
│   ├── kustom-webapp/       # Kustomize base + dev/prod overlays
│   ├── helm-webapp/         # the same app as a Helm chart
│   └── vault-external-secrets/  # ClusterSecretStore + ExternalSecrets + consumers
├── scripts/
│   ├── 00-provision.sh      # ssh key, firewall, VM
│   ├── 10-dns.sh            # Cloudflare A records
│   ├── 20-bootstrap-host.sh # docker/kubectl/helm/minikube on the VM
│   ├── 30-kubeconfig.sh     # merge a local kubectl context
│   ├── 40-argocd.sh         # install Argo CD, hand off to GitOps
│   ├── 60-vault-seed.sh     # seed the dev Vault + its token Secret
│   ├── update-firewall.sh   # re-point firewall rules at your current IP
│   ├── 99-teardown.sh       # destroy everything
│   ├── lib.sh               # shared config + helpers
│   └── remote/host-setup.sh # runs ON the VM (installs + starts minikube)
├── .env.example             # copy to .env and fill in (gitignored)
└── README.md
```
