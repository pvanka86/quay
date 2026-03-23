# RH Quay Operator — Kasten Blueprint

Kanister Blueprint for backup and restore of Red Hat Quay Operator
on OpenShift Container Platform using Veeam Kasten.

## Files in This Directory

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the `quay-kanister-tools` image required by the blueprint |
| `quay-kanister-blueprint.yaml` | Production Kanister Blueprint |
| `quay-kanister-rbac.yaml` | RBAC permissions for the Kanister pod |
| `docs/backup_restore_runbook.md` | Full backup and restore instructions |

---

## Prerequisites

- OpenShift Container Platform 4.14+
- Red Hat Quay Operator 3.13.2+
- Veeam Kasten 8.5.4+
- A container registry to host the tools image (Docker Hub, Quay, etc.)

---

## Setup Steps

### Step 1 — Build and Push the Tools Image

```bash
podman build --platform linux/amd64 \
  -t <your-registry>/<your-org>/quay-kanister-tools:1.0.0 \
  -f Dockerfile .

podman push <your-registry>/<your-org>/quay-kanister-tools:1.0.0
```

### Step 2 — Apply RBAC

```bash
kubectl apply -f quay-kanister-rbac.yaml
```

### Step 3 — Deploy the Blueprint

```bash
kubectl apply -f quay-kanister-blueprint.yaml -n kasten-io
```

### Step 4 — Annotate the Quay Deployment

```bash
kubectl annotate deployment quay-registry-quay-app \
  -n <quay-namespace> \
  kanister.kasten.io/blueprint='quay-operator-blueprint' \
  --overwrite
```

> ⚠️ Annotate the **Deployment** — not the QuayRegistry CR or the namespace.

### Step 5 — Configure Kasten Policy

Create a backup policy in the Kasten UI or via CLI targeting your Quay
namespace with your location profile.

Under **Kanister Options** in the policy, set these values:

| Option | Required | Description |
|---|---|---|
| `quayToolsImage` | ✅ Yes | Your tools image e.g. `docker.io/<org>/quay-kanister-tools:1.0.0` |
| `quayAdminPassword` | ✅ Yes | Quay admin user password |
| `quayRegistryName` | ⚪ No | Defaults to first QuayRegistry CR found |
| `quayAdminUser` | ⚪ No | Defaults to first enabled non-robot user in DB |
| `sourceNamespace` | ⚪ No | Defaults to `quay` |
| `storageNamespace` | ⚪ No | Defaults to namespace containing the s3 route |

### Step 6 — Restore

When restoring via the Kasten UI, under **Advanced Options → Resource Filter**
exclude these resource types to avoid conflicts with the Quay Operator:

- `services`
- `horizontalpodautoscalers`
- `deployments`
- `replicasets`
- `endpoints`

> These are all managed by the Quay Operator and will be recreated automatically.

---

## Full Documentation

See [docs/backup_restore_runbook.md](docs/backup_restore_runbook.md) for
complete step-by-step instructions, troubleshooting, and lessons learned.
