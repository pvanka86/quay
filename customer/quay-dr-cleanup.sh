#!/usr/bin/env bash
# =============================================================================
# quay-dr-cleanup.sh
# Safely cleans the quay-dr namespace after a failed Kasten restore.
# Safe to run multiple times — all steps are idempotent.
#
# Usage:
#   ./quay-dr-cleanup.sh                      # DR=quay-dr, source=quay
#   ./quay-dr-cleanup.sh quay-dr2             # custom DR namespace
#   ./quay-dr-cleanup.sh quay-dr quay-prod    # custom DR + source namespace
#
# What is PRESERVED (never touched):
#   - quay-operator deployment and its pod
#   - quay-operator ClusterServiceVersion (CSV)
#   - Original OperatorGroup for the DR namespace (quay-dr-*)
#   - quay-s3-backup-credentials secret
#   - System secrets (dockercfg, default-token, pipeline, builder, deployer)
#   - System ConfigMaps (kube-root-ca, openshift-service-ca, ca-bundles)
#
# What is CLEANED (operand state only):
#   1.  Cancel any running Kasten RestoreAction
#   2.  Delete QuayRegistry CR + pre-scale to 0
#   3.  Wait for operator-managed pods to terminate
#   4.  Force-delete any remaining non-operator pods
#   5.  Delete stale OLM objects restored by Kasten (NOT the operator CSV)
#   6.  Delete Quay-owned secrets (not s3 credentials, not system secrets)
#   7.  Delete Quay-owned ConfigMaps
#   8.  Delete ObjectBucketClaim (strips finalizer first)
#   9.  Delete cluster-scoped ObjectBucket from source ns (unblocks NooBaa)
#   10. Delete kanister-job pods
#   11. Print final namespace state
# =============================================================================
set -o pipefail

DR_NAMESPACE="${1:-quay-dr}"
SOURCE_NAMESPACE="${2:-quay}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo ""; echo -e "${GREEN}========== $* ==========${NC}"; }

section "Quay DR Cleanup — namespace: ${DR_NAMESPACE}"
info "Starting cleanup at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
info "Source namespace  : ${SOURCE_NAMESPACE}"
info "Operator and quay-s3-backup-credentials will be preserved"

if ! oc get namespace "${DR_NAMESPACE}" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace '${DR_NAMESPACE}' not found"
  exit 1
fi

# =============================================================================
# STEP 1 — Cancel any running Kasten RestoreAction
# =============================================================================
section "STEP 1: Cancel running RestoreActions"

