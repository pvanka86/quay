# =============================================================================
# quay-kanister-tools — Multi-stage Dockerfile
# =============================================================================
# Stage 1: extract kando binary from the official kanister-tools image
# Stage 2: build final image on UBI9 (full package manager, no conflicts)
#
# Why multi-stage?
#   - kanister-tools is distroless (no package manager, no tar, no shell utils)
#   - UBI9 has dnf and all the tools we need, but no kando
#   - Multi-stage gives us both: copy kando from stage 1 into stage 2
#
# Build:
#   podman build --platform linux/amd64 \
#     -t docker.io/${REGISTRY_USER}/quay-kanister-tools:1.0.0 \
#     -f 05_Dockerfile .
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1 — extract kando from the official distroless kanister-tools image
# ---------------------------------------------------------------------------
FROM ghcr.io/kanisterio/kanister-tools:0.118.0 AS kanister-source

# ---------------------------------------------------------------------------
# Stage 2 — final image built on UBI9 (full dnf package manager)
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest

LABEL maintainer="your-team@example.com" \
      description="Kanister Blueprint image for Red Hat Quay Operator" \
      quay.version="3.13.x" \
      kanister.version="0.118.0"

ARG OC_VERSION="4.14"

# ---------------------------------------------------------------------------
# Step 1 — copy kando binary from stage 1
# ---------------------------------------------------------------------------
COPY --from=kanister-source /usr/local/bin/kando /usr/local/bin/kando

# ---------------------------------------------------------------------------
# Step 2 — install system packages (dnf available on UBI9)
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
      openssl \
      ca-certificates \
      findutils \
    && dnf clean all

# ---------------------------------------------------------------------------
# Step 3 — PyYAML for YAML manifest cleanup in Blueprint phases
# ---------------------------------------------------------------------------
RUN pip3 install --no-cache-dir PyYAML==6.0.1

# ---------------------------------------------------------------------------
# Step 4 — oc + kubectl from OpenShift mirror (amd64, matches --platform)
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OC_VERSION}/openshift-client-linux.tar.gz" \
      -o /tmp/oc.tar.gz \
    && tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl \
    && rm /tmp/oc.tar.gz \
    && oc version --client \
    && kubectl version --client

# ---------------------------------------------------------------------------
# Step 5 — AWS CLI v2 (amd64, matches --platform linux/amd64)
# ---------------------------------------------------------------------------
RUN curl -fsSL \
      "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && aws --version

# ---------------------------------------------------------------------------
# Step 6 — Smoke test: verify ALL tools are present and executable
# ---------------------------------------------------------------------------
RUN echo "=== Verifying all tools ===" \
    && oc version --client \
    && kubectl version --client \
    && aws --version \
    && kando --help 2>&1 | head -1 \
    && python3 -c "import yaml; print('PyYAML OK:', yaml.__version__)" \
    && echo "=== All tools verified ==="

# ---------------------------------------------------------------------------
# Non-root user — OCP runs containers as arbitrary UIDs
# ---------------------------------------------------------------------------
RUN useradd -u 1001 -r -g 0 -s /sbin/nologin \
      -c "Blueprint runner" kanister \
    && mkdir -p /home/kanister \
    && chown -R 1001:0 /home/kanister \
    && chmod -R g=u /home/kanister

USER 1001
WORKDIR /home/kanister

ENTRYPOINT ["/bin/bash"]
CMD ["-c", "echo 'quay-kanister-tools ready' && oc version --client && aws --version && kando --help 2>&1 | head -1"]
