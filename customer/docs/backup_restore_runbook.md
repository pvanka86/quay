# RH Quay Operator — Backup & Restore Runbook
**Version:** 3.0.0  
**Quay Version:** 3.13.2  
**Validated:** March 2026  

---

## Overview

This runbook covers two methods for backup and restore of Red Hat Quay Operator:

| Method | Use Case |
|---|---|
| **Method A — Manual Scripts** | Ad-hoc backup/restore, testing, troubleshooting |
| **Method B — Kasten Blueprint** | Scheduled automated backup/restore via Kasten policy |

---

## Prerequisites

### Tools Required (Local Workstation)
| Tool | Purpose |
|---|---|
| `oc` / `kubectl` | OpenShift CLI |
| `aws` CLI v2 | NooBaa/S3 object storage sync (manual method) |
| `python3` + `PyYAML` + `bcrypt` | YAML cleanup + password reset |
| `podman` | Image build, push, pull verification |

```bash
# Install required Python packages
python3 -m pip install PyYAML bcrypt
```

### Environment Variables — Set Once, Used Everywhere
Save to `env.sh` and source before every session:

```bash
# ── Registry ────────────────────────────────────────────────────────────────
export REGISTRY="docker.io"
export REGISTRY_USER="<your-dockerhub-username>"
export REGISTRY_PASS="<your-dockerhub-password>"
export IMAGE_NAME="quay-kanister-tools"
export IMAGE_TAG="1.0.0"
export FULL_IMAGE="${REGISTRY}/${REGISTRY_USER}/${IMAGE_NAME}:${IMAGE_TAG}"

# ── OCP / Quay ───────────────────────────────────────────────────────────────
export SOURCE_NS="quay"
export DR_NS="quay-dr"
export QUAY_CR_NAME="quay-registry"
export QUAY_USER="<your-quay-admin-username>"
export QUAY_PASS="<your-quay-admin-password>"
export QUAY_EMAIL="<your-email>"
export QUAY_HOST="<your-quay-host>"
export QUAY_DR_HOST="<your-quay-dr-host>"

# ── Kasten ───────────────────────────────────────────────────────────────────
export KASTEN_NS="kasten-io"
export KASTEN_PROFILE="<your-location-profile>"
export KASTEN_POLICY="<your-policy-name>"

# ── Storage ───────────────────────────────────────────────────────────────────
export STORAGE_NS="openshift-storage"
export STORAGE_CLASS="<your-storage-class>"

# ── Test App ──────────────────────────────────────────────────────────────────
export TEST_APP_NS="test-app"
export TEST_APP_DR_NS="test-app-dr"
```

```bash
# Source before every session
source ./env.sh
oc whoami
```

---

## METHOD A — Manual Backup & Restore

### A1. BACKUP

#### Pre-Backup Checklist
- [ ] Logged into OCP cluster (`oc whoami`)
- [ ] Source Quay is Available (`oc get quayregistry -n ${SOURCE_NS}`)
- [ ] `python3`, `PyYAML`, `aws` CLI available locally
- [ ] Sufficient local disk space for blobs

#### Run the Script
```bash
export BACKUP_DIR="./<your-policy-name>-$(date +%Y%m%d-%H%M%S)"
bash 02_quay_backup.sh
```

#### Expected Backup Artifacts
```
<your-policy-name>-YYYYMMDD-HHMMSS/
├── quay-registry.yaml          # QuayRegistry CR (runtime fields stripped)
├── managed-secret-keys.yaml    # Managed secret keys (ownerReferences stripped)
├── config-bundle.yaml          # Config bundle secret
├── backup.sql                  # PostgreSQL dump (~324K)
└── blobs/                      # NooBaa object storage (11 files)
    └── datastorage/registry/sha256/...
```

---

### A2. RESTORE (Manual)

#### Pre-Restore Checklist
- [ ] `BACKUP_DIR` points to a valid backup folder
- [ ] DR namespace `quay-dr` has Quay Operator running
- [ ] DR namespace has **NO** existing QuayRegistry CR
- [ ] DR namespace has **NO** stale Quay secrets

#### Clean DR Namespace Before Restore
```bash
# Delete existing QuayRegistry CR if present
oc delete quayregistry ${QUAY_CR_NAME} -n ${DR_NS} 2>/dev/null || true
sleep 30

# Remove all stale Quay secrets (keep dockercfg system secrets)
oc get secrets -n ${DR_NS} --no-headers \
  | grep -v "dockercfg\|default-token\|pipeline\|builder\|deployer" \
  | awk '{print $1}' \
  | xargs -r oc delete secret -n ${DR_NS} 2>/dev/null || true

# Delete Quay PVCs
oc delete pvc quay-registry-clair-postgres-15 \
  quay-registry-quay-postgres-13 \
  -n ${DR_NS} 2>/dev/null || true

# Verify clean state
oc get pods -n ${DR_NS}
oc get quayregistry -n ${DR_NS} 2>/dev/null || echo "No CR"
oc get secrets -n ${DR_NS} | grep -v dockercfg
```

