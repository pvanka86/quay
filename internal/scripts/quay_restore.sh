#!/usr/bin/env bash
# =============================================================================
# RH Quay Operator — Restore Script v2.0.0
# Target:    OpenShift Container Platform (OCP)
# Quay Ver:  3.13.2
# Namespace: quay-dr (DR target — operator installed, NO CR yet)
#
# Production-validated fixes in v2.0.0:
#   - Config bundle secret NOT pre-created — operator must bootstrap it fresh
#   - QuayRegistry CR applied without configBundleSecret reference
#   - Operator allowed to initialize fully before scale-down
#   - HPA deleted directly (not just patched) to prevent runaway scaling
#   - DR namespace runs with replicas:1 to avoid CPU request exhaustion
#   - DB name queried from psql directly (not awk/grep parsing)
#   - Stale secrets cleaned from DR namespace before restore
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURABLE VARIABLES — override via env or edit here
# ---------------------------------------------------------------------------
SOURCE_NS="${SOURCE_NS:-quay}"
DR_NS="${DR_NS:-quay-dr}"
QUAY_CR_NAME="${QUAY_CR_NAME:-quay-registry}"
BACKUP_DIR="${BACKUP_DIR:-}"
STORAGE_NS="${STORAGE_NS:-openshift-storage}"
QUAY_USER="${QUAY_USER:-praveen}"
QUAY_PASS="${QUAY_PASS:-password}"
QUAY_EMAIL="${QUAY_EMAIL:-praveen@example.com}"
QUAY_DR_HOST="${QUAY_DR_HOST:-quay-registry-quay-quay-dr.apps.kasten-se-lab-baremetal.kasten.veeam.local}"
TEST_APP_DR_NS="${TEST_APP_DR_NS:-test-app-dr}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# STEP 0 — Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
  info "Step 0: Checking prerequisites..."
  [[ -z "$BACKUP_DIR" ]] && die "BACKUP_DIR must be set. E.g.: BACKUP_DIR=./quay-backup-20260319-100441 $0"
  [[ -d "$BACKUP_DIR" ]] || die "Backup directory not found: $BACKUP_DIR"

  for f in quay-registry.yaml managed-secret-keys.yaml config-bundle.yaml backup.sql; do
    [[ -f "${BACKUP_DIR}/${f}" ]] || die "Required backup artifact missing: ${BACKUP_DIR}/${f}"
  done
  for cmd in oc kubectl aws python3; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
  oc whoami &>/dev/null || die "Not logged in to OpenShift. Run 'oc login' first."

  python3 -c "import yaml" 2>/dev/null || {
    info "Installing PyYAML..."
    python3 -m pip install PyYAML --quiet
  }
  success "Prerequisites OK — backup dir: $BACKUP_DIR"
}

# ---------------------------------------------------------------------------
# STEP 1 — Clean DR namespace
# Remove any stale Quay secrets/CRs — operator and system secrets are kept
# ---------------------------------------------------------------------------
step1_clean_dr_namespace() {
  info "Step 1: Cleaning DR namespace '$DR_NS'..."

  # Check for existing QuayRegistry CR
  local existing_cr
  existing_cr=$(oc get quayregistry -n "$DR_NS" --no-headers 2>/dev/null | wc -l)
  if [[ "$existing_cr" -gt 0 ]]; then
    warn "Found existing QuayRegistry CR — deleting..."
    oc delete quayregistry "$QUAY_CR_NAME" -n "$DR_NS" --timeout=120s || true
    sleep 10
  fi

  # Remove stale Quay secrets (not system dockercfg secrets)
  info "Removing stale Quay secrets..."
  oc get secrets -n "$DR_NS" --no-headers \
    | grep -v "dockercfg\|default-token\|pipeline\|builder\|deployer" \
    | awk '{print $1}' \
    | xargs -r oc delete secret -n "$DR_NS" 2>/dev/null || true

  info "DR namespace state after cleanup:"
  oc get all -n "$DR_NS" 2>/dev/null || true
  success "DR namespace cleaned"
}

# ---------------------------------------------------------------------------
# STEP 2 — Patch namespace in backup manifests
# ---------------------------------------------------------------------------
step2_patch_namespace() {
  info "Step 2: Patching namespace in backup manifests (${SOURCE_NS} → ${DR_NS})..."

  for f in quay-registry.yaml managed-secret-keys.yaml config-bundle.yaml; do
    sed "s/namespace: ${SOURCE_NS}/namespace: ${DR_NS}/g" \
      "${BACKUP_DIR}/${f}" > "${BACKUP_DIR}/dr-${f}"
    echo "  ✓ Created ${BACKUP_DIR}/dr-${f}"
  done

  # Verify all three show DR namespace
  info "Namespace verification:"
  grep "namespace:" "${BACKUP_DIR}"/dr-*.yaml
  success "Namespace patched in all manifests"
}

