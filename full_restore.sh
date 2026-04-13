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
echo ""
echo "------------------------------------------------------------"
echo "🛡️  CREATING SAFETY BACKUP OF TARGET ENVIRONMENT..."
echo "------------------------------------------------------------"

# We call the backup script directly, passing the Target URL, Target Remote, and a custom folder prefix!
./full_backup.sh "$TARGET_DB_URL" "$TARGET_RCLONE_REMOTE" "target_pre_restore_backup"

if [ $? -ne 0 ]; then
  echo "❌ Safety backup failed. Aborting restore to protect your target environment."
  exit 1
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