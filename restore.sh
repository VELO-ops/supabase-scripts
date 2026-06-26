#!/bin/bash

# --- Save Injected Variables ---
# If a parent script (like spawn-branch-replica) passes a URL, save it before .env clobbers it
INJECTED_TEST_URL="$TEST_DB_URL"

# --- Load Environment Variables ---
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Restore Injected Variables ---
if [ -n "$INJECTED_TEST_URL" ]; then
  TEST_DB_URL="$INJECTED_TEST_URL"
fi

# --- Parse Flags ---
SCHEMA_ONLY=false
DATA_ONLY=false
SKIP_BACKUP=false
POSITIONAL_ARGS=()

for arg in "$@"; do
  if [ "$arg" == "--schema-only" ]; then
    SCHEMA_ONLY=true
  elif [ "$arg" == "--data-only" ]; then
    DATA_ONLY=true
  elif [ "$arg" == "--skip-backup" ]; then
    SKIP_BACKUP=true
  else
    POSITIONAL_ARGS+=("$arg") # Save non-flag arguments
  fi
done

# Reassign the remaining arguments
set -- "${POSITIONAL_ARGS[@]}"

# --- Input Validation ---
ENV_TARGET=$1
BACKUP_DIR=$2

if [[ "$ENV_TARGET" != "test" && "$ENV_TARGET" != "prod" ]]; then
  echo "❌ Error: First argument must be 'test' or 'prod'."
  echo "Usage: ./restore.sh <test|prod> <backup_dir> [--schema-only]"
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
  WARNING_MSG="🔥 DANGER: YOU ARE ABOUT TO WIPE AND OVERWRITE PRODUCTION! 🔥"
  CONFIRM_WORD="I UNDERSTAND"
else
  TARGET_DB_URL=$TEST_DB_URL
  WARNING_MSG="🚨 WARNING: DESTRUCTIVE RESTORE TO TEST INITIATED 🚨"
  CONFIRM_WORD="YES"
fi

