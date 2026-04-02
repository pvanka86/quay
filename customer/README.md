# Red Hat Quay Operator — Veeam Kasten Backup & Restore

Kanister Blueprint for automated backup and restore of Red Hat Quay Operator
on OpenShift Container Platform using Veeam Kasten.

---

## Objective

This blueprint enables **application-consistent, automated backup and restore**
of a Red Hat Quay registry deployed via the Quay Operator on OpenShift.
It integrates with Veeam Kasten as a set of execution hooks (pre/post backup,
pre/post restore) that handle everything the operator requires for a
clean, production-safe backup and a fully functional DR restore —
including blob sync, config preservation, and password reset.

Key outcomes:
- Scheduled or on-demand Quay backups via Kasten policy with zero manual steps
- Full DR restore into a separate namespace with all images intact and accessible
- Support for internal (NooBaa/ODF) and external object storage configurations
- Support for external PostgreSQL, Redis, and Clair configurations

---

## Validated Versions

| Component | Version |
|---|---|
| Red Hat Quay | 3.13.2 |
| Quay Operator | 3.13.2 |
| OpenShift Container Platform | 4.14+ |
| Veeam Kasten | 8.5.5 |
| Kanister | 0.118.0 |
| quay-kanister-tools image | `docker.io/pvanka86/quay-kanister-tools:2.0.0` |

---

## How It Works

The blueprint uses a **pure hook-based pattern** — no deployment annotations,
no annotated workloads. Five named actions are wired as Kasten execution hooks
on the backup policy and restore action:

```
BACKUP FLOW
  preBackupHook   → export manifests → capture component state → scale Quay to 0
                    → sync blobs NooBaa→S3
  [Kasten takes PVC snapshots — Quay=0, no in-flight writes]
  postBackupHook  → restore CR to pre-backup state → wait Available=True

RESTORE FLOW
  preRestoreHook  → clean stale OBC/secrets/HPAs in DR namespace
  [Kasten restores spec objects + PVCs into DR namespace]
  postRestoreHook → bootstrap operator → wait OBC bind → wait Available
                    → patch config.yaml → restore blobs S3→NooBaa
                    → scale up → flush Redis → reset password
  postRestoreHookError → best-effort cleanup if restore fails
```

### What Kasten Snapshots

- `quay-registry-quay-postgres-13` PVC (application-consistent — Quay at 0 replicas)
- `quay-registry-clair-postgres-15` PVC
- `quay-kanister-backup-manifests` ConfigMap (QuayRegistry CR, secrets, config bundle)
- All other spec objects in the namespace (routes, services, roles, rolebindings)

### What the Blueprint Manages

- Image blobs: synced from NooBaa to external S3 on backup, restored S3→NooBaa on restore
- QuayRegistry CR: exported, namespace-patched, re-applied in DR
- `managed-secret-keys` secret: carries SECRET_KEY and DATABASE_SECRET_KEY
- Config bundle secret: backed up and patched into operator's newly-created secret on restore
- Admin password: bcrypt-reset from `quay-kanister-credentials` secret (optional)

---

## Prerequisites

### 1. Quay Operator running in source namespace

The Quay Operator must be installed and the QuayRegistry CR must be in
`Available=True` state before the first backup.

```bash
oc get quayregistry -n quay \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}'
# Expected: True
```

### 2. External S3 bucket for blob sync

The blueprint syncs image blobs to an external S3-compatible bucket as a
separate data path from Kasten's PVC snapshot. This provides blob portability
independent of the storage layer.

Required bucket: create in your S3 provider before first backup.
The blueprint creates it automatically on first run if it does not exist.

### 3. Secret: `quay-s3-backup-credentials`

Create in **both** the source namespace and the DR namespace:

```bash
kubectl create secret generic quay-s3-backup-credentials \
  -n quay \
  --from-literal=AWS_ACCESS_KEY_ID=<your-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key> \
  --from-literal=AWS_S3_ENDPOINT=https://s3.us-east-2.amazonaws.com \
  --from-literal=AWS_S3_BUCKET=quay-kasten-blobs \
  --from-literal=AWS_DEFAULT_REGION=us-east-1

# Repeat for DR namespace
kubectl create secret generic quay-s3-backup-credentials \
  -n quay-dr \
  --from-literal=AWS_ACCESS_KEY_ID=<your-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key> \
  --from-literal=AWS_S3_ENDPOINT=https://s3.us-east-2.amazonaws.com \
  --from-literal=AWS_S3_BUCKET=quay-kasten-blobs \
  --from-literal=AWS_DEFAULT_REGION=us-east-1
```

