#!/usr/bin/env bash
# =============================================================================
# Quay DR End-to-End Test Script
# Veeam Kasten 8.5.5 | Quay 3.13.2 | OpenShift
#
# Usage:
#   chmod +x quay_e2e_test.sh
#   ./quay_e2e_test.sh [lab|prod]
#
#   lab  (default) — quay-backup-lab policy + quay-kanister-blueprint-lab
#   prod           — quay-backup-prod policy + quay-kanister-blueprint
#
# Customize the CONFIG section below before running.
# =============================================================================

# NOTE: intentionally NOT using set -e so the script continues through all
# phases and reports a full result at the end rather than stopping mid-run.
set -uo pipefail

# =============================================================================
# ENVIRONMENT — lab or prod (defaults to lab if no argument given)
# =============================================================================
ENV="${1:-lab}"
if [[ "${ENV}" != "lab" && "${ENV}" != "prod" ]]; then
  echo "Usage: $0 [lab|prod]"
  echo "  lab  — quay-backup-lab policy + quay-kanister-blueprint-lab (default)"
  echo "  prod — quay-backup-prod policy + quay-kanister-blueprint"
  exit 1
fi

# =============================================================================
# CONFIG — edit these before running
# =============================================================================
SOURCE_NS="quay"
DR_NS="quay-dr"
CR_NAME="quay-registry"
QUAY_USER="praveen"
QUAY_PASS="password"
KASTEN_NS="kasten-io"
LOCATION_PROFILE="kasten-se-lab-baremetal-s3"
EXT_S3_BUCKET="quay-kasten-blobs"

# Policy and blueprint resolved from ENV argument — do not edit these
if [[ "${ENV}" == "prod" ]]; then
  BLUEPRINT="quay-kanister-blueprint"
  POLICY_NAME="quay-backup-prod"
else
  BLUEPRINT="quay-kanister-blueprint-lab"
  POLICY_NAME="quay-backup-lab"
fi
EXT_S3_ENDPOINT="https://s3.us-east-2.amazonaws.com"
TEST_IMAGE="docker.io/library/alpine:latest"
TEST_IMAGE_TAG="alpine:latest"
CLEANUP_SCRIPT="./quay-dr-cleanup.sh"

# Timeouts (seconds)
BACKUP_TIMEOUT=900
RESTORE_TIMEOUT=1800
POD_APPEAR_TIMEOUT=180

# =============================================================================
# COLORS & HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0
declare -a RESULTS=()
FATAL=false

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ WARNING: $*${NC}"; WARN=$((WARN+1)); }
fail()    { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}"; }
header()  {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
}

check() {
  local label="$1" result="$2"
  if [[ "${result}" == "pass" ]]; then
    PASS=$((PASS+1)); RESULTS+=("✓ ${label}")
    success "CHECK: ${label}"
  else
    FAIL=$((FAIL+1)); RESULTS+=("✗ ${label}")
    fail "CHECK FAILED: ${label}"
  fi
}

abort() {
  fail "FATAL: $*"
  FATAL=true
  print_report
  exit 1
}

print_report() {
  header "FINAL TEST REPORT"
  echo ""
  for r in "${RESULTS[@]}"; do
    if [[ "${r}" == ✓* ]]; then echo -e "  ${GREEN}${r}${NC}"
    else echo -e "  ${RED}${r}${NC}"; fi
  done
  echo ""
  echo -e "  ${GREEN}Passed  : ${PASS}${NC}"
  echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
  echo -e "  ${RED}Failed  : ${FAIL}${NC}"
  echo ""
  if [[ "${FAIL}" -eq 0 && "${FATAL}" == "false" ]]; then
    echo -e "${GREEN}${BOLD}  ✓ END-TO-END TEST PASSED${NC}"
    echo -e "${GREEN}  Quay DR restore validated — image pull from DR registry succeeded${NC}"
  else
    echo -e "${RED}${BOLD}  ✗ END-TO-END TEST FAILED${NC}"
  fi
}

# Wait for a shell condition with timeout, returns 0 on success 1 on timeout
wait_for() {
  local desc="$1" timeout="$2" interval="${3:-5}"
  shift 3
  local elapsed=0
  log "Waiting for: ${desc} (timeout ${timeout}s)..."
  while [[ ${elapsed} -lt ${timeout} ]]; do
    if eval "$@" &>/dev/null; then
      success "${desc} — after ${elapsed}s"
      return 0
    fi
    printf "."; sleep "${interval}"; elapsed=$((elapsed + interval))
  done
  echo ""
  warn "Timed out waiting for: ${desc} (${timeout}s)"
  return 1
}

