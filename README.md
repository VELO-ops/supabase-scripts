# Supabase Backup & Restore Toolkit

This toolkit provides automated scripts to safely backup and restore an entire Supabase project, including the PostgreSQL database (roles, schema, rows) and all S3-compatible physical storage files via `rclone`.

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
3. Replace the placeholder `<PASSWORD>` with your actual database passwords

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

## Usage

### Backup (Production)

To take a full snapshot of your source database and download all storage files:

1. Make the script executable:
   ```bash
   chmod +x full_backup.sh
   ```

2. Run the backup:
   ```bash
   ./full_backup.sh
   ```

This generates a timestamped backup directory (e.g., `supabase_backup_20260412_183000`) containing:
- `.sql` database dumps
- `storage/` subdirectory with all physical storage files

### Restore (Test Environment)

To clone a backup into your target environment:

1. Make the script executable:
   ```bash
   chmod +x full_restore.sh
   ```

2. Run the restore, specifying the backup directory:
   ```bash
   ./full_restore.sh ./supabase_backup_20260412_183000
   ```

#### Safety Features

The restore script includes multiple safeguards:

- **Confirmation prompt** before execution
- **Pre-restore backup** of the target environment (automatic recovery point)
- **Manual pause** to allow you to run database wipe commands (`TRUNCATE`, `DROP SCHEMA`, etc.) before injection
- **Destructive sync** via `rclone sync` — files in the target bucket that don't exist in the backup will be permanently deleted to ensure a 1:1 clone