### 4. Secret: `quay-kanister-credentials`

Used by the blueprint for admin password reset on restore (STEP 13).
Create in **both** the source namespace and the DR namespace:

```bash
kubectl create secret generic quay-kanister-credentials \
  -n quay \
  --from-literal=quayAdminUser=<your-quay-admin-username> \
  --from-literal=quayAdminPassword=<your-quay-admin-password>

kubectl create secret generic quay-kanister-credentials \
  -n quay-dr \
  --from-literal=quayAdminUser=<your-quay-admin-username> \
  --from-literal=quayAdminPassword=<your-quay-admin-password>
```

> If this secret is not created, the restore completes successfully but STEP 13
> is skipped — the original password hash from the PVC snapshot is preserved.

### 5. Quay Operator installed in DR namespace

The Quay Operator must be installed in the DR namespace before restore.
It can be cluster-scoped (one operator watching all namespaces) or
namespace-scoped in `quay-dr`. The operator pod must be Running before
triggering a RestoreAction.

```bash
oc get pods -n quay-dr | grep quay-operator
# Expected: quay-operator.vX.Y.Z-... 1/1 Running
```

### 6. Tools image

The blueprint runs inside a container using `quay-kanister-tools:2.0.0`.
This image is pre-built and available at:

```
docker.io/pvanka86/quay-kanister-tools:2.0.0
```

To build and host your own copy:

```bash
podman build --platform linux/amd64 \
  -t <your-registry>/<your-org>/quay-kanister-tools:2.0.0 \
  -f Dockerfile .

podman push <your-registry>/<your-org>/quay-kanister-tools:2.0.0
```

Then set the `quayToolsImage` option on your policy (see Options Reference).

---

## Setup Steps

### Step 1 — Apply RBAC

The blueprint pod needs permissions to read/patch QuayRegistry CRs, manage
secrets, exec into postgres/redis pods, and look up NooBaa routes.

```bash
kubectl apply -f quay-kanister-rbac.yaml
```

This creates a `ClusterRole` named `quay-kanister-role` with RoleBindings in
the source namespace (`quay`), DR namespace (`quay-dr`), and
`openshift-storage` (for NooBaa S3 route lookup).

> If your source namespace, DR namespace, or ODF namespace differ from the
> defaults, edit `quay-kanister-rbac.yaml` before applying.

### Step 2 — Deploy the Blueprint

```bash
kubectl apply -f quay-kanister-blueprint.yaml -n kasten-io
```

Verify:

```bash
kubectl get blueprint quay-kanister-blueprint -n kasten-io
```

### Step 3 — Create required secrets

Follow the Prerequisites section above to create `quay-s3-backup-credentials`
and `quay-kanister-credentials` in both namespaces.

### Step 4 — Create the Backup Policy

Apply the provided policy template (edit location profile and namespace first):

```bash
# Edit quay-backup-policy.yaml:
#   - Set spec.actions[0].backupParameters.profile.name to your location profile
#   - Set selector.matchExpressions[0].values[0] to your Quay namespace
kubectl apply -f quay-backup-policy.yaml
```

Or create via the Kasten UI. The policy **must** have these hooks wired under
`Backup Parameters → Hooks`:

| Hook | Blueprint | Action |
|---|---|---|
| Pre-hook | `quay-kanister-blueprint` | `preBackupHook` |
| On Success | `quay-kanister-blueprint` | `postBackupHook` |

And these resource exclusions under `Backup Parameters → Filters`:

| Resource | Group | Version |
|---|---|---|
| `subscriptions` | `operators.coreos.com` | `v1alpha1` |
| `operatorgroups` | `operators.coreos.com` | `v1` |
| `clusterserviceversions` | `operators.coreos.com` | `v1alpha1` |
| `installplans` | `operators.coreos.com` | `v1alpha1` |
| `horizontalpodautoscalers` | — | — |
| `objectbucketclaims` | — | — |
| `reclaimspacejobs` | — | — |
| `reclaimspacecronjobs` | — | — |
| `datasources` | — | — |
| `operatorconditions` | `operators.coreos.com` | `v2` |

