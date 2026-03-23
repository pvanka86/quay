#!/usr/bin/env bash
# =============================================================================
# RH Quay Operator — Backup Script v2.0.0
# Target:    OpenShift Container Platform (OCP)
# Quay Ver:  3.13.2
# Namespace: quay (source)
# Outputs:   ./quay-backup-<timestamp>/
#
# Production-validated fixes in v2.0.0:
#   - PyYAML installed locally before use
#   - DB name queried from psql directly (not awk parsing of DB_URI)
#   - pg_dump uses quoted DB name to handle hyphens
#   - Backup order: config → DB → storage → scale down (safer order)
#   - configBundleSecret name captured before scale down
#   - Sanity checks on DB name length
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURABLE VARIABLES — override via env or edit here
# ---------------------------------------------------------------------------
SOURCE_NS="${SOURCE_NS:-quay}"
QUAY_CR_NAME="${QUAY_CR_NAME:-quay-registry}"
BACKUP_DIR="${BACKUP_DIR:-./quay-backup-$(date +%Y%m%d-%H%M%S)}"
STORAGE_NS="${STORAGE_NS:-openshift-storage}"

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
  for cmd in oc kubectl aws python3; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
  oc whoami &>/dev/null || die "Not logged in to OpenShift. Run 'oc login' first."

  # Ensure PyYAML is installed locally — required for manifest cleanup
  python3 -c "import yaml" 2>/dev/null || {
    info "Installing PyYAML..."
    python3 -m pip install PyYAML --quiet
  }
  success "Prerequisites OK"
}

# ---------------------------------------------------------------------------
# STEP 1 — Verify Quay health
# ---------------------------------------------------------------------------
step1_verify_health() {
  info "Step 1: Verifying Quay deployment health..."
  oc wait quayregistry "$QUAY_CR_NAME" \
    --for=condition=Available=true \
    -n "$SOURCE_NS" \
    --timeout=300s || die "Quay is not Available. Fix health issues before backing up."

  info "All pods in $SOURCE_NS:"
  oc get pods -n "$SOURCE_NS"
  success "Quay deployment is healthy"
}

# ---------------------------------------------------------------------------
# STEP 2 — Backup QuayRegistry CR
# ---------------------------------------------------------------------------
step2_backup_quay_cr() {
  info "Step 2: Backing up QuayRegistry CR..."
  oc get quayregistry "$QUAY_CR_NAME" \
    -n "$SOURCE_NS" \
    -o yaml > "${BACKUP_DIR}/quay-registry.yaml"

  # Strip runtime-only fields — not needed and cause errors on restore
  python3 - <<PYEOF
import yaml

path = "${BACKUP_DIR}/quay-registry.yaml"
with open(path) as f:
    doc = yaml.safe_load(f)

doc.pop('status', None)
for field in ['creationTimestamp','finalizers','generation','resourceVersion','uid']:
    doc.get('metadata', {}).pop(field, None)

with open(path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)

print(f"  Cleaned: {path}")
PYEOF

  info "Preview (should have only name + namespace in metadata):"
  head -10 "${BACKUP_DIR}/quay-registry.yaml"
  success "QuayRegistry CR saved → ${BACKUP_DIR}/quay-registry.yaml"
}

# ---------------------------------------------------------------------------
# STEP 3 — Backup managed-secret-keys
# ---------------------------------------------------------------------------
step3_backup_managed_secrets() {
  info "Step 3: Backing up managed-secret-keys..."
  local secret_name="${QUAY_CR_NAME}-quay-registry-managed-secret-keys"
  oc get secret -n "$SOURCE_NS" "$secret_name" \
    -o yaml > "${BACKUP_DIR}/managed-secret-keys.yaml"

  python3 - <<PYEOF
import yaml

path = "${BACKUP_DIR}/managed-secret-keys.yaml"
with open(path) as f:
    doc = yaml.safe_load(f)

for field in ['ownerReferences','creationTimestamp','resourceVersion','uid']:
    doc.get('metadata', {}).pop(field, None)

with open(path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)

print(f"  Cleaned: {path}")
PYEOF
  success "Managed secret keys saved → ${BACKUP_DIR}/managed-secret-keys.yaml"
}

