# Supabase Backup & Restore Toolkit

This toolkit provides automated, DRY (Don't Repeat Yourself) scripts to safely backup and restore an entire Supabase project. It handles both the PostgreSQL database (roles, schema, rows) using the Supabase CLI, and all S3-compatible physical storage files using `rclone`.

## Prerequisites

Before using these scripts, ensure you have the following installed:

- [Supabase CLI](https://supabase.com/docs/guides/cli) (`brew install supabase/tap/supabase`)
- [Rclone](https://rclone.org/) (`brew install rclone`)
- PostgreSQL Client (`psql`)

## Setup

### Step 1: Environment Setup

1. Duplicate `sample.env` and rename it to `.env`
2. Retrieve your database connection strings from the Supabase Dashboard:
   - Navigate to **Project Settings** > **Database** > **Connection String (URI)**
3. Replace the placeholder `<PASSWORD>` with your actual database passwords for both your Production and Target (Test) environments

### Step 2: Storage Setup

1. Duplicate `rclone.conf.template` and rename it to `rclone.conf`
2. Generate S3 credentials in the Supabase Dashboard:
   - Navigate to **Project Settings** > **Storage** > **S3 Connection**
   - Generate a new Access Key for both your Production (Source) and Target (Test) environments
3. Fill in the following fields in `rclone.conf`:
   - `<PROJECT_ID>`
   - `<ACCESS_KEY>`
   - `<SECRET_KEY>`
   - `<REGION>`

> **Security Note:** Both `.env` and `rclone.conf` contain sensitive credentials. Never commit these files to version control.

## Usage

### Backup (Production)

To take a full snapshot of your source database and download all storage files:

1. Make both scripts executable:
   ```bash
   chmod +x full_backup.sh full_restore.sh
   ```

2. Run the backup script:
   ```bash
   ./full_backup.sh
   ```

This generates a timestamped backup directory (e.g., `backups/supabase_backup_20260412_183000`) containing:
- `.sql` dumps with roles, schema, and data
- `storage/` subdirectory with all physical storage files

> **Note:** The data dump automatically excludes vector indices to ensure the file remains safely restorable.

### Restore (Test Environment)

To clone a backup into your target environment:

```bash
# Target environment: test
./full_restore.sh test ./backups/supabase_backup_20260412_183000

# Target environment: prod
./full_restore.sh prod ./backups/supabase_backup_20260412_183000
```

#### Built-in Safety Features

**Confirmation Prompt**
- The script will request confirmation before executing any destructive actions

**Automated Safety Snapshot**
- Before modifying your target database, `full_restore.sh` automatically creates a pre-restore backup (e.g., `target_pre_restore_backup_XYZ`)
- If anything goes wrong, you have an immediate fallback

**1:1 Storage Sync**
- Storage restores use `rclone sync`, which means any files in the target bucket that don't exist in the backup will be permanently deleted
- Ensures a perfect 1:1 clone with no orphaned files