#!/usr/bin/env bash
# =============================================================================
# RH Quay Operator - Installation & Setup Script
# Target:    OpenShift Container Platform (OCP)
# Quay Ver:  3.13.2
# Namespace: quay (source)  |  quay-dr (DR - operator only, no CR)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURABLE VARIABLES - edit before running
# ---------------------------------------------------------------------------
SOURCE_NS="quay"
DR_NS="quay-dr"
QUAY_CR_NAME="quay-registry"
QUAY_USER="praveen"
QUAY_PASSWORD="password"
QUAY_EMAIL="praveen@example.com"
QUAY_HOST="quay-registry-quay-quay.apps.kasten-se-lab-baremetal.kasten.veeam.local"
QUAY_DR_HOST="quay-registry-quay-quay-dr.apps.kasten-se-lab-baremetal.kasten.veeam.local"
TEST_APP_NS="test-app"
STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
BUSYBOX_IMAGE="docker.io/library/busybox"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
info()    { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_prereqs() {
  info "Checking prerequisites..."
  for cmd in oc kubectl podman; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
  oc whoami &>/dev/null || die "Not logged in to OpenShift. Run 'oc login' first."
  success "Prerequisites OK"
}

# ---------------------------------------------------------------------------
# STEP 1 — Create source namespace
# ---------------------------------------------------------------------------
step1_create_namespace() {
  info "Step 1: Creating source namespace '$SOURCE_NS'..."
  oc new-project "$SOURCE_NS" 2>/dev/null || warn "Namespace '$SOURCE_NS' already exists"
  success "Namespace '$SOURCE_NS' ready"
}

# ---------------------------------------------------------------------------
# STEP 2 — Deploy QuayRegistry CR with defaults
# ---------------------------------------------------------------------------
step2_deploy_quay_cr() {
  info "Step 2: Deploying QuayRegistry CR '$QUAY_CR_NAME' in '$SOURCE_NS'..."
  cat <<EOF | kubectl apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: ${QUAY_CR_NAME}
  namespace: ${SOURCE_NS}
EOF
  success "QuayRegistry CR applied"
}

# ---------------------------------------------------------------------------
# STEP 3 — Wait for registryEndpoint to be populated
# ---------------------------------------------------------------------------
step3_wait_for_endpoint() {
  info "Step 3: Waiting for registryEndpoint to be populated (timeout 10 min)..."
  local endpoint=""
  local retries=60
  while [[ -z "$endpoint" && $retries -gt 0 ]]; do
    endpoint=$(oc get quayregistry -n "$SOURCE_NS" "$QUAY_CR_NAME" \
      -o jsonpath="{.status.registryEndpoint}" 2>/dev/null || true)
    [[ -z "$endpoint" ]] && { sleep 10; ((retries--)); }
  done
  [[ -z "$endpoint" ]] && die "Timed out waiting for registryEndpoint"
  success "registryEndpoint: $endpoint"
}

# ---------------------------------------------------------------------------
# STEP 4 — Wait for all pods to be Running
# ---------------------------------------------------------------------------
step4_wait_for_pods() {
  info "Step 4: Waiting for all Quay pods to be Running (timeout 15 min)..."
  oc wait pod --all -n "$SOURCE_NS" \
    --for=condition=Ready \
    --timeout=900s || warn "Some pods may not be fully Ready yet - check 'oc get pods -n $SOURCE_NS'"
  success "Quay pods are Running"
}

# ---------------------------------------------------------------------------
# STEP 5 — Note: First user must be created via the Quay UI
# ---------------------------------------------------------------------------
step5_note_first_user() {
  info "Step 5: Create the first Quay user via the web UI."
  local ep
  ep=$(oc get quayregistry -n "$SOURCE_NS" "$QUAY_CR_NAME" \
    -o jsonpath="{.status.registryEndpoint}" 2>/dev/null || echo "<check endpoint>")
  echo "  → Open: ${ep}/api/v1/user/initialize"
  echo "  → Ref:  https://docs.redhat.com/en/documentation/red_hat_quay/3.13/html/"
  echo "           deploying_the_red_hat_quay_operator_on_openshift_container_platform/"
  echo "           operator-monitor-deploy-cli#operator-first-user"
}

# ---------------------------------------------------------------------------
# STEP 6-8 — Push test image to Quay
# ---------------------------------------------------------------------------
step6_push_test_image() {
  info "Step 6-8: Pushing busybox test image to Quay..."
  podman login --tls-verify=false "$QUAY_HOST" \
    --username "$QUAY_USER" --password "$QUAY_PASSWORD"
  podman pull "$BUSYBOX_IMAGE"
  podman tag "$BUSYBOX_IMAGE" "${QUAY_HOST}/${QUAY_USER}/busybox"
  podman push --tls-verify=false "${QUAY_HOST}/${QUAY_USER}/busybox"
  success "busybox image pushed to ${QUAY_HOST}/${QUAY_USER}/busybox"
  warn "Ensure the repository visibility is set to Public in the Quay UI."
}

# ---------------------------------------------------------------------------
# STEP 9 — Configure InsecureRegistry (self-signed certs only)
# ---------------------------------------------------------------------------
step9_configure_insecure_registry() {
  info "Step 9: Configuring InsecureRegistry for self-signed certs..."

  # 9a — Create ICSP
  cat <<EOF | kubectl apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: quay-insecure
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${QUAY_HOST}
    source: ${QUAY_HOST}
  - mirrors:
    - ${QUAY_DR_HOST}
    source: ${QUAY_DR_HOST}
EOF

  # 9b — Patch Cluster Image Config
  oc patch image.config.openshift.io/cluster --type=merge -p "{
    \"spec\": {
      \"registrySources\": {
        \"insecureRegistries\": [
          \"${QUAY_HOST}\",
          \"${QUAY_DR_HOST}\"
        ]
      }
    }
  }"

  # 9c — Wait for MachineConfigPool to complete rollout
  info "Step 9c: Waiting for MachineConfigPool to complete (this may take 15-30 min)..."
  oc wait mcp --all --for=condition=Updated=True --timeout=1800s \
    || warn "MCP rollout still in progress - run 'oc get mcp' to check"

  # 9d — Verify
  info "Step 9d: Verifying Quay API endpoint..."
  curl -sk "https://${QUAY_HOST}/api/v1/repository/${QUAY_USER}/busybox" | head -c 200
  success "InsecureRegistry configuration complete"
}