# ---------------------------------------------------------------------------
# STEP 3 — Restore managed-secret-keys
# Must be applied BEFORE the QuayRegistry CR
# ---------------------------------------------------------------------------
step3_restore_managed_secrets() {
  info "Step 3: Restoring managed-secret-keys into '$DR_NS'..."
  oc create -f "${BACKUP_DIR}/dr-managed-secret-keys.yaml" 2>/dev/null \
    || oc replace -f "${BACKUP_DIR}/dr-managed-secret-keys.yaml"

  oc get secret \
    "${QUAY_CR_NAME}-quay-registry-managed-secret-keys" \
    -n "$DR_NS" \
    || die "Managed secret keys not found after restore"
  success "Managed secret keys restored"
}

# ---------------------------------------------------------------------------
# STEP 4 — Restore QuayRegistry CR WITHOUT configBundleSecret
# IMPORTANT: Do NOT pre-create the config bundle secret.
# The operator will create it fresh and bootstrap all components.
# We patch config data into it AFTER the operator initializes.
# ---------------------------------------------------------------------------
step4_restore_quay_cr() {
  info "Step 4: Restoring QuayRegistry CR into '$DR_NS'..."

  # Strip configBundleSecret from the CR — operator will create a new one
  python3 - <<PYEOF
import yaml

path = "${BACKUP_DIR}/dr-quay-registry.yaml"
with open(path) as f:
    doc = yaml.safe_load(f)

doc.get('spec', {}).pop('configBundleSecret', None)

with open(path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)

print(f"  Removed configBundleSecret from CR spec")
PYEOF

  oc create -f "${BACKUP_DIR}/dr-quay-registry.yaml" \
    || die "Failed to create QuayRegistry CR in '$DR_NS'"
  success "QuayRegistry CR created in '$DR_NS'"
}

# ---------------------------------------------------------------------------
# STEP 5 — Wait for operator to bootstrap and become Available
# ---------------------------------------------------------------------------
step5_wait_for_bootstrap() {
  info "Step 5: Waiting for Quay operator to bootstrap (up to 15 min)..."
  oc wait quayregistry "$QUAY_CR_NAME" \
    --for=condition=Available=true \
    -n "$DR_NS" \
    --timeout=900s || die "Quay CR did not become Available — check operator logs"

  info "Pods in $DR_NS:"
  oc get pods -n "$DR_NS"
  success "Quay bootstrapped and Available in '$DR_NS'"
}

# ---------------------------------------------------------------------------
# STEP 6 — Patch backed-up config data into the operator-created secret
# ---------------------------------------------------------------------------
step6_patch_config_bundle() {
  info "Step 6: Patching backed-up config data into DR config bundle secret..."

  # Get the name of the secret the operator just created
  local new_secret
  new_secret=$(oc get quayregistry "$QUAY_CR_NAME" \
    -n "$DR_NS" \
    -o jsonpath='{.spec.configBundleSecret}')
  echo "  Operator-created secret: $new_secret"

  # Extract config.yaml data from source backup
  local config_data
  config_data=$(oc get secret \
    -n "$SOURCE_NS" \
    "$(oc get quayregistry $QUAY_CR_NAME -n $SOURCE_NS \
      -o jsonpath='{.spec.configBundleSecret}')" \
    -o jsonpath='{.data.config\.yaml}')

  # Patch into DR secret
  oc patch secret "$new_secret" \
    -n "$DR_NS" \
    --type=merge \
    -p "{\"data\":{\"config.yaml\":\"${config_data}\"}}"

  success "Config data patched into $new_secret"
}