#### Run the Script
```bash
export BACKUP_DIR="./<your-policy-name>-20260319-100441"  # your actual folder
bash 03_quay_restore.sh
```

---

## METHOD B — Kasten Blueprint Backup & Restore

### B1. One-Time Setup

#### Deploy Blueprint and RBAC
```bash
# Deploy RBAC (required for Kanister pod permissions)
kubectl apply -f 10_quay-kanister-rbac.yaml

# Deploy blueprint
kubectl apply -f 04_quay-kanister-blueprint-lab.yaml -n ${KASTEN_NS}

# Verify
kubectl get blueprint quay-operator-blueprint-lab -n ${KASTEN_NS}
kubectl get clusterrole quay-kanister-role
```

#### Annotate the Quay Deployment
```bash
# Annotate quay-app Deployment — NOT the QuayRegistry CR or namespace
kubectl annotate deployment quay-registry-quay-app \
  -n ${SOURCE_NS} \
  kanister.kasten.io/blueprint='quay-operator-blueprint-lab' \
  --overwrite

# Verify
kubectl get deployment quay-registry-quay-app \
  -n ${SOURCE_NS} \
  -o jsonpath='{.metadata.annotations.kanister\.kasten\.io/blueprint}'
echo ""
```

> ⚠️ **Critical:** The annotation must be on the **Deployment** workload.  
> Annotating the QuayRegistry CR or the namespace will not work.

#### Create Kasten Policy
```bash
cat <<EOF | kubectl create -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: ${KASTEN_POLICY}
  namespace: ${KASTEN_NS}
spec:
  comment: "Backup policy for RH Quay Operator"
  frequency: "@onDemand"
  paused: false
  actions:
  - action: backup
    backupParameters:
      profile:
        name: ${KASTEN_PROFILE}
        namespace: ${KASTEN_NS}
  selector:
    matchExpressions:
    - key: k10.kasten.io/appNamespace
      operator: In
      values:
      - ${SOURCE_NS}
EOF
```

---

### B2. BACKUP via Kasten

#### Trigger Backup
```bash
cat <<EOF | kubectl create -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: <your-policy-name>-run-
  namespace: ${KASTEN_NS}
spec:
  subject:
    kind: Policy
    name: ${KASTEN_POLICY}
    namespace: ${KASTEN_NS}
EOF
```

#### Monitor Backup
```bash
# Watch run action status
kubectl get runactions -n ${KASTEN_NS} \
  --sort-by='.metadata.creationTimestamp' | tail -5

# Watch kanister pod logs
kubectl logs -n ${KASTEN_NS} \
  $(kubectl get pods -n ${KASTEN_NS} --no-headers \
    | grep kanister-job \
    | grep -v Completed \
    | awk '{print $1}' | tail -1) \
  --follow
```

#### Verify Backup Succeeded
```bash
# Get latest run action name
export BACKUP_RUN=$(kubectl get runactions -n ${KASTEN_NS} \
  --sort-by='.metadata.creationTimestamp' \
  --no-headers | tail -1 | awk '{print $1}')

kubectl get runaction ${BACKUP_RUN} -n ${KASTEN_NS} \
  -o jsonpath='{.status.state}'
echo ""
```

✅ **Expected:** `Complete`

#### Where Are the Backup Files Stored?
Kasten stores backups as **kopia snapshots** in your S3 location profile (`<your-location-profile>`). They are not raw files — they are deduplicated and compressed kopia archives at these logical paths:

```
<your-policy-name>s/quay/config/config.tar.gz     ← QuayRegistry CR + secrets
<your-policy-name>s/quay/database/backup.sql      ← PostgreSQL dump
<your-policy-name>s/quay/blobs/blobs.tar.gz       ← NooBaa image blobs
```

---

### B3. RESTORE via Kasten

#### Pre-Restore Checklist
- [ ] Backup run shows `Complete`
- [ ] DR namespace `quay-dr` has Quay Operator running
- [ ] DR namespace is clean (no existing QuayRegistry CR or Quay secrets)

