# Internal — Lab & Development Files

> ⚠️ These files are for **internal lab use only**.  
> Do not share with customers. Customer-facing files are in `../customer/`.

## Files

| File/Folder | Purpose |
|---|---|
| `quay-kanister-blueprint-lab.yaml` | Lab blueprint — enforces `replicas:1`, 90s HPA suppression loop, retry on HPA conflict |
| `scripts/quay_install_setup.sh` | Quay Operator installation and setup steps |
| `scripts/quay_backup.sh` | Manual backup script (without Kasten) |
| `scripts/quay_restore.sh` | Manual restore script (without Kasten) |
| `scripts/test-app-dr-deploy.sh` | DR test app deployment after restore |
| `actionsets/quay-actionsets.yaml` | Kanister ActionSet YAML examples |
| `test-apps/test-app-source.yaml` | Test app pulling from source Quay registry |
| `test-apps/test-app-dr.yaml` | Test app pulling from DR Quay registry |

## Lab Blueprint vs Production Blueprint

| Feature | Production | Lab |
|---|---|---|
| HPA suppression | Patch + delete twice | 90s loop deleting every 10s |
| Scale up replicas | 1 | 1 |
| HPA delete on scaleDown | Single attempt | Retry loop with conflict handling |
| Verification on scale up | None | `oc get pods` + `oc get hpa` |

## Usage

### Manual Backup
```bash
source ../../env.sh
bash scripts/quay_backup.sh
```

### Manual Restore
```bash
export BACKUP_DIR="./quay-backup-YYYYMMDD-HHMMSS"
bash scripts/quay_restore.sh
```

### Deploy DR Test App (after Kasten blueprint restore)
```bash
source ../../env.sh
bash scripts/test-app-dr-deploy.sh
```

### Deploy DR Test App (after manual restore — password reset needed)
```bash
source ../../env.sh
RESET_PASSWORD=true bash scripts/test-app-dr-deploy.sh
```

## Lab Environment

| Setting | Value |
|---|---|
| Source namespace | `quay` |
| DR namespace | `quay-dr` |
| Quay CR name | `quay-registry` |
| OCP cluster | SE Lab Bare-Metal |
| Kasten version | 8.5.4 |