# ---------------------------------------------------------------------------
# STEP 7 — Scale DOWN DR Quay before database restore
# Also delete HPA objects directly to prevent runaway scaling
# ---------------------------------------------------------------------------
step7_scale_down_dr() {
  info "Step 7: Scaling down DR Quay before database restore..."

  # Disable HPA via patch
  oc patch quayregistry "$QUAY_CR_NAME" -n "$DR_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false}
    ]}
  }'
  sleep 10

  # Zero out replicas
  oc patch quayregistry "$QUAY_CR_NAME" -n "$DR_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false},
      {"kind":"quay",  "managed":true,"overrides":{"replicas":0}},
      {"kind":"clair", "managed":true,"overrides":{"replicas":0}},
      {"kind":"mirror","managed":true,"overrides":{"replicas":0}}
    ]}
  }'

  # Delete HPA objects directly — prevents operator from scaling back up
  oc delete hpa --all -n "$DR_NS" 2>/dev/null || true

  oc wait pod -l app=quay   -n "$DR_NS" --for=delete --timeout=300s 2>/dev/null || true
  oc wait pod -l app=clair  -n "$DR_NS" --for=delete --timeout=300s 2>/dev/null || true
  oc wait pod -l app=mirror -n "$DR_NS" --for=delete --timeout=300s 2>/dev/null || true

  info "Remaining pods (should be postgres, redis, clair-postgres, operator):"
  oc get pods -n "$DR_NS"
  success "DR Quay scaled to 0"
}

# ---------------------------------------------------------------------------
# STEP 8 — Restore PostgreSQL database
# ---------------------------------------------------------------------------
step8_restore_postgres() {
  info "Step 8: Restoring PostgreSQL database in '$DR_NS'..."

  local dr_pg_pod
  dr_pg_pod=$(oc get pod \
    -l quay-component=postgres \
    -n "$DR_NS" \
    -o jsonpath='{.items[0].metadata.name}')
  [[ -z "$dr_pg_pod" ]] && die "No PostgreSQL pod found in '$DR_NS'"
  echo "  DR PostgreSQL pod: $dr_pg_pod"

  # Get DB name directly from psql
  local db_name
  db_name=$(oc -n "$DR_NS" rsh "$dr_pg_pod" \
    bash -c "psql -tAc \"SELECT datname FROM pg_database \
    WHERE datname NOT IN ('postgres','template0','template1');\"")

  echo "  DB name: $db_name (length: ${#db_name})"

  # Sanity check
  if [[ ${#db_name} -lt 5 || ${#db_name} -gt 60 ]]; then
    warn "DB name length unexpected — using fallback"
    db_name="${QUAY_CR_NAME}-quay-database"
  fi

  # Copy backup into pod
  oc cp "${BACKUP_DIR}/backup.sql" \
    -n "$DR_NS" \
    "${dr_pg_pod}:/tmp/backup.sql"
  success "backup.sql copied to pod"

  # Drop, restore, verify
  oc rsh -n "$DR_NS" "$dr_pg_pod" bash -c "
    echo 'Terminating active connections...'
    psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
      WHERE datname = '${db_name}';\"

    echo 'Dropping existing database...'
    psql -c \"DROP DATABASE IF EXISTS \\\"${db_name}\\\";\"

    echo 'Restoring from backup...'
    psql < /tmp/backup.sql

    echo 'Verifying...'
    psql -c '\l' | grep ${db_name}
  "
  success "PostgreSQL database restored in '$DR_NS'"
}

# ---------------------------------------------------------------------------
# STEP 9 — Restore Object Storage (NooBaa/S3)
# ---------------------------------------------------------------------------
step9_restore_object_storage() {
  info "Step 9: Restoring Object Storage blobs into '$DR_NS'..."
  [[ -d "${BACKUP_DIR}/blobs" ]] || die "Blobs directory not found: ${BACKUP_DIR}/blobs"

  export AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_ID=$(oc get secret -l app=noobaa \
    -n "$DR_NS" \
    -o jsonpath='{.items[0].data.AWS_ACCESS_KEY_ID}' | base64 -d)

  export AWS_SECRET_ACCESS_KEY
  AWS_SECRET_ACCESS_KEY=$(oc get secret -l app=noobaa \
    -n "$DR_NS" \
    -o jsonpath='{.items[0].data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

  local dr_s3_endpoint dr_bucket_name
  dr_s3_endpoint=$(oc get route s3 \
    -n "$STORAGE_NS" \
    -o jsonpath='{.spec.host}')
  dr_bucket_name=$(oc get cm -l app=noobaa \
    -n "$DR_NS" \
    -o jsonpath='{.items[0].data.BUCKET_NAME}')

  echo "  S3 Endpoint : $dr_s3_endpoint"
  echo "  Bucket Name : $dr_bucket_name"

  aws s3 sync \
    --no-verify-ssl \
    --endpoint "https://${dr_s3_endpoint}" \
    "${BACKUP_DIR}/blobs" \
    "s3://${dr_bucket_name}"

  local file_count
  file_count=$(find "${BACKUP_DIR}/blobs" -type f | wc -l)
  success "Object storage restored — $file_count files synced to $dr_bucket_name"
}

# ---------------------------------------------------------------------------
# STEP 10 — Scale DR Quay back UP with replicas:1
# Use replicas:1 on shared clusters to avoid CPU request exhaustion
# ---------------------------------------------------------------------------
step10_scale_up_dr() {
  info "Step 10: Scaling DR Quay back up (replicas:1 to conserve CPU requests)..."

  # Disable HPA and set replicas:1 for all components
  oc patch quayregistry "$QUAY_CR_NAME" -n "$DR_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false},
      {"kind":"quay",  "managed":true,"overrides":{"replicas":1}},
      {"kind":"clair", "managed":true,"overrides":{"replicas":1}},
      {"kind":"mirror","managed":true,"overrides":{"replicas":1}}
    ]}
  }'

  # Delete any remaining HPA objects to prevent rebound scaling
  oc delete hpa --all -n "$DR_NS" 2>/dev/null || true

  sleep 30

  # Re-apply to catch any HPA rebound
  oc patch quayregistry "$QUAY_CR_NAME" -n "$DR_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false},
      {"kind":"quay",  "managed":true,"overrides":{"replicas":1}},
      {"kind":"clair", "managed":true,"overrides":{"replicas":1}},
      {"kind":"mirror","managed":true,"overrides":{"replicas":1}}
    ]}
  }'

  info "Waiting for Quay DR to become Available..."
  oc wait quayregistry "$QUAY_CR_NAME" \
    --for=condition=Available=true \
    -n "$DR_NS" \
    --timeout=900s || die "Quay DR did not become Available"

  info "Final pod state:"
  oc get pods -n "$DR_NS"
  success "DR Quay is Available"
}

