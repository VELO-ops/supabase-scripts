#!/bin/bash

# --- Load Environment Variables ---
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file not found. Please copy sample.env to .env and configure it."
  exit 1
fi

# --- Parse Flags ---
SKIP_STORAGE=false
DEBUG_FLAG=""
POSITIONAL_ARGS=()

for arg in "$@"; do
  if [ "$arg" == "--db-only" ]; then
    SKIP_STORAGE=true
  elif [ "$arg" == "--debug" ]; then
    DEBUG_FLAG="--debug"
  else
    POSITIONAL_ARGS+=("$arg") # Save non-flag arguments
  fi
done

# Reassign the remaining arguments so the rest of the script functions normally
set -- "${POSITIONAL_ARGS[@]}"

# --- Configuration ---
RCLONE_CONFIG="./rclone.conf"

# 1. Automated override (Used when restore.sh calls this script with 3 exact arguments)
if [ $# -eq 3 ]; then
  DB_URL=$1
  RCLONE_REMOTE=$2
  FOLDER_PREFIX=$3

# 2. Manual execution
else
  ENV_INPUT=$1

  # Prompt if no argument was passed
  if [ -z "$ENV_INPUT" ]; then
    echo "============================================================"
    echo " 🎯 Target Selection"
    echo "============================================================"
    read -p "Enter environment ('prod'/'test') OR a full PostgreSQL URL: " ENV_INPUT
  fi

  # Route based on input
  if [ "$ENV_INPUT" == "test" ]; then
    DB_URL=$TEST_DB_URL
    RCLONE_REMOTE="test-supa"
    FOLDER_PREFIX="test_backup"
  elif [ "$ENV_INPUT" == "prod" ]; then
    DB_URL=$PROD_DB_URL
    RCLONE_REMOTE="prod-supa"
    FOLDER_PREFIX="prod_backup"
  elif [[ "$ENV_INPUT" == postgresql://* ]]; then
    DB_URL=$ENV_INPUT
    echo ""
    echo "🔗 Custom Database URL detected."

    # 1. Extract Project ID from the Postgres URL
    if [[ "$DB_URL" =~ postgres\.([^:]+) ]]; then
      PROJECT_ID="${BASH_REMATCH[1]}"
      echo "🔍 Extracted Project ID: $PROJECT_ID"
      
      # 2. Search rclone.conf for the remote that has this Project ID in its endpoint
      if [ -f "$RCLONE_CONFIG" ]; then
        AUTO_REMOTE=$(awk -v id="$PROJECT_ID" '
          /^\[.*\]$/ { remote=substr($0, 2, length($0)-2) }
          $0 ~ "endpoint.*" id { print remote; exit }
        ' "$RCLONE_CONFIG")
      fi
    fi

    # 3. Apply the detected remote or fallback to a manual prompt
    if [ -n "$AUTO_REMOTE" ]; then
      echo "✨ Auto-detected rclone remote: [$AUTO_REMOTE]"
      RCLONE_REMOTE=$AUTO_REMOTE
    else
      echo "⚠️ Could not auto-detect rclone remote. Did you add it to rclone.conf?"
      read -p "Enter the rclone remote name manually (e.g., clientA-supa): " RCLONE_REMOTE
    fi

    read -p "Enter a prefix for the backup folder (e.g., clientA_backup): " FOLDER_PREFIX
    
    if [ -z "$RCLONE_REMOTE" ] || [ -z "$FOLDER_PREFIX" ]; then
      echo "❌ Error: Rclone remote and folder prefix are required."
      exit 1
    fi
  else
    echo "❌ Error: Invalid input. Must be 'prod', 'test', or a valid postgresql:// URL."
    exit 1
  fi
fi

# --- Setup Directory ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./backups/${FOLDER_PREFIX}_${TIMESTAMP}"
STORAGE_DIR="$BACKUP_DIR/storage"

mkdir -p "$BACKUP_DIR"
if [ "$SKIP_STORAGE" = false ]; then
  mkdir -p "$STORAGE_DIR"
fi

echo "🚀 Starting Backup to $BACKUP_DIR..."
echo "------------------------------------------------------------"

# --- 1. Database Dumps ---
echo "📦 Dumping Roles..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/roles.sql" --keep-comments --role-only $DEBUG_FLAG

# The --schema-only flag forces the underlying pg_dump engine to rigorously scan the system catalog for all structural elements, including custom PL/pgSQL functions.
echo "📦 Dumping Schema..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/schema.sql" $DEBUG_FLAG

echo "📦 Dumping Data (Excluding vector indexes)..."
supabase db dump --db-url "$DB_URL" -f "$BACKUP_DIR/data.sql" --use-copy --data-only --exclude "storage.buckets_vectors,storage.vector_indexes" $DEBUG_FLAG

# --- 1.1 Migration History Dump ---
echo "📦 Dumping Migration History..."
MIGRATIONS_EXIST=$(psql -d "$DB_URL" -t -A -c "
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'supabase_migrations' 
    AND table_name = 'schema_migrations'
  );
" 2>/dev/null)

if [ "$MIGRATIONS_EXIST" == "t" ]; then
  HAS_STATEMENTS=$(psql -d "$DB_URL" -t -A -c "
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns 
      WHERE table_schema = 'supabase_migrations' 
      AND table_name = 'schema_migrations' 
      AND column_name = 'statements'
    );
  " 2>/dev/null)

  HAS_NAME=$(psql -d "$DB_URL" -t -A -c "
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns 
      WHERE table_schema = 'supabase_migrations' 
      AND table_name = 'schema_migrations' 
      AND column_name = 'name'
    );
  " 2>/dev/null)

  cat << 'EOF' > "$BACKUP_DIR/migrations.sql"
--
-- Supabase Migration History Dump
--

CREATE SCHEMA IF NOT EXISTS supabase_migrations;

ALTER SCHEMA supabase_migrations OWNER TO postgres;

CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
    version text NOT NULL PRIMARY KEY,
    statements text[],
    name text
);

ALTER TABLE supabase_migrations.schema_migrations OWNER TO postgres;

GRANT ALL ON SCHEMA supabase_migrations TO postgres;
GRANT ALL ON SCHEMA supabase_migrations TO anon;
GRANT ALL ON SCHEMA supabase_migrations TO authenticated;
GRANT ALL ON SCHEMA supabase_migrations TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA supabase_migrations TO postgres, anon, authenticated, service_role;

EOF

  if [ "$HAS_STATEMENTS" == "t" ] && [ "$HAS_NAME" == "t" ]; then
    psql -d "$DB_URL" -t -A -c "
      SELECT format(
        'INSERT INTO supabase_migrations.schema_migrations (version, name, statements) VALUES (%L, %L, %s) ON CONFLICT (version) DO NOTHING;',
        version,
        name,
        CASE 
          WHEN statements IS NULL THEN 'NULL'
          ELSE 'ARRAY[' || COALESCE((
            SELECT string_agg(quote_literal(s), ', ')
            FROM unnest(statements) AS s
          ), '') || ']::text[]'
        END
      )
      FROM supabase_migrations.schema_migrations
      ORDER BY version ASC;
    " >> "$BACKUP_DIR/migrations.sql" 2>/dev/null
  elif [ "$HAS_NAME" == "t" ]; then
    psql -d "$DB_URL" -t -A -c "
      SELECT format(
        'INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES (%L, %L) ON CONFLICT (version) DO NOTHING;',
        version,
        name
      )
      FROM supabase_migrations.schema_migrations
      ORDER BY version ASC;
    " >> "$BACKUP_DIR/migrations.sql" 2>/dev/null
  else
    psql -d "$DB_URL" -t -A -c "
      SELECT format(
        'INSERT INTO supabase_migrations.schema_migrations (version) VALUES (%L) ON CONFLICT (version) DO NOTHING;',
        version
      )
      FROM supabase_migrations.schema_migrations
      ORDER BY version ASC;
    " >> "$BACKUP_DIR/migrations.sql" 2>/dev/null
  fi

  MIGRATION_COUNT=$(grep -c "^INSERT INTO" "$BACKUP_DIR/migrations.sql" 2>/dev/null || echo 0)
  echo "✅ Dumped $MIGRATION_COUNT migration record(s) to migrations.sql"
else
  echo "⚠️ No migration history found in database (supabase_migrations.schema_migrations missing). Skipping."
fi

# --- 2. Storage Backup ---
if [ "$SKIP_STORAGE" = true ]; then
  echo "------------------------------------------------------------"
  echo "⏭️  --db-only flag detected. Skipping S3 Storage Buckets."
else
  echo "------------------------------------------------------------"
  echo "🪣 Fetching dynamic list of Storage Buckets..."

  BUCKETS=$(rclone lsf --dirs-only "$RCLONE_REMOTE:" --config "$RCLONE_CONFIG" | sed 's/\/$//')

  if [ -z "$BUCKETS" ]; then
    echo "⚠️ No buckets found or rclone could not connect."
  else
    echo "Found the following buckets:"
    echo "$BUCKETS"
    echo "------------------------------------------------------------"

    for BUCKET in $BUCKETS; do
      echo "💾 Backing up bucket: $BUCKET"
      rclone copy "$RCLONE_REMOTE:$BUCKET" "$STORAGE_DIR/$BUCKET" --config "$RCLONE_CONFIG" -P --size-only --no-update-modtime --retries 1
      echo "✅ Finished $BUCKET"
      echo ""
    done
  fi
fi

echo "------------------------------------------------------------"
echo "🎉 Backup completed successfully!"
echo "📂 All files are securely saved in: $BACKUP_DIR"