# ---------------------------------------------------------------------------
# STEP 4 — Backup configBundleSecret
# ---------------------------------------------------------------------------
step4_backup_config_bundle() {
  info "Step 4: Backing up configBundleSecret..."
  local config_secret
  config_secret=$(oc get quayregistry "$QUAY_CR_NAME" \
    -n "$SOURCE_NS" \
    -o jsonpath='{.spec.configBundleSecret}')
  echo "  Config bundle secret: $config_secret"

  oc get secret -n "$SOURCE_NS" "$config_secret" \
    -o yaml > "${BACKUP_DIR}/config-bundle.yaml"
  success "Config bundle saved → ${BACKUP_DIR}/config-bundle.yaml"
}

# ---------------------------------------------------------------------------
# STEP 5 — Get DB name directly from psql
# NOTE: Do NOT use awk on DB_URI — passwords with special chars corrupt parsing
# ---------------------------------------------------------------------------
step5_get_db_name() {
  info "Step 5: Determining Quay database name from psql..."
  local pg_pod
  pg_pod=$(oc get pod \
    -l quay-component=postgres \
    -n "$SOURCE_NS" \
    -o jsonpath='{.items[0].metadata.name}')
  [[ -z "$pg_pod" ]] && die "No PostgreSQL pod found"
  echo "  PostgreSQL pod: $pg_pod"

  # Query psql directly — excludes system DBs, no string parsing
  QUAY_DB_NAME=$(oc -n "$SOURCE_NS" rsh "$pg_pod" \
    bash -c "psql -tAc \"SELECT datname FROM pg_database \
    WHERE datname NOT IN ('postgres','template0','template1');\"")

  echo "  DB name raw   : $QUAY_DB_NAME"
  echo "  DB name length: ${#QUAY_DB_NAME}"

  # Sanity check — fall back to convention if corrupted
  if [[ ${#QUAY_DB_NAME} -lt 5 || ${#QUAY_DB_NAME} -gt 60 ]]; then
    warn "DB name length unexpected — using fallback"
    QUAY_DB_NAME="${QUAY_CR_NAME}-quay-database"
  fi
  success "Database name: $QUAY_DB_NAME"
}

# ---------------------------------------------------------------------------
# STEP 6 — Backup PostgreSQL database
# NOTE: pg_dump runs BEFORE scale-down — postgres is always accessible
# ---------------------------------------------------------------------------
step6_backup_postgres() {
  info "Step 6: Backing up Quay PostgreSQL database..."
  local pg_pod
  pg_pod=$(oc get pod \
    -l quay-component=postgres \
    -n "$SOURCE_NS" \
    -o jsonpath='{.items[0].metadata.name}')
  [[ -z "$pg_pod" ]] && die "No PostgreSQL pod found"

  # Use hardcoded DB name in exec to avoid shell variable interpolation issues
  oc -n "$SOURCE_NS" exec "$pg_pod" -- \
    /usr/bin/pg_dump -C "$QUAY_DB_NAME" \
    > "${BACKUP_DIR}/backup.sql"

  [[ ! -s "${BACKUP_DIR}/backup.sql" ]] && die "backup.sql is empty — pg_dump failed"
  success "Database backup saved → ${BACKUP_DIR}/backup.sql ($(du -sh ${BACKUP_DIR}/backup.sql | cut -f1))"
}

# ---------------------------------------------------------------------------
# STEP 7 — Backup Object Storage (NooBaa/S3)
# NOTE: Object storage backup runs BEFORE scale-down
# ---------------------------------------------------------------------------
step7_backup_object_storage() {
  info "Step 7: Backing up Quay Object Storage (NooBaa)..."

  export AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_ID=$(oc get secret -l app=noobaa \
    -n "$SOURCE_NS" \
    -o jsonpath='{.items[0].data.AWS_ACCESS_KEY_ID}' | base64 -d)

  export AWS_SECRET_ACCESS_KEY
  AWS_SECRET_ACCESS_KEY=$(oc get secret -l app=noobaa \
    -n "$SOURCE_NS" \
    -o jsonpath='{.items[0].data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

  local s3_endpoint bucket_name
  s3_endpoint=$(oc get route s3 \
    -n "$STORAGE_NS" \
    -o jsonpath='{.spec.host}')
  bucket_name=$(oc get cm -l app=noobaa \
    -n "$SOURCE_NS" \
    -o jsonpath='{.items[0].data.BUCKET_NAME}')

  echo "  S3 Endpoint : $s3_endpoint"
  echo "  Bucket Name : $bucket_name"

  mkdir -p "${BACKUP_DIR}/blobs"
  aws s3 sync \
    --no-verify-ssl \
    --endpoint "https://${s3_endpoint}" \
    "s3://${bucket_name}" \
    "${BACKUP_DIR}/blobs"

  local file_count
  file_count=$(find "${BACKUP_DIR}/blobs" -type f | wc -l)
  success "Object storage blobs saved → ${BACKUP_DIR}/blobs/ ($file_count files)"
}

# ---------------------------------------------------------------------------
# STEP 8 — Scale DOWN Quay
# Phase 1: disable HPA
# Phase 2: set replicas to 0
# ---------------------------------------------------------------------------
step8_scale_down_quay() {
  info "Step 8: Scaling down Quay deployment..."

  # Phase 1: disable HPA
  oc patch quayregistry "$QUAY_CR_NAME" -n "$SOURCE_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false}
    ]}
  }'
  sleep 10

  # Phase 2: zero out quay/clair/mirror
  oc patch quayregistry "$QUAY_CR_NAME" -n "$SOURCE_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":false},
      {"kind":"quay",  "managed":true,"overrides":{"replicas":0}},
      {"kind":"clair", "managed":true,"overrides":{"replicas":0}},
      {"kind":"mirror","managed":true,"overrides":{"replicas":0}}
    ]}
  }'

  info "Waiting for pods to terminate..."
  oc wait pod -l app=quay   -n "$SOURCE_NS" --for=delete --timeout=300s 2>/dev/null || true
  oc wait pod -l app=clair  -n "$SOURCE_NS" --for=delete --timeout=300s 2>/dev/null || true
  oc wait pod -l app=mirror -n "$SOURCE_NS" --for=delete --timeout=300s 2>/dev/null || true

  info "Remaining pods (should be postgres, redis, operator only):"
  oc get pods -n "$SOURCE_NS"
  success "Quay deployment scaled to 0"
}

