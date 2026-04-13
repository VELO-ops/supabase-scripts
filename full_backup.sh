#!/bin/bash

# --- Load Environment Variables ---
if [ -f .env ]; then
  # Read .env file, ignoring comments, and export variables
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Configuration ---
RCLONE_REMOTE="prod-supa"
RCLONE_CONFIG="./rclone.conf"

# --- Setup Directory ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./supabase_backup_$TIMESTAMP"
STORAGE_DIR="$BACKUP_DIR/storage"

mkdir -p "$STORAGE_DIR"

echo "🚀 Starting Full Supabase Backup to $BACKUP_DIR..."
echo "------------------------------------------------------------"

# --- 1. Database Dumps ---
echo "📦 Dumping Roles..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/roles.sql" --keep-comments --role-only

echo "📦 Dumping Schema..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/schema.sql"

echo "📦 Dumping Data (Excluding vector indexes)..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/data.sql" --use-copy --data-only -T "storage.buckets_vectors" -T "storage.vector_indexes"

echo "------------------------------------------------------------"
echo "🪣 Fetching dynamic list of Storage Buckets..."

# --- 2. Dynamically Fetch Buckets ---
BUCKETS=$(rclone lsf --dirs-only "$RCLONE_REMOTE:" --config "$RCLONE_CONFIG" | sed 's/\/$//')

if [ -z "$BUCKETS" ]; then
  echo "⚠️ No buckets found or rclone could not connect."
else
  echo "Found the following buckets:"
  echo "$BUCKETS"
  echo "------------------------------------------------------------"

  # --- 3. Loop and Backup ---
  for BUCKET in $BUCKETS; do
    echo "💾 Backing up bucket: $BUCKET"
    rclone copy "$RCLONE_REMOTE:$BUCKET" "$STORAGE_DIR/$BUCKET" --config "$RCLONE_CONFIG" -P
    echo "✅ Finished $BUCKET"
    echo ""
  done
fi

echo "------------------------------------------------------------"
echo "🎉 Full backup completed successfully!"
echo "📂 All files are securely saved in: $BACKUP_DIR"