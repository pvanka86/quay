# =============================================================================
# quay-kanister-tools:2.0.0
# Tools image for the Quay Operator Kanister Blueprint
#
# Contains:
#   - oc      (OpenShift CLI 4.14 — matches OCP 4.x)
#   - kubectl (bundled with oc)
#   - python3 + PyYAML + bcrypt  (manifest cleanup, bcrypt password reset)
#   - aws CLI v2                 (NooBaa ↔ external S3 blob sync)
#   - bash, curl, tar, gzip, jq (general scripting utilities)
#
# Build:
#   podman build -t docker.io/pvanka86/quay-kanister-tools:2.0.0 .
#   podman push docker.io/pvanka86/quay-kanister-tools:2.0.0
#
# OpenShift compatibility:
#   - Runs as non-root (USER 65532) by default
#   - runAsUser: 0 override used by Kasten KubeTask pods (podOverride in policy)
# =============================================================================

FROM registry.access.redhat.com/ubi9/ubi:latest

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN dnf install -y --allowerasing \
      bash \
      curl \
      tar \
      gzip \
      unzip \
      jq \
      python3 \
      python3-pip \
      ca-certificates \
      less \
      findutils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# ---------------------------------------------------------------------------
# Python packages — PyYAML for manifest cleanup, bcrypt for password reset
# ---------------------------------------------------------------------------
RUN pip3 install --no-cache-dir \
      PyYAML==6.0.2 \
      bcrypt==4.2.1

# ---------------------------------------------------------------------------
# OpenShift CLI (oc) — 4.14 stable, linux amd64
# Provides both `oc` and `kubectl`
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.14/openshift-client-linux.tar.gz" \
      -o /tmp/oc.tar.gz \
    && tar -C /usr/local/bin -xzf /tmp/oc.tar.gz oc kubectl \
    && rm /tmp/oc.tar.gz \
    && oc version --client \
    && kubectl version --client

# ---------------------------------------------------------------------------
# AWS CLI v2 — official installer, linux x86_64
# Supports --endpoint-url and --no-verify-ssl required for NooBaa S3
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

# ---------------------------------------------------------------------------
# Verification — fail the build if any tool is missing
# ---------------------------------------------------------------------------
RUN oc version --client \
    && python3 -c "import yaml; import bcrypt; print('Python packages OK')" \
    && aws --version \
    && echo "All tools verified"

# ---------------------------------------------------------------------------
# Runtime — run as non-root by default
# Kasten overrides to root via podOverride.securityContext.runAsUser: 0
# ---------------------------------------------------------------------------
USER 65532

ENTRYPOINT ["/bin/bash"]