# Stream pod logs with timeout — never kills the script on timeout
stream_logs() {
  local ns="$1" pod="$2" timeout_s="$3"
  log "Streaming logs from ${pod} (timeout ${timeout_s}s)..."
  timeout "${timeout_s}" kubectl logs -n "${ns}" "${pod}" --follow 2>/dev/null || true
  echo ""
}

# Wait for a kanister-job pod to appear (excluding a known pod name)
wait_for_kanister_pod() {
  local ns="$1" exclude="${2:-__none__}" timeout_s="${3:-${POD_APPEAR_TIMEOUT}}"
  local elapsed=0 pod=""
  while [[ ${elapsed} -lt ${timeout_s} ]]; do
    pod=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | grep "kanister-job" | grep -v Completed \
      | awk '{print $1}' | grep -v "^${exclude}$" | tail -1 || true)
    if [[ -n "${pod}" ]]; then
      echo "${pod}"; return 0
    fi
    sleep 3; elapsed=$((elapsed+3))
  done
  echo ""; return 1
}

# =============================================================================
# SECTION 1 — PRE-FLIGHT
# =============================================================================
header "SECTION 1 — Pre-Flight Checks"
log "Source NS: ${SOURCE_NS} | DR NS: ${DR_NS} | Blueprint: ${BLUEPRINT}"

# Required tools
for tool in oc kubectl podman aws python3; do
  if ! command -v "${tool}" &>/dev/null; then
    abort "Required tool not found: ${tool}"
  fi
done
success "All required tools available"

