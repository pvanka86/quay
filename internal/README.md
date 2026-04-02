# Internal — Lab & SE Use Only

> ⚠️ These files are for **internal lab and SE use only**.
> Do not share with customers. Customer-facing files are in `../customer/`.

---

## Lab Environment

| Setting | Value |
|---|---|
| OCP Cluster | `kasten-se-lab-baremetal.kasten.veeam.local` |
| Source namespace | `quay` |
| DR namespace | `quay-dr` |
| QuayRegistry CR | `quay-registry` |
| Quay version | 3.13.2 |
| Kasten version | 8.5.5 |
| Tools image | `docker.io/pvanka86/quay-kanister-tools:2.0.0` |
| Location profile | `kasten-se-lab-baremetal-s3` |

---

## Files in This Directory

| File | Purpose |
|---|---|
| `quay-kanister-blueprint-lab.yaml` | Lab blueprint v5 — identical logic to production v6, lab policy name, used for SE demos and testing |
| `quay-backup-policy-lab.yaml` | Lab backup policy — wired to `quay-kanister-blueprint-lab`, uses lab location profile |
| `quay_e2e_test.sh` | End-to-end automated test script — runs full backup+restore cycle and verifies image pull from DR |

---

## Lab vs Production Blueprint

| Aspect | Production (`customer/`) | Lab (`internal/`) |
|---|---|---|
| Blueprint name | `quay-kanister-blueprint` | `quay-kanister-blueprint-lab` |
| Policy name | `quay-backup-prod` | `quay-backup-lab` |
| Version | v6.0.0 | v5.0.0 |
| Behavior | Identical — same hook logic, same options | Identical — same hook logic, same options |
| DR replicas default | 1 | 1 |

The lab blueprint is kept at v5 as a stable fallback during active development
of production v6. Once v6 is fully validated, the lab blueprint will be updated.

---

## E2E Test Script

`quay_e2e_test.sh` runs a complete automated backup and restore cycle:

```
Section 1 — Pre-flight checks
Section 2 — Push test image to source Quay, verify NooBaa blobs
Section 3 — Verify backup policy hooks
Section 4 — Trigger backup, stream logs, wait for completion
Section 5 — Run DR cleanup, verify clean state
Section 6 — Trigger restore with all 3 hooks, stream logs, wait for completion
Section 7 — Verify DR: pods, QuayRegistry Available, health endpoint,
            image pull, digest comparison
```

### Usage

```bash
./quay_e2e_test.sh [lab|prod]

# lab  (default) — quay-backup-lab policy + quay-kanister-blueprint-lab
# prod           — quay-backup-prod policy + quay-kanister-blueprint
```

### Prerequisites before running

Both secrets must exist in both `quay` and `quay-dr`:

```bash
# Verify
kubectl get secret quay-s3-backup-credentials -n quay
kubectl get secret quay-s3-backup-credentials -n quay-dr
kubectl get secret quay-kanister-credentials -n quay
kubectl get secret quay-kanister-credentials -n quay-dr
```

Source Quay must be `Available=True` and the Quay Operator must be Running
in `quay-dr` before running the script.

### Interpreting results

A passing run ends with:
```
✓ END-TO-END TEST PASSED
  Quay DR restore validated — image pull from DR registry succeeded
```

The digest comparison confirms the image pulled from DR is bit-for-bit
identical to the image pushed to the source registry before backup.

---

## Policy Files

### `quay-backup-policy-lab.yaml`

Lab backup policy wired to `quay-kanister-blueprint-lab`. Apply once:

```bash
kubectl apply -f quay-backup-policy-lab.yaml
```

Verify hooks are correctly wired:
```bash
kubectl get policy quay-backup-lab -n kasten-io \
  -o jsonpath='{.spec.actions[0].backupParameters.hooks}' \
  | python3 -m json.tool
```

Expected:
```json
{
  "onSuccess": {
    "actionName": "postBackupHook",
    "blueprint": "quay-kanister-blueprint-lab"
  },
  "preHook": {
    "actionName": "preBackupHook",
    "blueprint": "quay-kanister-blueprint-lab"
  }
}
```

---

## Common Lab Operations

### Apply/update the lab blueprint

```bash
kubectl apply -f quay-kanister-blueprint-lab.yaml -n kasten-io
kubectl get blueprint quay-kanister-blueprint-lab -n kasten-io
```

### Monitor a running blueprint job

```bash
# Source namespace (backup hooks)
kubectl get pods -n quay | grep kanister-job
kubectl logs -n quay -l app=kanister-job --follow

# DR namespace (restore hooks)
kubectl get pods -n quay-dr | grep kanister-job
kubectl logs -n quay-dr -l app=kanister-job --follow
```

### Clean DR namespace before a fresh restore

```bash
bash ../customer/quay-dr-cleanup.sh quay-dr quay
```

### Check QuayRegistry status

```bash
# Source
oc get quayregistry quay-registry -n quay \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# DR
oc get quayregistry quay-registry -n quay-dr \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

### Tail Kasten operator logs during restore

```bash
kubectl logs -n kasten-io \
  $(kubectl get pods -n kasten-io | grep executor | awk '{print $1}') \
  --follow | grep -i "quay\|hook\|blueprint"
```
