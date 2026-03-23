# RH Quay Operator — Kasten Blueprint

Kanister Blueprint for backup and restore of Red Hat Quay Operator 3.13.2
on OpenShift Container Platform using Veeam Kasten.

## Repository Structure
```
├── customer/                             # Customer-facing files
│   ├── Dockerfile                        # Build the quay-kanister-tools image
│   ├── quay-kanister-blueprint.yaml      # Production Kanister Blueprint v2.1.0
│   ├── quay-kanister-rbac.yaml           # RBAC for Kanister pod permissions
│   └── docs/
│       └── backup_restore_runbook.md     # Full backup & restore runbook
│
└── internal/                             # Internal/lab use only
    ├── quay-kanister-blueprint-lab.yaml  # Lab blueprint (replicas:1, HPA suppression)
    ├── scripts/
    │   ├── quay_install_setup.sh         # Quay installation steps
    │   ├── quay_backup.sh                # Manual backup script
    │   ├── quay_restore.sh               # Manual restore script
    │   └── test-app-dr-deploy.sh         # DR test app deployment
    ├── actionsets/
    │   └── quay-actionsets.yaml          # Kanister ActionSet examples
    └── test-apps/
        ├── test-app-source.yaml          # Source registry test app
        └── test-app-dr.yaml              # DR registry test app
```

## Quick Start

See [customer/docs/backup_restore_runbook.md](customer/docs/backup_restore_runbook.md)
for complete backup and restore instructions.

## Validated Environment

| Component | Version |
|---|---|
| Red Hat Quay | 3.13.2 |
| OpenShift | 4.14 |
| Veeam Kasten | 8.5.4 |
| Kanister | 0.118.0 |
| kanister-tools image | docker.io/pvanka86/quay-kanister-tools:1.0.0 |
