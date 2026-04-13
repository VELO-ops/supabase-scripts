#!/bin/bash

# --- Load Environment Variables ---
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Configuration ---
TARGET_RCLONE_REMOTE="test-supa"
RCLONE_CONFIG="./rclone.conf"
BACKUP_DIR=$1

# --- Input Validation ---
if [ -z "$BACKUP_DIR" ]; then
  echo "❌ Error: You must specify a source backup directory to restore from."
  echo "Usage: ./full_restore.sh ./supabase_backup_20260412_183000"
  exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "❌ Error: Directory '$BACKUP_DIR' does not exist."
  exit 1
fi

# --- 🚨 NUCLEAR WARNING 🚨 ---
echo "============================================================"
echo " 🚨 WARNING: DESTRUCTIVE RESTORE INITIATED 🚨"
echo "============================================================"
echo "Target Database: $TARGET_DB_URL"
echo "Source Backup: $BACKUP_DIR"
echo ""
echo "This will OVERWRITE the target database and DELETE any physical"
echo "storage files in the target that are not in the source backup."
echo "============================================================"
read -p "Are you absolutely sure you want to proceed? (Type 'YES' to continue): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
  echo "Restore aborted. Your target environment has not been touched."
  exit 0
fi

# --- 🛡️ SAFETY BACKUP PHASE 🛡️ ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_BACKUP_DIR="./target_pre_restore_backup_$TIMESTAMP"
SAFE_STORAGE_DIR="$SAFE_BACKUP_DIR/storage"

echo ""
echo "------------------------------------------------------------"
echo "🛡️  CREATING SAFETY BACKUP OF TARGET ENVIRONMENT..."
echo "📂 Saving to: $SAFE_BACKUP_DIR"
echo "------------------------------------------------------------"
mkdir -p "$SAFE_STORAGE_DIR"

echo "📦 Dumping Target Roles..."
supabase db dump --db-url "$TARGET_DB_URL" -f "$SAFE_BACKUP_DIR/roles.sql" --keep-comments --role-only

echo "📦 Dumping Target Schema..."
supabase db dump --db-url "$TARGET_DB_URL" -f "$SAFE_BACKUP_DIR/schema.sql"

echo "📦 Dumping Target Data (Excluding vector indexes)..."
supabase db dump --db-url "$TARGET_DB_URL" -f "$SAFE_BACKUP_DIR/data.sql" --use-copy --data-only -T "storage.buckets_vectors" -T "storage.vector_indexes"

echo "🪣 Fetching dynamic list of Target Storage Buckets..."
TARGET_BUCKETS=$(rclone lsf --dirs-only "$TARGET_RCLONE_REMOTE:" --config "$RCLONE_CONFIG" | sed 's/\/$//')

if [ -n "$TARGET_BUCKETS" ]; then
  for BUCKET in $TARGET_BUCKETS; do
    echo "💾 Safely copying target bucket: $BUCKET"
    rclone copy "$TARGET_RCLONE_REMOTE:$BUCKET" "$SAFE_STORAGE_DIR/$BUCKET" --config "$RCLONE_CONFIG" -P
  done
else
  echo "⚠️ No buckets found in the target to back up."
fi

echo "✅ Safety backup complete!"
echo ""

# --- ⏸️ MANUAL WIPE PAUSE ⏸️ ---
echo "⏳ Before proceeding with the injection, ensure you have run your DB Wipe"
echo "   commands on the target to clear out the old schema and rows."
read -p "Press [Enter] when the target DB is completely clean and ready..."

# --- 💥 RESTORE PHASE 💥 ---
echo "------------------------------------------------------------"
echo "🚀 BEGINNING FULL RESTORE FROM $BACKUP_DIR..."
echo "------------------------------------------------------------"

echo "📦 Restoring Roles..."
psql -d "$TARGET_DB_URL" -f "$BACKUP_DIR/roles.sql"

echo "📦 Restoring Schema..."
psql -d "$TARGET_DB_URL" -f "$BACKUP_DIR/schema.sql"

echo "📦 Restoring Data..."
psql -d "$TARGET_DB_URL" -f "$BACKUP_DIR/data.sql"

echo "------------------------------------------------------------"
echo "🪣 Restoring Storage Buckets (Syncing)..."

if [ -d "$BACKUP_DIR/storage" ]; then
  for BUCKET_PATH in "$BACKUP_DIR/storage"/*; do
    if [ -d "$BUCKET_PATH" ]; then
      BUCKET=$(basename "$BUCKET_PATH")
      echo "🔄 Syncing bucket: $BUCKET"
      rclone sync "$BUCKET_PATH" "$TARGET_RCLONE_REMOTE:$BUCKET" --config "$RCLONE_CONFIG" -P
      echo "✅ Finished syncing $BUCKET"
      echo ""
    fi
  done
else
  echo "⚠️ No storage/ directory found in the backup. Skipping physical file restore."
fi

echo "------------------------------------------------------------"
echo "🎉 Full restore completed successfully!"