#### Clean DR Namespace
```bash
# Delete existing QuayRegistry CR
oc delete quayregistry ${QUAY_CR_NAME} -n ${DR_NS} 2>/dev/null || true
sleep 30

# Remove stale Quay secrets
oc get secrets -n ${DR_NS} --no-headers \
  | grep -v "dockercfg\|default-token\|pipeline\|builder\|deployer" \
  | awk '{print $1}' \
  | xargs -r oc delete secret -n ${DR_NS} 2>/dev/null || true

# Delete Quay PVCs only (do NOT delete non-Quay PVCs)
oc get pvc -n ${DR_NS} --no-headers \
  | grep "quay-registry" \
  | awk '{print $1}' \
  | xargs -r oc delete pvc -n ${DR_NS} 2>/dev/null || true

# Verify
oc get pods -n ${DR_NS}
oc get quayregistry -n ${DR_NS} 2>/dev/null || echo "✅ No CR"
```

#### Trigger Restore via Kasten UI

1. **Kasten Dashboard** → **Applications**
2. Find `quay` → click restore points icon
3. Select the restore point → click **Restore**
4. Enable **"Restore to a different namespace"** → select `quay-dr`
5. Under **Advanced Options → Resource Filter** add these **Exclude Resources**:

| Resource | API Group | Reason |
|---|---|---|
| `services` | `""` | Operator manages these — conflict on restore |
| `horizontalpodautoscalers` | `autoscaling` | Operator manages these |
| `deployments` | `apps` | Operator manages these |
| `replicasets` | `apps` | Operator manages these |
| `endpoints` | `""` | Auto-created from services |

> ⚠️ **Critical:** These exclusions are required. Without them Kasten will conflict  
> with the Quay Operator which simultaneously manages the same resources.

6. Click **Restore**

#### Monitor Restore
```bash
# Watch kanister pod logs
kubectl logs -n ${KASTEN_NS} \
  $(kubectl get pods -n ${KASTEN_NS} --no-headers \
    | grep kanister-job \
    | grep -v Completed \
    | awk '{print $1}' | tail -1) \
  --follow

# Watch DR pods come up
oc get pods -n ${DR_NS} -w
```

#### Expected Restore Phase Progression
| Phase | What Happens |
|---|---|
| `restoreConfig` | Cleans stale secrets, applies managed-secret-keys, creates QuayRegistry CR |
| `waitForQuay` | Waits for Available=True, patches config, flushes Redis |
| `scaleDownDR` | Disables HPA (with retry loop), scales to 0 |
| `restoreDatabase` | Pulls backup.sql, drops and restores PostgreSQL DB |
| `restoreStorage` | Pulls blobs, syncs to DR NooBaa bucket |
| `scaleUpDR` | Brings up at replicas:1, suppresses HPA for 90s |
| `resetPassword` | Generates bcrypt hash, updates DB, flushes Redis |

#### If HPA Scales Up Beyond 1 Replica (Lab Environment)
The blueprint suppresses HPA for 90 seconds but on resource-constrained clusters you may need to run this manually:

```bash
for i in $(seq 1 9); do
  echo "HPA suppression ${i}/9..."
  oc delete hpa --all -n ${DR_NS} 2>/dev/null || true
  sleep 10
done

oc patch quayregistry ${QUAY_CR_NAME} -n ${DR_NS} \
  --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false},
      {"kind":"quay",  "managed":true,"overrides":{"replicas":1}},
      {"kind":"clair", "managed":true,"overrides":{"replicas":1}},
      {"kind":"mirror","managed":true,"overrides":{"replicas":1}}
    ]}
  }'
```

---

### B4. VERIFY RESTORE

#### Step 1 — Check DR Quay is Available
```bash
oc get quayregistry ${QUAY_CR_NAME} -n ${DR_NS} \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
echo ""

oc get pods -n ${DR_NS} | grep -v Completed
```

✅ **Expected:** `True`, exactly 1 pod per component

#### Step 2 — Test Login to DR Registry
```bash
podman login \
  --tls-verify=false \
  --username ${QUAY_USER} \
  --password ${QUAY_PASS} \
  ${QUAY_DR_HOST}
```

✅ **Expected:** `Login Succeeded!`

> Note: The `resetPassword` blueprint phase handles this automatically.  
> If login fails, the phase may have not completed — run manually:
```bash
export DR_PG_POD=$(oc get pod -l quay-component=postgres \
  -n ${DR_NS} -o jsonpath='{.items[0].metadata.name}')

python3 - <<'PYEOF'
import bcrypt
password = "<your-quay-admin-password>".encode('utf-8')
hashed = bcrypt.hashpw(password, bcrypt.gensalt(12)).decode('utf-8')
sql = f"UPDATE public.user SET password_hash = '{hashed}' WHERE username = '<your-quay-admin-username>';"
with open('/tmp/reset_pw.sql', 'w') as f:
    f.write(sql)
print(f"Hash: {hashed[:20]}...")
PYEOF

oc cp /tmp/reset_pw.sql -n ${DR_NS} ${DR_PG_POD}:/tmp/reset_pw.sql
oc rsh -n ${DR_NS} ${DR_PG_POD} \
  bash -c "psql -d quay-registry-quay-database -f /tmp/reset_pw.sql"

oc rsh -n ${DR_NS} \
  $(oc get pod -l quay-component=redis -n ${DR_NS} \
    -o jsonpath='{.items[0].metadata.name}') \
  bash -c "redis-cli FLUSHALL"
```

