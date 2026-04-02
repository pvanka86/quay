# Red Hat Quay Operator — Veeam Kasten Backup & Restore

Kanister Blueprint for backup and restore of Red Hat Quay Operator on
OpenShift Container Platform using Veeam Kasten.

## Repository Structure

```
├── customer/                              # Customer and production files
│   ├── README.md                          # Full customer guide — start here
│   ├── quay-kanister-blueprint.yaml       # Production blueprint v6.0.0
│   ├── quay-kanister-rbac.yaml            # RBAC for Kanister pod permissions
│   ├── quay-kanister-credentials.yaml     # Admin credentials secret template
│   ├── quay-backup-policy.yaml            # Kasten backup policy template
│   ├── quay-restore-action.yaml           # Kasten RestoreAction template
│   ├── quay-dr-cleanup.sh                 # DR namespace cleanup script
│   └── Dockerfile                         # Builds quay-kanister-tools image
│
└── internal/                              # SE lab and internal use only
    ├── README.md                          # Internal guide
    ├── quay-kanister-blueprint-lab.yaml   # Lab blueprint v5
    ├── quay-backup-policy-lab.yaml        # Lab backup policy
    └── quay_e2e_test.sh                   # End-to-end automated test script
```

## Quick Start

See **[customer/README.md](customer/README.md)** for the full guide including
prerequisites, setup steps, backup and restore walkthroughs, all options,
and troubleshooting.

## Validated Environment

| Component | Version |
|---|---|
| Red Hat Quay | 3.13.2 |
| Quay Operator | 3.13.2 |
| OpenShift Container Platform | 4.14+ |
| Veeam Kasten | 8.5.5 |
| quay-kanister-tools image | `docker.io/pvanka86/quay-kanister-tools:2.0.0` |