# 🎯 Extract the 20-character Target Project ID from the Database URL
if [[ "$TARGET_DB_URL" =~ postgres\.([^:]+) ]]; then
  TARGET_ID="${BASH_REMATCH[1]}"
  echo "🔍 Auto-detected Target Project ID: $TARGET_ID"
  
  # 🪣 Auto-detect the correct rclone remote to prevent "split-brain" uploads
  if [ -f "$RCLONE_CONFIG" ]; then
    TARGET_RCLONE_REMOTE=$(awk -v id="$TARGET_ID" '
      /^\[.*\]$/ { remote=substr($0, 2, length($0)-2) }
      $0 ~ "endpoint.*" id { print remote; exit }
    ' "$RCLONE_CONFIG")
  fi
elif [[ "$TARGET_DB_URL" =~ 127\.0\.0\.1 ]]; then
  # Trick the script into keeping the original test URLs perfectly intact
  TARGET_ID="iahkuyfzsmihqtokfuap"
  TARGET_RCLONE_REMOTE="test-supa"
  echo "🔍 Local database detected! Bypassing ID extraction and preserving URLs."
else
  echo "❌ Error: Could not extract Project ID from the target DB URL."
  exit 1
fi

# Validate rclone remote detection (only required if we are pushing files)
if [ -n "$TARGET_RCLONE_REMOTE" ]; then
  echo "✨ Auto-detected rclone remote: [$TARGET_RCLONE_REMOTE]"
else
  if [ "$SCHEMA_ONLY" = false ]; then
    echo "⚠️ Could not auto-detect rclone remote for target ID $TARGET_ID."
    echo "Did you forget to add this project's S3 credentials to rclone.conf?"
    read -p "Enter the rclone remote name manually (or press Ctrl+C to abort): " TARGET_RCLONE_REMOTE
    
    if [ -z "$TARGET_RCLONE_REMOTE" ]; then
      echo "❌ Error: Rclone remote is required to restore storage files."
      exit 1
    fi
  fi
fi

# --- 🚨 WARNING 🚨 ---
echo "============================================================"
echo " $WARNING_MSG"
echo "============================================================"
echo "Target Environment: $ENV_TARGET"
echo "Target Database: $TARGET_DB_URL"
echo "Source Backup: $BACKUP_DIR"

if [ "$SCHEMA_ONLY" = true ]; then
  echo "Mode: 🏗️ SCHEMA ONLY (Table rows and S3 files will be skipped)"
fi

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
if [ "$SKIP_BACKUP" = false ]; then
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
else
  echo ""
  echo "⏭️  --skip-backup flag detected. Skipping safety backup phase."
  echo ""
fi

# --- 🧹 AUTOMATED WIPE TARGET 🧹 ---
echo "------------------------------------------------------------"
echo "🧹 WIPING $ENV_TARGET DATABASE..."
echo "------------------------------------------------------------"

if [ "$DATA_ONLY" = false ]; then
  psql -d "$TARGET_DB_URL" -c "
    DROP SCHEMA IF EXISTS public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO postgres;
    GRANT ALL ON SCHEMA public TO public;
    TRUNCATE auth.users CASCADE;
    TRUNCATE storage.buckets CASCADE;
  "
else
  echo "⏭️  --data-only flag detected. Truncating all data while preserving schema and permissions..."
  psql -d "$TARGET_DB_URL" -c "
    TRUNCATE auth.users CASCADE;
    TRUNCATE storage.buckets CASCADE;
    DO \$\$
    DECLARE
        stmt text;
    BEGIN
        -- Dynamically build a TRUNCATE command for all tables in the public schema
        SELECT 'TRUNCATE ' || string_agg(quote_ident(tablename), ', ') || ' CASCADE;'
        INTO stmt
        FROM pg_tables
        WHERE schemaname = 'public';
        
        IF stmt IS NOT NULL THEN
            EXECUTE stmt;
        END IF;
    END;
    \$\$;
  "
fi

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

if [ "$DATA_ONLY" = false ]; then
  echo "🔗 Patching Webhooks in Schema and Restoring on the fly..."
  cat "$BACKUP_DIR/schema.sql" \
    | sed -E "s/[a-z0-9]{20}\.supabase\.co/$TARGET_ID\.supabase\.co/g" \
    | psql -d "$TARGET_DB_URL"
else
  echo "⏭️  --data-only flag detected. Skipping Schema injection."
fi

# --- Conditional Data Injection ---
if [ "$SCHEMA_ONLY" = false ]; then
  echo "🔗 Patching URLs in Data and Restoring on the fly..."
  cat "$BACKUP_DIR/data.sql" \
    | sed -E "s/[a-z0-9]{20}\.supabase\.co/$TARGET_ID\.supabase\.co/g" \
    | psql -d "$TARGET_DB_URL"
else
  echo "⏭️  --schema-only flag detected. Skipping Data (table rows) restore."
fi

# --- Conditional S3 Restore ---
if [ "$SCHEMA_ONLY" = false ]; then
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
    echo "⚠️ No storage/ directory found in the backup. Skipping physical file restore.\n\n"
  fi
else
  echo "------------------------------------------------------------"
  echo "⏭️  --schema-only flag detected. Skipping S3 physical file sync.\n\n"
fi

# --- ⚠️ Manual Action Prompt for Schema-Only ---
if [ "$SCHEMA_ONLY" = true ]; then
  echo "------------------------------------------------------------"
  echo "⚠️  MANUAL ACTION REQUIRED: RECREATE STORAGE BUCKETS"
  echo "------------------------------------------------------------"
  echo "Because you ran a --schema-only restore, your 'storage.buckets' table"
  echo "was truncated but not repopulated with the backup data."
  echo ""
  echo "Please log into the Supabase Dashboard and manually recreate"
  echo "the following buckets to ensure your app functions correctly."
  echo ""
  echo "Target Project ID: $TARGET_ID"
  echo "URL: https://supabase.com/dashboard/project/$TARGET_ID/storage/buckets"
  echo ""
  
  if [ -d "$BACKUP_DIR/storage" ]; then
    for BUCKET_PATH in "$BACKUP_DIR/storage"/*; do
      if [ -d "$BUCKET_PATH" ]; then
        echo " [] $(basename "$BUCKET_PATH")"
      fi
    done
  else
    echo " (No buckets found in the source backup.)"
  fi
  echo "------------------------------------------------------------"
fi

echo "------------------------------------------------------------"
echo "Full restore to $ENV_TARGET completed successfully!"