# ---------------------------------------------------------------------------
# STEP 10 — Create ImagePullSecret in test-app namespace
# ---------------------------------------------------------------------------
step10_create_pull_secret() {
  info "Step 10: Creating ImagePullSecret in '$TEST_APP_NS'..."
  kubectl create ns "$TEST_APP_NS" 2>/dev/null || warn "Namespace '$TEST_APP_NS' already exists"
  kubectl -n "$TEST_APP_NS" create secret docker-registry quay-pull-secret \
    --docker-server="$QUAY_HOST" \
    --docker-username="$QUAY_USER" \
    --docker-password="$QUAY_PASSWORD" \
    --docker-email="$QUAY_EMAIL" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "ImagePullSecret 'quay-pull-secret' created in '$TEST_APP_NS'"
}

# ---------------------------------------------------------------------------
# STEP 11 — Deploy test application
# ---------------------------------------------------------------------------
step11_deploy_test_app() {
  info "Step 11: Deploying test application in '$TEST_APP_NS'..."
  cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-app-pvc
  namespace: ${TEST_APP_NS}
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
  name: test-app-deploy
  namespace: ${TEST_APP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: test-app-container
        image: ${QUAY_HOST}/${QUAY_USER}/busybox
        imagePullPolicy: IfNotPresent
        command:
        - sh
        - -c
        - |
          cd /data
          echo "starting sleep"
          while true; do sleep 1; done
        volumeMounts:
        - mountPath: /data
          name: data
      imagePullSecrets:
      - name: quay-pull-secret
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: test-app-pvc
EOF
  success "Test application deployed"
}

# ---------------------------------------------------------------------------
# STEP 12 — Verify test app is running
# ---------------------------------------------------------------------------
step12_verify() {
  info "Step 12: Verifying Pod and PVC are Running..."
  kubectl wait pod -l app=test-app -n "$TEST_APP_NS" \
    --for=condition=Ready --timeout=300s \
    || warn "Pod not ready yet - check 'kubectl get pods -n $TEST_APP_NS'"
  kubectl get pods,pvc -n "$TEST_APP_NS"
  success "Test application is running"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  info "============================================================"
  info " RH Quay Operator — Installation & Setup"
  info " Source NS: $SOURCE_NS  |  Quay CR: $QUAY_CR_NAME"
  info "============================================================"

  check_prereqs
  step1_create_namespace
  step2_deploy_quay_cr
  step3_wait_for_endpoint
  step4_wait_for_pods
  step5_note_first_user

  read -rp $'\n[PAUSE] Complete Step 5 (create first user in UI), then press ENTER...' _

  step6_push_test_image
  step9_configure_insecure_registry
  step10_create_pull_secret
  step11_deploy_test_app
  step12_verify

  info "============================================================"
  success "Installation & Setup COMPLETE"
  info "  Quay UI:  https://${QUAY_HOST}/${QUAY_USER}/"
  info "  Verify:   podman pull --tls-verify=false ${QUAY_HOST}/${QUAY_USER}/busybox:latest"
  info "============================================================"
}

main "$@"
