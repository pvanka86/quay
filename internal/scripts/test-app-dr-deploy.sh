#!/usr/bin/env bash
# =============================================================================
# DR Test App — Deploy Script
# Creates pull secret and deploys test app in test-app-dr namespace
#
# When to run:
#   - After a successful Kasten blueprint restore into quay-dr
#   - The blueprint resetPassword phase handles password reset automatically
#
# If login fails after a MANUAL restore (not blueprint):
#   Run internal/scripts/quay_restore.sh which includes password reset
#   Or set RESET_PASSWORD=true to trigger it here
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# VARIABLES — override via env or edit here
# ---------------------------------------------------------------------------
DR_NS="${DR_NS:-quay-dr}"
QUAY_USER="${QUAY_USER:-praveen}"
QUAY_PASS="${QUAY_PASS:-password}"
QUAY_EMAIL="${QUAY_EMAIL:-praveen@example.com}"
QUAY_DR_HOST="${QUAY_DR_HOST:-quay-registry-quay-quay-dr.apps.kasten-se-lab-baremetal.kasten.veeam.local}"
TEST_APP_DR_NS="${TEST_APP_DR_NS:-test-app-dr}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"
RESET_PASSWORD="${RESET_PASSWORD:-false}"   # set to true only for manual restores

info()    { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# STEP 1 — Optional password reset (manual restore only)
# Blueprint restore handles this automatically via resetPassword phase
# ---------------------------------------------------------------------------
if [[ "${RESET_PASSWORD}" == "true" ]]; then
  info "Step 1: Resetting Quay DR admin password (manual restore mode)..."

  python3 -c "import bcrypt" 2>/dev/null || pip3 install bcrypt --quiet

  DR_PG_POD=$(oc get pod \
    -l quay-component=postgres \
    -n "${DR_NS}" \
    -o jsonpath='{.items[0].metadata.name}')

  echo "  PostgreSQL pod: ${DR_PG_POD}"

  python3 - <<PYEOF
import bcrypt
password = "${QUAY_PASS}".encode('utf-8')
hashed = bcrypt.hashpw(password, bcrypt.gensalt(12)).decode('utf-8')
sql = f"UPDATE public.user SET password_hash = '{hashed}' WHERE username = '${QUAY_USER}';"
with open('/tmp/reset_pw.sql', 'w') as f:
    f.write(sql)
print(f"  Hash preview: {hashed[:20]}...")
PYEOF

  oc cp /tmp/reset_pw.sql -n "${DR_NS}" "${DR_PG_POD}:/tmp/reset_pw.sql"
  oc exec -n "${DR_NS}" "${DR_PG_POD}" -- \
    psql -d "quay-registry-quay-database" -f /tmp/reset_pw.sql

  DR_REDIS_POD=$(oc get pod \
    -l quay-component=redis \
    -n "${DR_NS}" \
    -o jsonpath='{.items[0].metadata.name}')
  oc rsh -n "${DR_NS}" "${DR_REDIS_POD}" \
    bash -c "redis-cli FLUSHALL" || true

  success "Password reset and Redis flushed"
else
  info "Step 1: Skipping password reset (blueprint restore handles this automatically)"
fi

# ---------------------------------------------------------------------------
# STEP 2 — Verify login to DR registry
# ---------------------------------------------------------------------------
info "Step 2: Verifying login to DR registry..."
podman login \
  --tls-verify=false \
  --username "${QUAY_USER}" \
  --password "${QUAY_PASS}" \
  "${QUAY_DR_HOST}" \
  || die "Login failed. If this was a manual restore, re-run with RESET_PASSWORD=true"

success "Login to DR registry succeeded"

# ---------------------------------------------------------------------------
# STEP 3 — Create namespace and pull secret
# ---------------------------------------------------------------------------
info "Step 3: Creating namespace and pull secret..."

kubectl create ns "${TEST_APP_DR_NS}" 2>/dev/null \
  || echo "  Namespace already exists"

kubectl -n "${TEST_APP_DR_NS}" create secret docker-registry quay-dr-pull-secret \
  --docker-server="${QUAY_DR_HOST}" \
  --docker-username="${QUAY_USER}" \
  --docker-password="${QUAY_PASS}" \
  --docker-email="${QUAY_EMAIL}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "Pull secret created in ${TEST_APP_DR_NS}"

# ---------------------------------------------------------------------------
# STEP 4 — Deploy test app
# ---------------------------------------------------------------------------
info "Step 4: Deploying test app..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-app-dr-pvc
  namespace: ${TEST_APP_DR_NS}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app-dr-deploy
  namespace: ${TEST_APP_DR_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app-dr
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: test-app-dr
    spec:
      containers:
      - name: test-app-dr-container
        image: ${QUAY_DR_HOST}/${QUAY_USER}/busybox
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "while true; do sleep 3600; done"]
        volumeMounts:
        - mountPath: /data
          name: data
      imagePullSecrets:
      - name: quay-dr-pull-secret
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: test-app-dr-pvc
EOF

# ---------------------------------------------------------------------------
# STEP 5 — Wait and verify
# ---------------------------------------------------------------------------
info "Step 5: Waiting for pod to become Ready..."

kubectl wait pod \
  -l app=test-app-dr \
  -n "${TEST_APP_DR_NS}" \
  --for=condition=Ready \
  --timeout=180s

echo ""
echo "=== Pod status ==="
kubectl get pods,pvc -n "${TEST_APP_DR_NS}"

echo ""
echo "=== Image pull verification ==="
kubectl describe pod \
  $(kubectl get pod -l app=test-app-dr \
    -n "${TEST_APP_DR_NS}" \
    -o jsonpath='{.items[0].metadata.name}') \
  -n "${TEST_APP_DR_NS}" \
  | grep -A 3 "Events:"

success "DR test app deployed and verified"
echo ""
echo "Usage for manual restores: RESET_PASSWORD=true bash test-app-dr-deploy.sh"