# ---------------------------------------------------------------------------
# STEP 11 — Create ImagePullSecret and test pod in DR test namespace
# ---------------------------------------------------------------------------
step11_verify_restore() {
  info "Step 11: Verifying restore with test pod..."

  # Create DR test namespace
  kubectl create ns "$TEST_APP_DR_NS" 2>/dev/null \
    || warn "Namespace '$TEST_APP_DR_NS' already exists"

  # Create ImagePullSecret
  kubectl -n "$TEST_APP_DR_NS" create secret docker-registry quay-dr-pull-secret \
    --docker-server="$QUAY_DR_HOST" \
    --docker-username="$QUAY_USER" \
    --docker-password="$QUAY_PASS" \
    --docker-email="$QUAY_EMAIL" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Deploy test pod
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-dr-pod
  namespace: ${TEST_APP_DR_NS}
spec:
  containers:
  - name: busybox
    image: ${QUAY_DR_HOST}/${QUAY_USER}/busybox:latest
    imagePullPolicy: Always
    command:
    - sh
    - -c
    - |
      echo "DR image pull successful"
      echo "Running from: \$(hostname)"
      sleep 3600
  imagePullSecrets:
  - name: quay-dr-pull-secret
EOF

  info "Waiting for test pod to become Ready..."
  kubectl wait pod test-dr-pod \
    -n "$TEST_APP_DR_NS" \
    --for=condition=Ready \
    --timeout=120s \
    || die "Test pod failed to start — check image pull"

  info "Test pod logs:"
  kubectl logs test-dr-pod -n "$TEST_APP_DR_NS"

  success "Restore verified — image pulled and pod running from DR registry"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  info "============================================================"
  info " RH Quay Operator — Restore v2.0.0"
  info " Source NS : $SOURCE_NS"
  info " DR NS     : $DR_NS"
  info " Quay CR   : $QUAY_CR_NAME"
  info " Backup    : $BACKUP_DIR"
  info "============================================================"

  check_prereqs
  step1_clean_dr_namespace
  step2_patch_namespace
  step3_restore_managed_secrets
  step4_restore_quay_cr
  step5_wait_for_bootstrap
  step6_patch_config_bundle
  step7_scale_down_dr
  step8_restore_postgres
  step9_restore_object_storage
  step10_scale_up_dr
  step11_verify_restore

  info "============================================================"
  success "RESTORE COMPLETE"
  info "  Quay DR UI : https://${QUAY_DR_HOST}/${QUAY_USER}/"
  info "  Test NS    : $TEST_APP_DR_NS"
  info "============================================================"
}

main "$@"
