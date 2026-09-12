---
title: "Vault + External Secrets example"
author: "Alex Benisch"
date: 2026-09-09
geometry: "margin=1.5cm"
papersize: a4
---

# Vault + External Secrets

Adapted from [rslim087a/vault-kubernetes-external-secrets-tutorial](https://github.com/rslim087a/vault-kubernetes-external-secrets-tutorial)
([video](https://youtu.be/CF6ARIXdA4A)).

The idea: secrets live in Vault, never in git. The External Secrets Operator
(ESO) watches `ExternalSecret` objects — which *are* in git, and contain only
pointers — and materialises real Kubernetes `Secret`s from Vault. Argo CD gets
to manage 100% of the cluster declaratively without a single credential in a
public repo.

```
Vault (org/kv/dev#api-key)
        |
        |  ClusterSecretStore "vault-backend"  (how to reach + authenticate to Vault)
        v
ExternalSecret dev/dev-api-key  --[ESO, every 60s]-->  Secret dev/dev-api-credentials
                                                              |
                                                              v
                                                     Deployment dev/api-consumer
```

## What's here

| File | What it is |
|------|-----------|
| `secret-store.yaml`         | `ClusterSecretStore` — cluster-scoped, so one definition serves every namespace |
| `external-secret-dev.yaml`  | `ExternalSecret` in `dev`, produces Secret `dev-api-credentials` |
| `external-secret-prod.yaml` | `ExternalSecret` in `prod`, produces Secret `prod-api-credentials` |
| `consumer-dev.yaml`         | busybox Deployment in `dev` reading the Secret as an env var |
| `consumer-prod.yaml`        | the same in `prod` |

Deployed by `manifests/apps/vault-secrets.yaml` (sync-wave 4). The operator and
Vault itself are separate Applications:

- `manifests/apps/external-secrets.yaml` — ESO Helm chart, wave -1 (CRDs first)
- `manifests/apps/vault.yaml` — Vault Helm chart in dev mode, wave 0

## Changes vs. upstream

1. **Vault moved into the cluster.** Upstream runs Vault via `docker-compose`
   on the developer's laptop and points the store at
   `http://host.docker.internal:8200`. This playground's minikube runs on a
   remote Hetzner VM behind a firewall that only allows 22/80/443/6443, so the
   cluster cannot reach a Vault on your workstation at all. Vault is installed
   in-cluster (dev mode, `manifests/apps/vault.yaml`) and addressed at
   `http://vault.vault.svc.cluster.local:8200`.

2. **`external-secrets.io/v1beta1` -> `external-secrets.io/v1`.** The upstream
   YAML targets ESO 0.15. The current chart (2.10.0) makes `v1` the served and
   stored version and only serves `v1beta1` if you set
   `crds.unsafeServeV1Beta1=true`. The field layout is otherwise unchanged, so
   this is a one-line edit per file.

3. **`demo` namespace -> `dev` and `prod`.** Upstream puts both ExternalSecrets
   in one namespace, which rather undersells a *Cluster*SecretStore. Splitting
   them across the `dev` and `prod` namespaces that already exist in this repo
   shows the point: one store, many namespaces, different values per
   environment. The store's `tokenSecretRef` correspondingly moved to the
   `vault` namespace and names it explicitly (a cluster-scoped object has no
   "current" namespace).

4. **Bare `Pod` -> `Deployment` for the consumer.** Argo CD manages this object;
   a bare Pod can't be updated in place and goes Degraded when its `sleep 3600`
   expires. The command also prints the key's *length* rather than its value —
   secrets in pod logs are a bad reflex to build, even with a fake key.

5. **Vault seeding is a script, not a manual copy-paste.**
   `scripts/60-vault-seed.sh` enables the `org/kv` KV-v2 mount, writes randomly
   generated dev/prod API keys, and creates the `vault-token` Secret.

## Bootstrap

Vault runs in **dev mode**: unsealed automatically, in-memory storage, plain
HTTP, fixed root token `root`. Everything is lost when the pod restarts. That
is deliberate for a throwaway playground, and thoroughly unsuitable for
anything else.

After Argo CD has synced the `vault` and `external-secrets` Applications:

```
scripts/60-vault-seed.sh
```

Re-run it after any `vault-0` restart, or the ExternalSecrets go `NotReady`.
Re-running also rotates both keys — see the exercises below.

Until it has run for the first time, `vault-secrets` sits in a retry loop and
the `api-consumer` pods are stuck in `CreateContainerConfigError` because their
Secret doesn't exist yet. That's the expected pre-seed state.

## Verifying

```bash
# ESO's view: did it manage to read Vault?
kubectl get externalsecret -A

# The Secrets ESO produced (owned by the ExternalSecret, not by Argo CD, and
# not in git)
kubectl -n dev  get secret dev-api-credentials  -o jsonpath='{.data.api-key}' | base64 -d; echo
kubectl -n prod get secret prod-api-credentials -o jsonpath='{.data.api-key}' | base64 -d; echo

# The value as the consumer pod actually sees it
kubectl -n dev exec deploy/api-consumer -- printenv API_KEY

# Vault's own view
kubectl -n vault exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv get org/kv/dev
```

The Vault UI is deliberately **not** exposed via ingress — a dev-mode Vault with
a published root token has no business on the public internet. Reach it locally:

```bash
kubectl -n vault port-forward svc/vault 8200:8200
# then http://localhost:8200, token: root
```

## Exercises

- **Rotate a secret.** Re-run `scripts/60-vault-seed.sh` and watch
  `kubectl -n dev get secret dev-api-credentials` change within a minute — with
  no commit, no sync, no Argo CD involvement at all. Then note that
  `kubectl -n dev exec deploy/api-consumer -- printenv API_KEY` still shows the
  *old* value: env vars are read once at container start.
  `kubectl -n dev rollout restart deployment/api-consumer` fixes it. Mounting
  the Secret as a volume instead would have updated live — a real trade-off
  worth having felt once.
- **Delete the materialised Secret** (`kubectl -n dev delete secret
  dev-api-credentials`) and watch ESO put it back. Note that this is ESO
  reconciling, not Argo CD self-heal — the Secret was never in git.
- **Break authentication.** Change the `token` in the `vault-token` Secret to
  garbage and read `kubectl -n dev describe externalsecret dev-api-key` — this
  is what a store misconfiguration actually looks like in the events.
- **Kill Vault** (`kubectl -n vault delete pod vault-0`) and see dev mode's
  in-memory storage for what it is: the mount and the data are gone, the
  ExternalSecrets go `SecretSyncedError`, and only re-seeding fixes it.
