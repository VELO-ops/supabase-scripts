#!/bin/bash

# --- Load Environment Variables ---
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Configuration (Allows overrides from full_restore.sh) ---
DB_URL=${1:-$PROD_DB_URL}
RCLONE_REMOTE=${2:-"prod-supa"}
FOLDER_PREFIX=${3:-"supabase_backup"}
RCLONE_CONFIG="./rclone.conf"

# --- Setup Directory ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./backups/${FOLDER_PREFIX}_${TIMESTAMP}"
STORAGE_DIR="$BACKUP_DIR/storage"

# Note: mkdir -p is smart enough to automatically create the master backups/ folder if it doesn't exist yet!
mkdir -p "$STORAGE_DIR"

echo "🚀 Starting Backup to $BACKUP_DIR..."
echo "------------------------------------------------------------"

# --- 1. Database Dumps ---
echo "📦 Dumping Roles..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/roles.sql" --keep-comments --role-only

echo "📦 Dumping Schema..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/schema.sql"

echo "📦 Dumping Data (Excluding vector indexes)..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/data.sql" --use-copy --data-only --exclude "storage.buckets_vectors,storage.vector_indexes"

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
echo "🎉 Backup completed successfully!"
echo "📂 All files are securely saved in: $BACKUP_DIR"