#!/bin/bash

# --- Load Environment Variables ---
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Input Validation ---
ENV_TARGET=$1
BACKUP_DIR=$2

if [[ "$ENV_TARGET" != "test" && "$ENV_TARGET" != "prod" ]]; then
  echo "❌ Error: First argument must be 'test' or 'prod'."
  echo "Usage: ./restore.sh <test|prod> <backup_dir>"
  exit 1
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  echo "❌ Error: Invalid or missing backup directory."
  echo "Usage: ./restore.sh test ./backups/supabase_backup_XYZ"
  exit 1
fi

# --- Configure Target Variables ---
RCLONE_CONFIG="./rclone.conf"

if [ "$ENV_TARGET" == "prod" ]; then
  TARGET_DB_URL=$PROD_DB_URL
  TARGET_RCLONE_REMOTE="prod-supa"
  WARNING_MSG="🔥 DANGER: YOU ARE ABOUT TO WIPE AND OVERWRITE PRODUCTION! 🔥"
  CONFIRM_WORD="I UNDERSTAND"
else
  TARGET_DB_URL=$TEST_DB_URL
  TARGET_RCLONE_REMOTE="test-supa"
  WARNING_MSG="🚨 WARNING: DESTRUCTIVE RESTORE TO TEST INITIATED 🚨"
  CONFIRM_WORD="YES"
fi

# 🎯 Extract the 20-character Target Project ID from the Database URL
if [[ "$TARGET_DB_URL" =~ postgres\.([^:]+) ]]; then
  TARGET_ID="${BASH_REMATCH[1]}"
  echo "🔍 Auto-detected Target Project ID: $TARGET_ID"
else
  echo "❌ Error: Could not extract Project ID from the target DB URL."
  exit 1
fi

# --- 🚨 WARNING 🚨 ---
echo "============================================================"
echo " $WARNING_MSG"
echo "============================================================"
echo "Target Environment: $ENV_TARGET"
echo "Target Database: $TARGET_DB_URL"
echo "Source Backup: $BACKUP_DIR"
echo ""
echo "This will OVERWRITE the target database and DELETE any physical"
echo "storage files in the target that are not in the source backup."
echo "============================================================"
read -p "Type '$CONFIRM_WORD' to proceed with the wipe and restore: " CONFIRM

if [ "$CONFIRM" != "$CONFIRM_WORD" ]; then
  echo "Restore aborted. Your target environment has not been touched."
  exit 0
fi

# --- 🛡️ SAFETY BACKUP PHASE 🛡️ ---
echo ""
echo "------------------------------------------------------------"
echo "🛡️  CREATING SAFETY BACKUP OF $ENV_TARGET ENVIRONMENT..."
echo "------------------------------------------------------------"

./backup.sh "$TARGET_DB_URL" "$TARGET_RCLONE_REMOTE" "${ENV_TARGET}_pre_restore_backup"

if [ $? -ne 0 ]; then
  echo "❌ Safety backup failed! Aborting to protect your environment."
  exit 1
fi
echo "✅ Safety backup complete!"
echo ""

# --- 🧹 AUTOMATED WIPE TARGET 🧹 ---
echo "------------------------------------------------------------"
echo "🧹 WIPING $ENV_TARGET DATABASE..."
echo "------------------------------------------------------------"

psql -d "$TARGET_DB_URL" -c "
  DROP SCHEMA IF EXISTS public CASCADE;
  CREATE SCHEMA public;
  GRANT ALL ON SCHEMA public TO postgres;
  GRANT ALL ON SCHEMA public TO public;
  TRUNCATE auth.users CASCADE;
  TRUNCATE storage.buckets CASCADE;
"

if [ $? -ne 0 ]; then
  echo "❌ Failed to wipe the $ENV_TARGET database. Aborting."
  exit 1
fi
echo "✅ $ENV_TARGET database wiped successfully!"
echo ""

# --- 💥 RESTORE PHASE 💥 ---
echo "------------------------------------------------------------"
echo "🚀 INJECTING BACKUP INTO $ENV_TARGET..."
echo "------------------------------------------------------------"

echo "📦 Restoring Roles..."
psql -d "$TARGET_DB_URL" -f "$BACKUP_DIR/roles.sql"

echo "🔗 Patching Webhooks in Schema and Restoring on the fly..."
# Finds ANY 20-character Supabase ID and replaces it with the Target ID
cat "$BACKUP_DIR/schema.sql" \
  | sed -E "s/[a-z0-9]{20}\.supabase\.co/$TARGET_ID\.supabase\.co/g" \
  | psql -d "$TARGET_DB_URL"

echo "🔗 Patching URLs in Data and Restoring on the fly..."
cat "$BACKUP_DIR/data.sql" \
  | sed -E "s/[a-z0-9]{20}\.supabase\.co/$TARGET_ID\.supabase\.co/g" \
  | psql -d "$TARGET_DB_URL"

echo "------------------------------------------------------------"
echo "🪣 Restoring Storage Buckets (Syncing)..."

if [ -d "$BACKUP_DIR/storage" ]; then
  for BUCKET_PATH in "$BACKUP_DIR/storage"/*; do
    if [ -d "$BUCKET_PATH" ]; then
      BUCKET=$(basename "$BUCKET_PATH")
      echo "🔄 Syncing bucket: $BUCKET"
      rclone sync "$BUCKET_PATH" "$TARGET_RCLONE_REMOTE:$BUCKET" --config "$RCLONE_CONFIG" -P --ignore-times --no-update-modtime
      echo "✅ Finished syncing $BUCKET"
      echo ""
    fi
  done
else
  echo "⚠️ No storage/ directory found in the backup. Skipping physical file restore."
fi

echo "------------------------------------------------------------"
echo "🎉 Full restore to $ENV_TARGET completed successfully!"