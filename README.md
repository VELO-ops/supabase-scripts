# Supabase Backup & Restore Toolkit

This toolkit provides automated, DRY scripts to safely backup and restore an entire Supabase project. It handles the PostgreSQL database (Roles, Schema, Rows) via the Supabase CLI, and all S3-compatible physical storage files via `rclone`.

## Key Features

- **Infinite Scaling:** Backup Prod, Test, or _any_ custom Supabase project on the fly just by providing its database URL.
- **Smart Remote Detection:** Automatically parses your DB URL to find the matching S3 credentials in your `rclone.conf`.
- **Universal URL Patching:** Uses Regex to dynamically rewrite _any_ Supabase project ID (in file URLs, Webhooks, or API endpoints) during a restore to perfectly match the target environment.
- **Automated Safety Nets:** Restores automatically trigger a pre-restore safety snapshot of the target environment before executing.
- **Targeted Operations:** Skip heavy data/file syncs using the `--schema-only` (restore) or `--db-only` (backup) flags.

## ⚠️ Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) (`brew install supabase/tap/supabase`)
- [Rclone](https://rclone.org/) (`brew install rclone`)
- PostgreSQL Client (`psql`)

## ⚙️ Step 1: Environment Setup

1. Duplicate `sample.env` and rename it to `.env`.
2. Find your Database Connection Strings in the Supabase Dashboard: **Project Settings > Database > Connection String (URI)**.
3. Fill in the `.env` file for your primary environments:

```env
# .env
PROD_DB_URL="postgresql://postgres.<PROD_REF>:<PASSWORD>@<PROD_REGION>.pooler.supabase.com:5432/postgres"
TEST_DB_URL="postgresql://postgres.<TEST_REF>:<PASSWORD>@<TEST_REGION>.pooler.supabase.com:5432/postgres"
```

## 🪣 Step 2: Storage Setup

1. Duplicate `rclone.conf.template` and rename it to `rclone.conf`.
2. Generate your S3 credentials in the Supabase Dashboard: Project Settings > Storage > S3 Connection.
3. Generate a new Access Key for each environment you want to backup.
4. Fill in the `<PROJECT_ID>`, `<ACCESS_KEY>`, `<SECRET_KEY>`, and `<REGION>` fields in `rclone.conf`.

**🚨 Security Note:** Ensure `.env` and `rclone.conf` are in your `.gitignore` to prevent credential leaks!

## ⚡ Step 3: Executables

Make the scripts are executable:

```bash
chmod +x backup.sh restore.sh
```

## 💾 How to Backup

Backups are dynamically generated and saved inside a master `./backups/` directory.

### Interactive Mode

Run the script with no arguments to be prompted for an environment or a custom database URL:

```bash
./backup.sh
```

### Quick Commands

```bash
# Backup Production
./backup.sh prod

# Backup Test
./backup.sh test

# Backup a brand new/custom project on the fly
./backup.sh postgresql://postgres.xyz...:PASSWORD@...
```

### Backup Flags

Add `--db-only` anywhere in your command to skip the physical S3 storage sync and only snapshot your database (Roles, Schema, and Data).

```bash
./backup.sh prod --db-only
```

## 💥 How to Restore (or Migrate)

You can restore a backup to its original environment, or cross-migrate data between environments.

1. Ensure the script is executable: `chmod +x restore.sh`
2. Run the script, passing the target environment and the specific backup folder:

```bash
# Clone a backup INTO Test
./restore.sh test ./backups/prod_backup_20260413_083000

# Promote a backup INTO Production
./restore.sh prod ./backups/test_backup_20260413_091500
```

### Restore Flags

Add `--schema-only` to inject the pure structure of your database (Roles, Schema, Constraints, Webhooks) while explicitly skipping dummy table rows and dummy S3 images. Perfect for pre-launch production syncing!

```bash
./restore.sh prod ./backups/test_backup_XYZ --schema-only
```

**Caveat:** Because Supabase Buckets are stored as data rows, a `--schema-only` restore will not recreate your buckets. The script will output a handy list of buckets you need to manually recreate via the Dashboard when it finishes.

### What Happens During a Restore?

1. **Confirmation:** Prompts to ensure you intend to overwrite the target.
2. **Safety Snapshot:** Automatically backs up the current state of the target environment to `./backups/target_pre_restore_backup_...`.
3. **Automated Wipe:** Safely drops the target's public schema and truncates auth and storage tables.
4. **Universal URL Patching & Injection:** Streams the `.sql` schema and data directly into the database. While in memory, it uses Regex to hunt down any old Supabase domains (in webhooks, text columns, or JSON objects) and rewrites them to match the new target environment.
5. **Physical Sync:** Syncs physical S3 files, forcefully resolving any orphaned metadata.