for ra in $(kubectl get restoreactions -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  STATE=$(kubectl get restoreaction "${ra}" -n "${DR_NAMESPACE}" \
    -o jsonpath='{.status.state}' 2>/dev/null)
  info "Deleting RestoreAction ${ra} (state: ${STATE:-unknown})..."
  kubectl delete restoreaction "${ra}" -n "${DR_NAMESPACE}" \
    --timeout=30s 2>/dev/null \
    && info "  Deleted" || warn "  Could not delete (may be gone)"
done

for ra in $(kubectl get restoreactions -n kasten-io \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  TARGET=$(kubectl get restoreaction "${ra}" -n kasten-io \
    -o jsonpath='{.spec.targetNamespace}' 2>/dev/null)
  STATE=$(kubectl get restoreaction "${ra}" -n kasten-io \
    -o jsonpath='{.status.state}' 2>/dev/null)
  if [[ "${TARGET}" == "${DR_NAMESPACE}" && \
        ("${STATE}" == "Running" || -z "${STATE}") ]]; then
    info "Deleting kasten-io RestoreAction ${ra}..."
    kubectl delete restoreaction "${ra}" -n kasten-io \
      --timeout=30s 2>/dev/null \
      && info "  Deleted" || warn "  Could not delete"
  fi
done

# =============================================================================
# STEP 2 — Delete QuayRegistry CR
# Pre-scales to 0, then deletes. Strips finalizers if stuck.
# The quay-operator deployment is NOT touched.
# =============================================================================
section "STEP 2: Delete QuayRegistry CR (operator preserved)"

CR_NAME=$(oc get quayregistry -n "${DR_NAMESPACE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "${CR_NAME}" ]]; then
  info "No QuayRegistry CR found — skipping"
else
  info "Pre-scaling to 0 before CR delete..."
  oc patch quayregistry "${CR_NAME}" -n "${DR_NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"components":[{"kind":"horizontalpodautoscaler","managed":false},{"kind":"quay","managed":true,"overrides":{"replicas":0}},{"kind":"clair","managed":true,"overrides":{"replicas":0}},{"kind":"mirror","managed":true,"overrides":{"replicas":0}}]}}' \
    2>/dev/null || true
  oc delete hpa --all -n "${DR_NAMESPACE}" 2>/dev/null || true
  sleep 5

  info "Deleting QuayRegistry CR '${CR_NAME}'..."
  oc delete quayregistry "${CR_NAME}" -n "${DR_NAMESPACE}" \
    --timeout=60s 2>/dev/null \
    && info "  Deleted" \
    || warn "  Timed out — stripping finalizers..."

  if oc get quayregistry "${CR_NAME}" -n "${DR_NAMESPACE}" &>/dev/null; then
    oc patch quayregistry "${CR_NAME}" -n "${DR_NAMESPACE}" \
      --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    oc delete quayregistry "${CR_NAME}" -n "${DR_NAMESPACE}" \
      --force --grace-period=0 2>/dev/null || true
    info "  Force-deleted"
  fi
fi

# =============================================================================
# STEP 3 — Wait for operator-managed pods to terminate
# =============================================================================
section "STEP 3: Wait for operator-managed pods to terminate"

for label in "app=quay" "app=clair" "app=mirror" \
             "quay-component=postgres" "quay-component=redis" \
             "quay-component=clair-postgres"; do
  COUNT=$(oc get pods -l "${label}" -n "${DR_NAMESPACE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${COUNT}" -gt 0 ]]; then
    info "Waiting up to 120s for ${label} pods (${COUNT})..."
    oc wait pod -l "${label}" -n "${DR_NAMESPACE}" \
      --for=delete --timeout=120s 2>/dev/null \
      && info "  Terminated" \
      || warn "  Timed out — will force-delete in STEP 4"
  else
    info "No ${label} pods — skipping"
  fi
done

# =============================================================================
# STEP 4 — Force-delete remaining non-operator pods
# =============================================================================
section "STEP 4: Force-delete remaining non-operator pods"

REMAINING=$(oc get pods -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "quay-operator\|kanister-job" \
  | awk '{print $1}')

if [[ -z "${REMAINING}" ]]; then
  info "No remaining pods to force-delete"
else
  for pod in ${REMAINING}; do
    PHASE=$(oc get pod "${pod}" -n "${DR_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    info "Force-deleting pod ${pod} (${PHASE:-unknown})..."
    oc delete pod "${pod}" -n "${DR_NAMESPACE}" \
      --force --grace-period=0 2>/dev/null \
      && info "  Deleted" || warn "  Could not delete"
  done
fi

# =============================================================================
# STEP 5 — Delete stale OLM objects
# Preserves the quay-operator CSV and original OperatorGroup (quay-dr-*)
# =============================================================================
section "STEP 5: Delete stale OLM objects (preserving operator CSV)"

# OperatorGroups — keep quay-dr-* (the native DR namespace one)
for og in $(oc get operatorgroup -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | grep -v "^quay-dr-" | awk '{print $1}'); do
  info "Deleting stale OperatorGroup: ${og}"
  oc delete operatorgroup "${og}" -n "${DR_NAMESPACE}" \
    2>/dev/null && info "  Deleted" || warn "  Could not delete"
done

# CSVs — delete only non-quay-operator ones (restored from source backup)
for csv in $(oc get csv -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | grep -v "^quay-operator\." | awk '{print $1}'); do
  info "Deleting stale CSV: ${csv}"
  oc delete csv "${csv}" -n "${DR_NAMESPACE}" \
    2>/dev/null && info "  Deleted" || warn "  Could not delete"
done
KEPT=$(oc get csv -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep "^quay-operator\." | awk '{print $1}')
[[ -n "${KEPT}" ]] && info "Preserved operator CSV: ${KEPT}"

# InstallPlans
for ip in $(oc get installplan -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  info "Deleting InstallPlan: ${ip}"
  oc delete installplan "${ip}" -n "${DR_NAMESPACE}" \
    2>/dev/null && info "  Deleted" || warn "  Could not delete"
done

# Subscriptions
for sub in $(oc get subscription -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  info "Deleting Subscription: ${sub}"
  oc delete subscription "${sub}" -n "${DR_NAMESPACE}" \
    2>/dev/null && info "  Deleted" || warn "  Could not delete"
done

# OperatorConditions
for oc_res in $(oc get operatorcondition -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  info "Deleting OperatorCondition: ${oc_res}"
  oc delete operatorcondition "${oc_res}" -n "${DR_NAMESPACE}" \
    2>/dev/null && info "  Deleted" || warn "  Could not delete"
done

# =============================================================================
# STEP 6 — Delete Quay-owned secrets
# Preserves: dockercfg, default-token, pipeline, builder, deployer,
#            kanister, quay-s3-backup-credentials
# =============================================================================
section "STEP 6: Delete Quay-owned secrets (preserving credentials)"

QUAY_SECRETS=$(oc get secrets -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "dockercfg\|default-token\|pipeline\|builder\|deployer\|kanister\|s3-backup-credentials" \
  | awk '{print $1}')

if [[ -z "${QUAY_SECRETS}" ]]; then
  info "No Quay-owned secrets to delete"
else
  for secret in ${QUAY_SECRETS}; do
    oc delete secret "${secret}" -n "${DR_NAMESPACE}" 2>/dev/null \
      && info "Deleted: ${secret}" \
      || warn "Could not delete: ${secret}"
  done
fi

if oc get secret quay-s3-backup-credentials \
  -n "${DR_NAMESPACE}" &>/dev/null; then
  info "Preserved: quay-s3-backup-credentials ✓"
else
  warn "quay-s3-backup-credentials NOT found in ${DR_NAMESPACE}"
  warn "Create it before running restore — restore will fail without it"
fi

# =============================================================================
# STEP 7 — Delete Quay-owned ConfigMaps
# =============================================================================
section "STEP 7: Delete Quay-owned ConfigMaps"

QUAY_CMS=$(oc get configmaps -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "kube-root-ca\|openshift-service-ca\|custom-ca-bundle\|config-service-ca\|config-trusted-ca" \
  | awk '{print $1}')

if [[ -z "${QUAY_CMS}" ]]; then
  info "No Quay-owned ConfigMaps to delete"
else
  for cm in ${QUAY_CMS}; do
    oc delete configmap "${cm}" -n "${DR_NAMESPACE}" 2>/dev/null \
      && info "Deleted: ${cm}" \
      || warn "Could not delete: ${cm}"
  done
fi

# =============================================================================
# STEP 8 — Delete ObjectBucketClaim
# Strips the objectbucket.io/finalizer first. Without this the OBC stays
# in Terminating indefinitely — NooBaa holds the finalizer until it cleans
# up the backing bucket, which can take minutes or permanently block.
# =============================================================================
section "STEP 8: Delete ObjectBucketClaim (stripping finalizer first)"

for obc in $(oc get objectbucketclaim -n "${DR_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '{print $1}'); do
  info "Stripping finalizer from OBC: ${obc}..."
  oc patch objectbucketclaim "${obc}" -n "${DR_NAMESPACE}" \
    --type=merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true

  info "Deleting OBC: ${obc}..."
  oc delete objectbucketclaim "${obc}" -n "${DR_NAMESPACE}" \
    --timeout=15s 2>/dev/null \
    && info "  Deleted" \
    || {
      warn "  Timed out — force-deleting..."
      oc delete objectbucketclaim "${obc}" -n "${DR_NAMESPACE}" \
        --force --grace-period=0 2>/dev/null || true
      info "  Force-deleted"
    }
done

# =============================================================================
# STEP 9 — Delete cluster-scoped ObjectBucket from source namespace
# The source quay namespace has a Bound ObjectBucket at cluster scope.
# NooBaa won't provision a new bucket for quay-dr while it exists with
# a matching name. Strips finalizer before deleting.
# The source OBC is unaffected — the operator recreates its ObjectBucket
# on the next reconcile cycle.
# =============================================================================
section "STEP 9: Delete source ObjectBucket (unblocks NooBaa for DR)"

SOURCE_CR=$(oc get quayregistry -n "${SOURCE_NAMESPACE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "quay-registry")
SOURCE_OB="obc-${SOURCE_NAMESPACE}-${SOURCE_CR}-quay-datastore"

if oc get objectbucket "${SOURCE_OB}" &>/dev/null; then
  info "Stripping finalizer from ${SOURCE_OB}..."
  oc patch objectbucket "${SOURCE_OB}" \
    --type=merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true

  info "Deleting source ObjectBucket: ${SOURCE_OB}..."
  oc delete objectbucket "${SOURCE_OB}" --timeout=15s 2>/dev/null \
    && info "  Deleted" \
    || {
      warn "  Timed out — force-deleting..."
      oc delete objectbucket "${SOURCE_OB}" \
        --force --grace-period=0 2>/dev/null || true
    }
else
  info "Source ObjectBucket '${SOURCE_OB}' not found"
  # Show related buckets for reference
  RELATED=$(oc get objectbucket --no-headers 2>/dev/null \
    | grep -i "${SOURCE_NAMESPACE}\|quay-datastore" | awk '{print $1}')
  if [[ -n "${RELATED}" ]]; then
    warn "Related ObjectBuckets found (may need manual review):"
    for ob in ${RELATED}; do warn "  ${ob}"; done
  fi
fi

# =============================================================================
# STEP 10 — Clean up kanister-job pods
# =============================================================================
section "STEP 10: Clean up kanister-job pods"

for pod in $(oc get pods -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep "kanister-job" | awk '{print $1}'); do
  info "Deleting kanister-job pod: ${pod}"
  oc delete pod "${pod}" -n "${DR_NAMESPACE}" \
    --force --grace-period=0 2>/dev/null \
    && info "  Deleted" || warn "  Could not delete"
done

# =============================================================================
# STEP 11 — Final namespace state
# =============================================================================
section "STEP 11: Final namespace state"

echo ""
info "Pods:"
oc get pods -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  || echo "  (none)"

echo ""
info "QuayRegistry CRs:"
oc get quayregistry -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  || echo "  (none — expected)"

echo ""
info "OperatorGroups:"
oc get operatorgroup -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  || echo "  (none)"

echo ""
info "Secrets (non-system):"
oc get secrets -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "dockercfg\|default-token\|pipeline\|builder\|deployer" \
  || echo "  (none)"

echo ""
info "ObjectBucketClaims:"
oc get objectbucketclaim -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  || echo "  (none — expected)"

echo ""
info "ConfigMaps (non-system):"
oc get configmaps -n "${DR_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "kube-root-ca\|openshift-service-ca\|custom-ca-bundle\|config-service-ca\|config-trusted-ca" \
  || echo "  (none)"

echo ""
echo -e "${GREEN}======================================================"
echo "[DONE] Cleanup complete — ${DR_NAMESPACE} is ready for restore"
echo "[DONE] Operator preserved — no reinstall needed"
echo "[DONE] quay-s3-backup-credentials preserved"
echo -e "======================================================${NC}"
echo ""