> These exclusions prevent the operator lifecycle resources and NooBaa OBC
> from being restored by Kasten — the blueprint manages them directly.

### Step 5 — Run First Backup

Trigger an on-demand backup from the Kasten UI or via CLI:

```bash
kubectl create -f - <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: quay-backup-run-
  namespace: kasten-io
spec:
  subject:
    kind: Policy
    name: quay-backup-prod
    namespace: kasten-io
EOF
```

Monitor in Kasten UI or:

```bash
kubectl get runactions -n kasten-io -w
```

Stream blueprint logs:

```bash
# preBackupHook logs
kubectl logs -n quay -l app=kanister-job --follow

# postBackupHook logs (appears after PVC snapshot completes)
kubectl logs -n quay -l app=kanister-job --follow
```

The backup is complete when:
- RunAction reaches `Complete` state
- Source QuayRegistry returns to `Available=True`
- Restore point appears in Kasten UI

---

## Restore Steps

### Step 1 — Verify DR namespace is ready

```bash
# Quay Operator must be Running
oc get pods -n quay-dr | grep quay-operator

# Both secrets must exist in DR namespace
kubectl get secret quay-s3-backup-credentials -n quay-dr
kubectl get secret quay-kanister-credentials -n quay-dr
```

### Step 2 — Run the DR cleanup script (if retrying)

If a previous restore attempt left behind resources, run the cleanup script
before retrying:

```bash
bash quay-dr-cleanup.sh quay-dr quay
```

### Step 3 — Trigger the RestoreAction

Edit `quay-restore-action.yaml` — fill in:
- `spec.subject.name` — your restore point name
- `spec.subject.namespace` — source namespace
- `spec.targetNamespace` — DR namespace

```bash
kubectl create -f quay-restore-action.yaml
```

Or trigger via Kasten UI: select the restore point → Restore →
set target namespace to `quay-dr` → set hooks:

| Hook | Blueprint | Action |
|---|---|---|
| Pre-hook | `quay-kanister-blueprint` | `preRestoreHook` |
| On Success | `quay-kanister-blueprint` | `postRestoreHook` |
| On Failure | `quay-kanister-blueprint` | `postRestoreHookError` |

### Step 4 — Monitor

```bash
kubectl get restoreactions -n kasten-io -w

# Stream postRestoreHook logs
kubectl logs -n quay-dr -l app=kanister-job --follow
```

The restore is complete when all of these are true:
- RestoreAction reaches `Complete` (or is cleaned up by Kasten)
- `oc get quayregistry quay-registry -n quay-dr` shows `Available=True`
- All pods Running in `quay-dr`

### Step 5 — Verify

```bash
# Check QuayRegistry
oc get quayregistry -n quay-dr

# Check pods
oc get pods -n quay-dr

# Get DR Quay route
oc get route -n quay-dr -o jsonpath='{.items[0].spec.host}'

# Login to DR registry
podman login --tls-verify=false \
  --username <admin-user> --password <admin-password> \
  <dr-quay-route>

# Pull a test image
podman pull --tls-verify=false <dr-quay-route>/<org>/<image>:<tag>
```

---

## Options Reference

All options are set on the Kasten policy (`kanisterOptions`) or on the
RestoreAction (`kanisterOptions`). All options are optional — defaults are
safe for standard ODF/NooBaa environments.

