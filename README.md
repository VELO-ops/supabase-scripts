# Supabase Backup & Restore Toolkit

This toolkit provides automated, DRY scripts to safely backup and restore an entire Supabase project. It handles the PostgreSQL database (roles, schema, rows) via the Supabase CLI, and all S3-compatible physical storage files via `rclone`.

## Key Features

- **Cross-Environment Migrations:** Seamlessly move data between Test and Prod
- **On-the-Fly URL Patching:** Storage URLs inside your database are dynamically rewritten during a restore to match the target environment (no broken images!)
- **Automated Safety Nets:** Restores automatically trigger a pre-restore safety snapshot of the target environment before executing

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) (`brew install supabase/tap/supabase`)
- [Rclone](https://rclone.org/) (`brew install rclone`)
- PostgreSQL Client (`psql`)

## Setup

### Step 1: Environment Setup

1. Duplicate `sample.env` and rename it to `.env`
2. Retrieve your database connection strings from the Supabase Dashboard:
   - Navigate to **Project Settings** > **Database** > **Connection String (URI)**
3. Locate your 20-character Project Reference IDs in your Supabase Dashboard URLs (e.g., `https://supabase.com/dashboard/project/<PROJECT_REF>`)
4. Fill in the `.env` file with your credentials:

```env
PROD_DB_URL="postgresql://postgres.<PROD_REF>:<PASSWORD>@<PROD_REGION>.pooler.supabase.com:5432/postgres"
TEST_DB_URL="postgresql://postgres.<TEST_REF>:<PASSWORD>@<TEST_REGION>.pooler.supabase.com:5432/postgres"

PROD_REF="<PROD_REF>"
TEST_REF="<TEST_REF>"
```

### Step 2: Storage Setup

1. Duplicate `rclone.conf.template` and rename it to `rclone.conf`
2. Generate S3 credentials in the Supabase Dashboard:
   - Navigate to **Project Settings** > **Storage** > **S3 Connection**
   - Generate a new Access Key for both environments
3. Fill in the following fields in `rclone.conf`:
   - `<PROJECT_ID>`
   - `<ACCESS_KEY>`
   - `<SECRET_KEY>`
   - `<REGION>`

> **Security Note:** Ensure `.env` and `rclone.conf` are in your `.gitignore` to prevent credential leaks. These files contain sensitive database passwords and S3 keys.

### Step 3: Executables

1. Make the scripts executable:
   ```bash
   chmod +x full_backup.sh full_restore.sh
   ```

## Usage

### Backup

Backups are dynamically generated and saved inside a master `./backups/` directory.
Run the backup script with your target environment:
   ```bash
   # Backup Production (default)
   ./full_backup.sh prod

   # Backup Test
   ./full_backup.sh test
   ```

This generates a nested, timestamped folder (e.g., `./backups/prod_backup_20260413_083000`) containing:
- `.sql` database dumps
- `storage/` subdirectory with all physical storage files

### Restore (or Migrate)

You can restore a backup to its original environment, or cross-migrate data between environments (e.g., pulling Prod down to Test).

Run the restore script, specifying the target environment and backup folder:
   ```bash
   # Clone a backup into Test
   ./full_restore.sh test ./backups/prod_backup_20260413_083000

   # Promote a backup into Production
   ./full_restore.sh prod ./backups/test_backup_20260413_091500
   ```

#### Restore Workflow

The restore process executes the following steps:

1. **Confirmation:** Prompts to ensure you intend to overwrite the target environment
2. **Safety Snapshot:** Automatically backs up the current state of the target environment to `./backups/target_pre_restore_backup_...`
3. **Automated Wipe:** Safely drops the target's `public` schema and truncates `auth` and `storage` tables
4. **URL Patching & Injection:** Streams the `.sql` data directly into the database, dynamically replacing any old Supabase Project IDs with the new Target Project ID in memory
5. **Physical Sync:** Syncs physical S3 files, forcefully resolving any orphaned metadata