#### Step 3 — Deploy DR Test App and Verify Image Pull
```bash
# Create namespace and pull secret
kubectl create ns ${TEST_APP_DR_NS} 2>/dev/null || true

kubectl -n ${TEST_APP_DR_NS} create secret docker-registry quay-dr-pull-secret \
  --docker-server=${QUAY_DR_HOST} \
  --docker-username=${QUAY_USER} \
  --docker-password=${QUAY_PASS} \
  --docker-email=${QUAY_EMAIL} \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy test app
kubectl apply -f 09_test-app-dr.yaml

# Wait for pod
kubectl wait pod \
  -l app=test-app-dr \
  -n ${TEST_APP_DR_NS} \
  --for=condition=Ready \
  --timeout=180s

# Verify image pulled from DR registry
kubectl describe pod \
  $(kubectl get pod -l app=test-app-dr \
    -n ${TEST_APP_DR_NS} \
    -o jsonpath='{.items[0].metadata.name}') \
  -n ${TEST_APP_DR_NS} \
  | grep -A 5 "Events:"
```

✅ **Confirmed DR pull:**
```
Normal  Pulling  Pulling image "<your-quay-dr-host>/<your-username>/busybox"
Normal  Pulled   Successfully pulled image "<your-quay-dr-host>/..."
```

---

## Lessons Learned

| # | Finding | Impact | Fix Applied |
|---|---|---|---|
| 1 | Config bundle secret deleted by operator if pre-created | Restore blocked | Let operator bootstrap it, patch config after |
| 2 | DB name via `awk` on `DB_URI` corrupts with special chars in password | pg_dump fails | Use `psql -tAc SELECT` direct query |
| 3 | Backup order must be config → DB → storage → scale down | DB inaccessible if scaled down first | Fixed phase order in blueprint |
| 4 | HPA recreated faster than single patch | Runaway scaling, pods stuck Pending | 90s loop deleting HPA every 10s |
| 5 | DR namespace needs `replicas:1` on shared clusters | CPU requests exhausted | Hardcoded replicas:1 in scaleUpDR |
| 6 | `kando location push --dir` flag does not exist | Backup fails | Use `tar \| kando ... -` stdin instead |
| 7 | `kando location pull` does not take positional `-` arg | Restore tar corrupted | Remove trailing `-` from pull commands |
| 8 | Kasten conflicts with Quay Operator on Service/HPA restore | Restore fails | Exclude `services`, `deployments`, `replicasets`, `hpa` from Kasten restore |
| 9 | Restored DB has wrong password hash | Login fails with 500 error | `resetPassword` blueprint phase with bcrypt |
| 10 | Blueprint must annotate Deployment, not QuayRegistry CR | Nil pointer template error | Annotate `quay-registry-quay-app` Deployment |
| 11 | `python3 -c` inline heredocs cause YAML parse errors | Blueprint rejected | Base64-encoded Python scripts decoded at runtime |
| 12 | `{{ .Namespace.Name }}` nil on Deployment-annotated blueprint | Template error | Use `{{ .Deployment.Namespace }}` throughout |

---

## Quick Reference

```bash
# Re-source variables
source ./env.sh

# Check source Quay health
oc get quayregistry ${QUAY_CR_NAME} -n ${SOURCE_NS}
oc get pods -n ${SOURCE_NS}

# Check DR Quay health
oc get quayregistry ${QUAY_CR_NAME} -n ${DR_NS}
oc get pods -n ${DR_NS}

# Check Kasten run actions
kubectl get runactions -n ${KASTEN_NS} \
  --sort-by='.metadata.creationTimestamp' | tail -5

# Watch kanister logs
kubectl logs -n ${KASTEN_NS} \
  $(kubectl get pods -n ${KASTEN_NS} --no-headers \
    | grep kanister-job | grep -v Completed \
    | awk '{print $1}' | tail -1) --follow

# Force image pull verification
kubectl describe pod \
  $(kubectl get pod -l app=test-app-dr \
    -n ${TEST_APP_DR_NS} \
    -o jsonpath='{.items[0].metadata.name}') \
  -n ${TEST_APP_DR_NS} | grep -A 5 "Events:"

# Verify DR image pull from registry
podman pull --tls-verify=false \
  ${QUAY_DR_HOST}/${QUAY_USER}/busybox:latest
```