| Option | Default | Description |
|---|---|---|
| `quayToolsImage` | `docker.io/pvanka86/quay-kanister-tools:2.0.0` | Override the tools container image |
| `quayRegistryName` | auto-discovered | QuayRegistry CR name. Set if multiple CRs exist in namespace |
| `sourceNamespace` | `quay` | Namespace the backup was taken from. Set on RestoreAction if source NS differs |
| `quayAdminUser` | auto-discovered from DB | Quay admin username for password reset. Overrides `quay-kanister-credentials` secret |
| `quayAdminPassword` | from `quay-kanister-credentials` secret | Admin password for bcrypt reset. Overrides secret value if set |
| `objectStorageType` | `noobaa` | `noobaa` = ODF/NooBaa OBC (default). `external` = direct S3/Azure/GCS in config.yaml, skips all OBC and blob sync steps. `none` = no object storage |
| `noobaaNamespace` | `openshift-storage` | Namespace where ODF/NooBaa is installed |
| `postgresManaged` | `true` | Set `false` if using external PostgreSQL — skips postgres pod waits and in-cluster password reset |
| `redisManaged` | `true` | Set `false` if using external Redis — skips Redis FLUSHALL step |
| `clairManaged` | `true` | Set `false` if using external Clair — skips clair-app pod gate |
| `drReplicas` | `1` | Number of replicas for quay/clair/mirror on DR scale-up. Set `2` for HA DR environments |
| `blobSyncEnabled` | `true` | Set `false` to skip blob sync entirely (useful when `objectStorageType=external`) |

### Example: External PostgreSQL + Redis

```yaml
kanisterOptions:
  postgresManaged: "false"
  redisManaged: "false"
  drReplicas: "2"
```

### Example: External object storage (AWS S3 directly in config.yaml)

```yaml
kanisterOptions:
  objectStorageType: "external"
  blobSyncEnabled: "false"
```

---

## Files in This Directory

| File | Purpose |
|---|---|
| `quay-kanister-blueprint.yaml` | Production Kanister Blueprint v6.0.0 |
| `quay-kanister-rbac.yaml` | RBAC — ClusterRole + RoleBindings for blueprint pod |
| `quay-kanister-credentials.yaml` | Secret template for admin credentials |
| `quay-backup-policy.yaml` | Kasten backup policy template |
| `quay-restore-action.yaml` | Kasten RestoreAction template |
| `quay-dr-cleanup.sh` | DR namespace cleanup script (run before retrying restore) |
| `Dockerfile` | Builds the `quay-kanister-tools` container image |

---

## Troubleshooting

### ConfigInvalid at backup time

```
[INIT] ERROR: QuayRegistry is in ConfigInvalid state
```

Cause: `DISTRIBUTED_STORAGE_CONFIG` in `config.yaml` conflicts with
`objectstorage` component `managed:true`. The operator ignores scale-down
overrides when in this state.

Fix: Remove `DISTRIBUTED_STORAGE_CONFIG`, `DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS`,
and `DISTRIBUTED_STORAGE_PREFERENCE` from the config bundle secret. The blueprint
auto-fixes this on restore but cannot proceed at backup time.

### OBC stuck in Pending after restore

Cause: Stale NooBaa OBC Secret or ConfigMap from a previous restore is
blocking the provisioner. Run the cleanup script and retry:

```bash
bash quay-dr-cleanup.sh quay-dr quay
```

### postRestoreHook pod running for a long time

Normal — the postRestoreHook performs blob restore (S3→NooBaa) which takes
time proportional to registry size. Check progress:

```bash
kubectl logs -n quay-dr -l app=kanister-job --follow
```

### Password reset skipped

If `quay-kanister-credentials` secret is missing or `quayAdminPassword` option
is not set, STEP 13 is skipped. The original password hash from the PVC
snapshot remains. Create the secret and re-trigger the restore, or reset
the password manually:

```bash
# Connect to postgres pod and reset
oc exec -n quay-dr <postgres-pod> -- \
  psql -d <db-name> -c \
  "UPDATE public.user SET password_hash='<bcrypt-hash>' WHERE username='<admin>';"
```

### DR namespace cleanup

If a restore fails or you need to re-run from scratch:

```bash
bash quay-dr-cleanup.sh quay-dr quay
```

This script preserves the Quay Operator pod and `quay-s3-backup-credentials`
secret. Everything else in `quay-dr` is deleted so the next restore starts clean.

---

## References

- [Red Hat Quay Operator Documentation](https://docs.redhat.com/en/documentation/red_hat_quay/3.13)
- [Veeam Kasten Documentation](https://docs.kasten.io)
- [Kanister Documentation](https://docs.kanister.io)
- [NooBaa / ODF Documentation](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation)