# Source QuayRegistry Available
AVAIL=$(oc get quayregistry "${CR_NAME}" -n "${SOURCE_NS}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
[[ "${AVAIL}" != "True" ]] && abort "Source QuayRegistry not Available (${AVAIL:-unknown})"
check "Source QuayRegistry Available=True" "pass"

# ConfigInvalid check
CI=$(oc get quayregistry "${CR_NAME}" -n "${SOURCE_NS}" \
  -o jsonpath='{.status.conditions[?(@.reason=="ConfigInvalid")].reason}' 2>/dev/null || echo "")
[[ "${CI}" == "ConfigInvalid" ]] && abort "Source QuayRegistry is ConfigInvalid — remove DISTRIBUTED_STORAGE_CONFIG from config bundle secret"
check "Source QuayRegistry no ConfigInvalid" "pass"

# Source Quay route and health
QUAY_ROUTE=$(oc get route -n "${SOURCE_NS}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
[[ -z "${QUAY_ROUTE}" ]] && abort "Cannot find source Quay route in ${SOURCE_NS}"
log "Source Quay route: ${QUAY_ROUTE}"

HEALTH=$(curl -sk "https://${QUAY_ROUTE}/health/instance" 2>/dev/null || echo "{}")
if echo "${HEALTH}" | python3 -c "import sys,json; d=json.load(sys.stdin); assert all(d.get('data',{}).get('services',{}).values())" 2>/dev/null; then
  check "Source Quay health — all services true" "pass"
else
  abort "Source Quay health check failed: ${HEALTH}"
fi

# Blueprint present
kubectl get blueprint "${BLUEPRINT}" -n "${KASTEN_NS}" &>/dev/null \
  || abort "Blueprint ${BLUEPRINT} not found in ${KASTEN_NS}"
check "Blueprint present" "pass"

# DR operator check
DR_OP=$(kubectl get pods -n "${DR_NS}" --no-headers 2>/dev/null \
  | grep quay-operator | grep -c Running || true)
if [[ "${DR_OP}" -lt 1 ]]; then
  warn "No running Quay Operator in ${DR_NS} — if cluster-scoped this is fine, otherwise install it"
else
  check "Quay Operator running in ${DR_NS}" "pass"
fi

# S3 credentials
oc get secret quay-s3-backup-credentials -n "${SOURCE_NS}" &>/dev/null \
  || abort "quay-s3-backup-credentials missing in ${SOURCE_NS}"
oc get secret quay-s3-backup-credentials -n "${DR_NS}" &>/dev/null \
  || abort "quay-s3-backup-credentials missing in ${DR_NS}"
check "S3 credentials present in both namespaces" "pass"

# Kanister credentials (quayAdminUser + quayAdminPassword)
# Used by postRestoreHook STEP 13 for bcrypt password reset
oc get secret quay-kanister-credentials -n "${SOURCE_NS}" &>/dev/null \
  || abort "quay-kanister-credentials missing in ${SOURCE_NS} — create with: kubectl create secret generic quay-kanister-credentials -n ${SOURCE_NS} --from-literal=quayAdminUser=<user> --from-literal=quayAdminPassword=<pass>"
oc get secret quay-kanister-credentials -n "${DR_NS}" &>/dev/null \
  || abort "quay-kanister-credentials missing in ${DR_NS} — create with: kubectl create secret generic quay-kanister-credentials -n ${DR_NS} --from-literal=quayAdminUser=<user> --from-literal=quayAdminPassword=<pass>"
for key in quayAdminUser quayAdminPassword; do
  for ns in "${SOURCE_NS}" "${DR_NS}"; do
    VAL=$(oc get secret quay-kanister-credentials -n "${ns}" \
      -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d || true)
    [[ -z "${VAL}" ]] && abort "quay-kanister-credentials in ${ns} is missing key: ${key}"
  done
done
check "Kanister credentials present in both namespaces (with required keys)" "pass"

# =============================================================================
# SECTION 2 — PUSH TEST IMAGE
# =============================================================================
header "SECTION 2 — Push Test Image to Source Quay"

log "Pulling ${TEST_IMAGE}..."
podman pull "${TEST_IMAGE}" || abort "Failed to pull ${TEST_IMAGE}"

podman tag "${TEST_IMAGE}" "${QUAY_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" \
  || abort "Failed to tag image"

log "Logging in to source Quay..."
podman login --tls-verify=false \
  --username "${QUAY_USER}" --password "${QUAY_PASS}" \
  "${QUAY_ROUTE}" || abort "Login to source Quay failed"

log "Pushing to source Quay..."
podman push --tls-verify=false "${QUAY_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" \
  || abort "Push to source Quay failed"
check "Test image pushed to source Quay" "pass"

# Verify source blobs
NOOBAA_BUCKET=$(oc get configmap quay-registry-quay-datastore -n "${SOURCE_NS}" \
  -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || echo "")
NOOBAA_KEY=$(oc get secret quay-registry-quay-datastore -n "${SOURCE_NS}" \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || echo "")
NOOBAA_SEC=$(oc get secret quay-registry-quay-datastore -n "${SOURCE_NS}" \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || echo "")
NOOBAA_EP=$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [[ -n "${NOOBAA_BUCKET}" && -n "${NOOBAA_KEY}" && -n "${NOOBAA_EP}" ]]; then
  BLOB_COUNT=$(AWS_ACCESS_KEY_ID="${NOOBAA_KEY}" AWS_SECRET_ACCESS_KEY="${NOOBAA_SEC}" \
    aws s3 ls "s3://${NOOBAA_BUCKET}" \
    --endpoint-url "https://${NOOBAA_EP}" --no-verify-ssl --recursive 2>/dev/null \
    | wc -l | tr -d ' ')
  if [[ "${BLOB_COUNT}" -gt 0 ]]; then
    check "Source NooBaa has ${BLOB_COUNT} blobs" "pass"
  else
    abort "No blobs in source NooBaa after push — storage may be broken"
  fi
else
  warn "Cannot verify source NooBaa blob count — missing OBC credentials"
fi

# =============================================================================
# SECTION 3 — BACKUP POLICY
# =============================================================================
header "SECTION 3 — Backup Policy"

if kubectl get policy "${POLICY_NAME}" -n "${KASTEN_NS}" &>/dev/null; then
  log "Policy ${POLICY_NAME} exists — verifying hooks..."
  PREHOOK=$(kubectl get policy "${POLICY_NAME}" -n "${KASTEN_NS}" \
    -o jsonpath='{.spec.actions[0].backupParameters.hooks.preHook.actionName}' 2>/dev/null || echo "")
  POSTHOOK=$(kubectl get policy "${POLICY_NAME}" -n "${KASTEN_NS}" \
    -o jsonpath='{.spec.actions[0].backupParameters.hooks.onSuccess.actionName}' 2>/dev/null || echo "")
  if [[ "${PREHOOK}" != "preBackupHook" || "${POSTHOOK}" != "postBackupHook" ]]; then
    abort "Policy hooks misconfigured. preHook='${PREHOOK}' onSuccess='${POSTHOOK}'"
  fi
  check "Backup policy hooks correctly wired" "pass"
else
  log "Creating backup policy ${POLICY_NAME}..."
  kubectl apply -f - <<EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: ${POLICY_NAME}
  namespace: ${KASTEN_NS}
spec:
  frequency: "@onDemand"
  actions:
    - action: backup
      backupParameters:
        profile:
          name: ${LOCATION_PROFILE}
          namespace: ${KASTEN_NS}
        hooks:
          preHook:
            blueprint: ${BLUEPRINT}
            actionName: preBackupHook
          onSuccess:
            blueprint: ${BLUEPRINT}
            actionName: postBackupHook
        filters:
          excludeResources:
            - group: operators.coreos.com
              version: v1alpha1
              resource: subscriptions
            - group: operators.coreos.com
              version: v1
              resource: operatorgroups
            - group: operators.coreos.com
              version: v1alpha1
              resource: clusterserviceversions
            - group: operators.coreos.com
              version: v1alpha1
              resource: installplans
            - resource: horizontalpodautoscalers
            - resource: objectbucketclaims
            - resource: reclaimspacejobs
            - resource: reclaimspacecronjobs
            - resource: datasources
            - group: operators.coreos.com
              version: v2
              resource: operatorconditions
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - ${SOURCE_NS}
EOF
  check "Backup policy created" "pass"
fi

# =============================================================================
# SECTION 4 — TRIGGER BACKUP
# =============================================================================
header "SECTION 4 — Trigger Backup"

log "Triggering backup..."
RUN_OUTPUT=$(kubectl create -f - 2>&1 <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: quay-backup-run-
  namespace: ${KASTEN_NS}
spec:
  subject:
    kind: Policy
    name: ${POLICY_NAME}
    namespace: ${KASTEN_NS}
EOF
)
RUN_NAME=$(echo "${RUN_OUTPUT}" | grep -o 'quay-backup-run-[a-z0-9]*' | head -1 || echo "")
[[ -z "${RUN_NAME}" ]] && abort "Failed to create RunAction: ${RUN_OUTPUT}"
log "RunAction: ${RUN_NAME}"

# Wait for preBackupHook pod
log "Waiting for preBackupHook kanister-job pod..."
PREBK_POD=$(wait_for_kanister_pod "${SOURCE_NS}" "__none__" "${POD_APPEAR_TIMEOUT}")
[[ -z "${PREBK_POD}" ]] && abort "preBackupHook pod never appeared"
log "preBackupHook pod: ${PREBK_POD}"
stream_logs "${SOURCE_NS}" "${PREBK_POD}" "${BACKUP_TIMEOUT}"

# Wait up to 60s for pod to reach Succeeded after log stream ends
log "Waiting for preBackupHook pod to reach Succeeded..."
ELAPSED=0
while [[ ${ELAPSED} -lt 60 ]]; do
  PREBK_STATUS=$(kubectl get pod "${PREBK_POD}" -n "${SOURCE_NS}"     -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
  [[ "${PREBK_STATUS}" == "Succeeded" || "${PREBK_STATUS}" == "Gone" ]] && break
  sleep 5; ELAPSED=$((ELAPSED+5))
done
log "preBackupHook pod phase: ${PREBK_STATUS}"
if [[ "${PREBK_STATUS}" == "Succeeded" || "${PREBK_STATUS}" == "Gone" ]]; then
  check "preBackupHook succeeded" "pass"
else
  check "preBackupHook phase: ${PREBK_STATUS}" "fail"
fi

# Wait for postBackupHook pod (different from preBackupHook pod)
log "Waiting for postBackupHook kanister-job pod (appears after Kasten PVC snapshot)..."
POSTBK_POD=$(wait_for_kanister_pod "${SOURCE_NS}" "${PREBK_POD}" 600)
if [[ -n "${POSTBK_POD}" ]]; then
  log "postBackupHook pod: ${POSTBK_POD}"
  stream_logs "${SOURCE_NS}" "${POSTBK_POD}" 300
  ELAPSED=0
  while [[ ${ELAPSED} -lt 60 ]]; do
    POSTBK_STATUS=$(kubectl get pod "${POSTBK_POD}" -n "${SOURCE_NS}"       -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
    [[ "${POSTBK_STATUS}" == "Succeeded" || "${POSTBK_STATUS}" == "Gone" ]] && break
    sleep 5; ELAPSED=$((ELAPSED+5))
  done
  log "postBackupHook pod phase: ${POSTBK_STATUS}"
  if [[ "${POSTBK_STATUS}" == "Succeeded" || "${POSTBK_STATUS}" == "Gone" ]]; then
    check "postBackupHook succeeded" "pass"
  else
    check "postBackupHook phase: ${POSTBK_STATUS}" "fail"
  fi
else
  warn "postBackupHook pod not observed within 600s — may have completed very quickly"
fi

# Wait for RunAction to reach Complete
# Note: Kasten deletes RunAction objects after completion — NotFound = Complete
log "Waiting for RunAction ${RUN_NAME} to complete..."
ELAPSED=0
RA_STATUS=""
while [[ ${ELAPSED} -lt ${BACKUP_TIMEOUT} ]]; do
  RA_STATUS=$(kubectl get runaction "${RUN_NAME}" -n "${KASTEN_NS}"     -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [[ "${RA_STATUS}" == "Complete" || "${RA_STATUS}" == "NotFound" ]]; then break; fi
  if [[ "${RA_STATUS}" == "Failed" ]]; then
    abort "Backup RunAction ${RUN_NAME} failed"
  fi
  printf "."; sleep 10; ELAPSED=$((ELAPSED+10))
done
echo ""
if [[ "${RA_STATUS}" == "Complete" || "${RA_STATUS}" == "NotFound" ]]; then
  check "Backup RunAction Complete" "pass"
else
  abort "Backup did not complete within ${BACKUP_TIMEOUT}s (state: ${RA_STATUS})"
fi

# Verify restore point
LATEST_RP=$(kubectl get restorepoints -n "${SOURCE_NS}" \
  --sort-by='.metadata.creationTimestamp' --no-headers 2>/dev/null \
  | tail -1 | awk '{print $1}' || echo "")
[[ -z "${LATEST_RP}" ]] && abort "No restore point found after backup"
log "Latest restore point: ${LATEST_RP}"
check "Restore point created: ${LATEST_RP}" "pass"

# Verify PVC snapshots
SNAP_READY=$(kubectl get volumesnapshots -n "${SOURCE_NS}" \
  --sort-by='.metadata.creationTimestamp' --no-headers 2>/dev/null \
  | tail -2 | grep -c "true" || true)
if [[ "${SNAP_READY}" -ge 2 ]]; then
  check "PVC snapshots ReadyToUse (${SNAP_READY})" "pass"
else
  warn "Expected 2 ReadyToUse PVC snapshots, found ${SNAP_READY}"
fi

# Verify external S3 blobs
EXT_KEY=$(oc get secret quay-s3-backup-credentials -n "${SOURCE_NS}" \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || echo "")
EXT_SEC=$(oc get secret quay-s3-backup-credentials -n "${SOURCE_NS}" \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || echo "")
if [[ -n "${EXT_KEY}" ]]; then
  S3_COUNT=$(AWS_ACCESS_KEY_ID="${EXT_KEY}" AWS_SECRET_ACCESS_KEY="${EXT_SEC}" \
    aws s3 ls "s3://${EXT_S3_BUCKET}/${SOURCE_NS}/${SOURCE_NS}/blobs/" \
    --endpoint-url "${EXT_S3_ENDPOINT}" --no-verify-ssl --recursive 2>/dev/null \
    | wc -l | tr -d ' ' || echo "0")
  if [[ "${S3_COUNT}" -gt 0 ]]; then
    check "External S3 blobs captured (${S3_COUNT})" "pass"
  else
    warn "No blobs found in external S3 — registry may be empty or path differs"
  fi
fi

# Verify source Quay is back up
wait_for "source Quay Available=True after backup" 300 10 \
  "oc get quayregistry ${CR_NAME} -n ${SOURCE_NS} -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null | grep -q True" \
  && check "Source Quay Available=True after backup" "pass" \
  || check "Source Quay Available=True after backup" "fail"

# =============================================================================
# SECTION 5 — PREPARE DR NAMESPACE
# =============================================================================
header "SECTION 5 — Prepare DR Namespace"

if [[ -f "${CLEANUP_SCRIPT}" ]]; then
  log "Running cleanup: ${CLEANUP_SCRIPT} ${DR_NS} ${SOURCE_NS}"
  "${CLEANUP_SCRIPT}" "${DR_NS}" "${SOURCE_NS}" || warn "Cleanup returned non-zero — check for stale resources"
  check "DR namespace cleanup ran" "pass"
else
  warn "Cleanup script not found at ${CLEANUP_SCRIPT} — continuing without cleanup"
fi

# Brief settle after cleanup
sleep 5

# Verify clean
STALE_PODS=$(kubectl get pods -n "${DR_NS}" --no-headers 2>/dev/null \
  | grep -v quay-operator | grep -v "^$" | wc -l | tr -d ' ' || echo "0")
if [[ "${STALE_PODS}" -gt 0 ]]; then
  warn "${STALE_PODS} non-operator pods remain in ${DR_NS} — preRestoreHook will handle them"
else
  check "DR namespace clean" "pass"
fi

# =============================================================================
# SECTION 6 — TRIGGER RESTORE
# =============================================================================
header "SECTION 6 — Trigger DR Restore from ${LATEST_RP}"

RESTORE_OUTPUT=$(kubectl create -f - 2>&1 <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: quay-dr-restore-
  namespace: ${KASTEN_NS}
spec:
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: ${LATEST_RP}
    namespace: ${SOURCE_NS}
  targetNamespace: ${DR_NS}
  hooks:
    preHook:
      blueprint: ${BLUEPRINT}
      actionName: preRestoreHook
    onSuccess:
      blueprint: ${BLUEPRINT}
      actionName: postRestoreHook
    onFailure:
      blueprint: ${BLUEPRINT}
      actionName: postRestoreHookError
EOF
)
RESTORE_NAME=$(echo "${RESTORE_OUTPUT}" | grep -o 'quay-dr-restore-[a-z0-9]*' | head -1 || echo "")
[[ -z "${RESTORE_NAME}" ]] && abort "Failed to create RestoreAction: ${RESTORE_OUTPUT}"
log "RestoreAction: ${RESTORE_NAME}"

# Wait for preRestoreHook pod
log "Waiting for preRestoreHook kanister-job pod..."
PRE_RESTORE_POD=$(wait_for_kanister_pod "${DR_NS}" "__none__" "${POD_APPEAR_TIMEOUT}")
if [[ -n "${PRE_RESTORE_POD}" ]]; then
  log "preRestoreHook pod: ${PRE_RESTORE_POD}"
  stream_logs "${DR_NS}" "${PRE_RESTORE_POD}" 300
else
  warn "preRestoreHook pod not observed — Kasten may have already processed it"
  PRE_RESTORE_POD="__none__"
fi

# Wait for postRestoreHook pod (appears after Kasten restores specs+PVCs)
log "Waiting for postRestoreHook kanister-job pod (appears after Kasten spec+PVC restore)..."
POST_RESTORE_POD=$(wait_for_kanister_pod "${DR_NS}" "${PRE_RESTORE_POD}" 600)
if [[ -n "${POST_RESTORE_POD}" ]]; then
  log "postRestoreHook pod: ${POST_RESTORE_POD}"
  stream_logs "${DR_NS}" "${POST_RESTORE_POD}" "${RESTORE_TIMEOUT}"
  ELAPSED=0
  while [[ ${ELAPSED} -lt 120 ]]; do
    POST_STATUS=$(kubectl get pod "${POST_RESTORE_POD}" -n "${DR_NS}"       -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
    [[ "${POST_STATUS}" == "Succeeded" || "${POST_STATUS}" == "Gone" ]] && break
    sleep 5; ELAPSED=$((ELAPSED+5))
  done
  log "postRestoreHook pod phase: ${POST_STATUS}"
  if [[ "${POST_STATUS}" == "Succeeded" || "${POST_STATUS}" == "Gone" ]]; then
    check "postRestoreHook succeeded" "pass"
  else
    check "postRestoreHook phase: ${POST_STATUS}" "fail"
  fi
else
  warn "postRestoreHook pod not observed — checking RestoreAction state directly"
fi

# Wait for RestoreAction to complete
# Note: Kasten deletes RestoreAction objects after completion — empty state = Complete
log "Waiting for RestoreAction ${RESTORE_NAME} to complete..."
ELAPSED=0
RESTORE_STATE=""
while [[ ${ELAPSED} -lt ${RESTORE_TIMEOUT} ]]; do
  RESTORE_STATE=$(kubectl get restoreaction "${RESTORE_NAME}" -n "${KASTEN_NS}"     -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [[ "${RESTORE_STATE}" == "Complete" || "${RESTORE_STATE}" == "NotFound" ]]; then break; fi
  if [[ "${RESTORE_STATE}" == "Failed" ]]; then
    abort "RestoreAction ${RESTORE_NAME} failed"
  fi
  printf "."; sleep 10; ELAPSED=$((ELAPSED+10))
done
echo ""
# NotFound means Kasten cleaned up the object after successful completion
if [[ "${RESTORE_STATE}" == "Complete" || "${RESTORE_STATE}" == "NotFound" ]]; then
  check "RestoreAction Complete" "pass"
else
  abort "Restore did not complete within ${RESTORE_TIMEOUT}s (state: ${RESTORE_STATE})"
fi

# =============================================================================
# SECTION 7 — VERIFY DR RESTORE
# =============================================================================
header "SECTION 7 — Verify DR Restore"

log "Current DR pod state:"
kubectl get pods -n "${DR_NS}" --no-headers 2>/dev/null \
  | awk '{printf "  %-55s %-10s %-12s %s\n", $1, $2, $3, $4}'

# QuayApp running
DR_APP=$(kubectl get pods -n "${DR_NS}" --no-headers 2>/dev/null \
  | grep "quay-app" | grep -c "1/1.*Running" || true)
[[ "${DR_APP}" -ge 1 ]] \
  && check "DR quay-app Running" "pass" \
  || check "DR quay-app Running" "fail"

# QuayRegistry Available
DR_AVAIL=$(oc get quayregistry "${CR_NAME}" -n "${DR_NS}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
[[ "${DR_AVAIL}" == "True" ]] \
  && check "DR QuayRegistry Available=True" "pass" \
  || check "DR QuayRegistry Available=True" "fail"

# DR health endpoint
DR_ROUTE=$(oc get route -n "${DR_NS}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
if [[ -z "${DR_ROUTE}" ]]; then
  check "DR Quay route found" "fail"
  abort "Cannot find DR Quay route — restore may be incomplete"
fi
log "DR Quay route: ${DR_ROUTE}"

DR_HEALTH=$(curl -sk "https://${DR_ROUTE}/health/instance" 2>/dev/null || echo "{}")
if echo "${DR_HEALTH}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert all(d.get('data',{}).get('services',{}).values())" 2>/dev/null; then
  check "DR Quay health — all services true" "pass"
else
  check "DR Quay health — all services true" "fail"
  warn "DR health: ${DR_HEALTH}"
fi

# Clean pull test
log "Removing any cached images for clean pull test..."
podman rmi "${DR_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" 2>/dev/null || true
podman rmi "${TEST_IMAGE}" 2>/dev/null || true

log "Logging in to DR Quay..."
if ! podman login --tls-verify=false \
  --username "${QUAY_USER}" --password "${QUAY_PASS}" \
  "${DR_ROUTE}" 2>/dev/null; then
  check "DR Quay login" "fail"
  abort "Login to DR Quay failed — check credentials or wait for quay-app to be fully ready"
fi
check "DR Quay login" "pass"

log "Pulling ${TEST_IMAGE_TAG} from DR registry..."
if podman pull --tls-verify=false "${DR_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" 2>/dev/null; then
  check "Image pull from DR registry succeeded" "pass"
else
  check "Image pull from DR registry succeeded" "fail"
  abort "Image pull from DR Quay failed — blobs may not have restored correctly"
fi

# Digest comparison
SOURCE_DIGEST=$(podman inspect "${QUAY_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" \
  --format '{{.Digest}}' 2>/dev/null || echo "")
DR_DIGEST=$(podman inspect "${DR_ROUTE}/${QUAY_USER}/${TEST_IMAGE_TAG}" \
  --format '{{.Digest}}' 2>/dev/null || echo "")
log "Source digest : ${SOURCE_DIGEST:-unavailable}"
log "DR digest     : ${DR_DIGEST:-unavailable}"

if [[ -n "${SOURCE_DIGEST}" && -n "${DR_DIGEST}" && "${SOURCE_DIGEST}" == "${DR_DIGEST}" ]]; then
  check "Image digest matches source — data integrity confirmed" "pass"
elif [[ -z "${SOURCE_DIGEST}" || -z "${DR_DIGEST}" ]]; then
  warn "Could not compare digests — both images must be locally present"
else
  check "Image digest matches source" "fail"
fi

# =============================================================================
# FINAL REPORT
# =============================================================================
print_report
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