# ---------------------------------------------------------------------------
# STEP 9 — Scale Quay back UP
# ---------------------------------------------------------------------------
step9_scale_up_quay() {
  info "Step 9: Scaling Quay back up..."

  # Phase 1: re-enable HPA
  oc patch quayregistry "$QUAY_CR_NAME" -n "$SOURCE_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"horizontalpodautoscaler","managed":true}
    ]}
  }'
  sleep 10

  # Phase 2: restore managed components
  oc patch quayregistry "$QUAY_CR_NAME" -n "$SOURCE_NS" --type=merge -p '{
    "spec":{"components":[
      {"kind":"quay",  "managed":true},
      {"kind":"clair", "managed":true},
      {"kind":"mirror","managed":true}
    ]}
  }'

  info "Waiting for Quay to become Available..."
  oc wait quayregistry "$QUAY_CR_NAME" \
    --for=condition=Available=true \
    -n "$SOURCE_NS" \
    --timeout=600s || warn "Quay taking longer than expected — check pods manually"
  success "Quay deployment scaled back up"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  info "============================================================"
  info " RH Quay Operator — Backup v2.0.0"
  info " Source NS : $SOURCE_NS"
  info " Quay CR   : $QUAY_CR_NAME"
  info " Output Dir: $BACKUP_DIR"
  info "============================================================"

  check_prereqs
  mkdir -p "$BACKUP_DIR"

  step1_verify_health
  step2_backup_quay_cr
  step3_backup_managed_secrets
  step4_backup_config_bundle
  step5_get_db_name
  step6_backup_postgres        # runs BEFORE scale-down
  step7_backup_object_storage  # runs BEFORE scale-down
  step8_scale_down_quay        # scale down AFTER all data captured
  step9_scale_up_quay

  info "============================================================"
  success "BACKUP COMPLETE"
  info "  Artifacts in: $BACKUP_DIR"
  ls -lh "$BACKUP_DIR"
  info "============================================================"
}

main "$@"
