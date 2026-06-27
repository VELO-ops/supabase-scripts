#!/bin/bash

# --- 1. Validation & Input ---
BRANCH_NAME=$1
PROD_DB_URL=$2
PROVIDED_BACKUP=$3

if [ -z "$BRANCH_NAME" ] || [ -z "$PROD_DB_URL" ]; then
  echo "❌ Error: Missing arguments."
  echo "Usage: ./spawn-branch-replica.sh <branch-name> <prod-db-url>"
  exit 1
fi

# 🚨 Guardrail: Prevent targeting main
if [ "$BRANCH_NAME" == "main" ]; then
  echo "❌ CRITICAL ERROR: You cannot target the 'main' branch with this script."
  echo "This script is exclusively for ephemeral testing branches."
  exit 1
fi

# --- 2. Extract Project ID and Rclone Remote ---
if [[ "$PROD_DB_URL" =~ postgres\.([^:]+) ]]; then
  PROJECT_ID="${BASH_REMATCH[1]}"
  echo "🔍 Extracted Prod Project ID: $PROJECT_ID"
else
  echo "❌ Error: Could not extract Project ID from the provided DB URL."
  exit 1
fi

RCLONE_CONFIG="./rclone.conf"
if [ -f "$RCLONE_CONFIG" ]; then
  RCLONE_REMOTE=$(awk -v id="$PROJECT_ID" '
    /^\[.*\]$/ { remote=substr($0, 2, length($0)-2) }
    $0 ~ "endpoint.*" id { print remote; exit }
  ' "$RCLONE_CONFIG")
fi

if [ -z "$RCLONE_REMOTE" ]; then
  echo "❌ Error: Could not auto-detect the rclone remote for Project ID $PROJECT_ID."
  echo "Make sure it is added to your rclone.conf file."
  exit 1
fi

# --- 3. Step 1: Check or Create the Supabase Cloud Branch ---
echo "🔍 Checking if branch '$BRANCH_NAME' already exists..."

# Fetch raw output and use sed to strip any CLI update warnings, isolating the JSON array
RAW_CLI_OUTPUT=$(supabase branches list --project-ref "$PROJECT_ID" --output json 2>/dev/null)
CLEAN_JSON=$(echo "$RAW_CLI_OUTPUT" | sed -n '/^\[/,/^\]/p')

EXISTING_BRANCH=$(echo "$CLEAN_JSON" | jq -r ".[] | select(.name == \"$BRANCH_NAME\") | .name" 2>/dev/null)

if [ "$EXISTING_BRANCH" == "$BRANCH_NAME" ]; then
  echo "♻️  Branch '$BRANCH_NAME' already exists! Skipping creation and reusing..."
else
  echo "🏗️  Creating isolated Supabase branch on project $PROJECT_ID..."
  supabase branches create "$BRANCH_NAME" --project-ref "$PROJECT_ID"

  if [ $? -ne 0 ]; then
    echo "❌ Failed to create cloud branch. Aborting."
    exit 1
  fi
fi

# --- 4. Step 2: Grab the New Branch's Connection Details ---
echo "🔍 Fetching credentials for the new branch..."

RAW_CLI_OUTPUT=$(supabase branches list --project-ref "$PROJECT_ID" --output json 2>/dev/null)
CLEAN_JSON=$(echo "$RAW_CLI_OUTPUT" | sed -n '/^\[/,/^\]/p')

BRANCH_ID=$(echo "$CLEAN_JSON" | jq -r ".[] | select(.name == \"$BRANCH_NAME\") | .project_ref" 2>/dev/null)

if [ -z "$BRANCH_ID" ] || [ "$BRANCH_ID" == "null" ]; then
  echo "❌ Error: Could not find branch '$BRANCH_NAME' in project '$PROJECT_ID'."
  exit 1
fi

# --- The Password & Polling Loop ---
DB_READY=false
BRANCH_DB_URL=""

while [ "$DB_READY" = false ]; do
  echo "🔑 Please enter your Supabase Database Password (the one used for this project):"
  read -s DB_PASSWORD
  echo ""

  # Safely URL-encode the password just in case it has special characters
  ENCODED_PASSWORD=$(jq -nr --arg pwd "$DB_PASSWORD" '$pwd | @uri')

  # Extract Prod pooler to try first, but also prepare the default fallback pooler
  if [[ "$PROD_DB_URL" =~ @([^:/]+) ]]; then
    PROD_POOLER="${BASH_REMATCH[1]}"
  else
    PROD_POOLER="aws-0-us-west-2.pooler.supabase.com"
  fi
  DEFAULT_POOLER="aws-0-us-west-2.pooler.supabase.com"

  echo "⏳ Testing connections..."
  export LANG=C # 🛡️ Force standard English errors

  MAX_ATTEMPTS=20
  ATTEMPT=0
  PASSWORD_FAILED=false

  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    for HOST in "$PROD_POOLER" "$DEFAULT_POOLER"; do
      TEST_URL="postgresql://postgres.${BRANCH_ID}:${ENCODED_PASSWORD}@${HOST}:6543/postgres"
      echo -e "\n[Attempt $((ATTEMPT+1))] Testing host: $HOST ..."
      
      PSQL_OUTPUT=$(PGCONNECT_TIMEOUT=15 psql "$TEST_URL" -c "SELECT 1;" 2>&1)
      PSQL_EXIT_CODE=$?
      
      if [ $PSQL_EXIT_CODE -eq 0 ]; then
        BRANCH_DB_URL="$TEST_URL"
        DB_READY=true
        echo "✅ Connection successful!"
        break 2 # Breaks out of both the HOST loop and the ATTEMPT loop
      elif echo "$PSQL_OUTPUT" | grep -q "password authentication failed"; then
        echo "❌ Error: Password authentication failed!"
        PASSWORD_FAILED=true
        break 2 # Breaks out to ask for the password again
      else
        echo "⚠️ Connection failed (Database might still be waking up). Raw output:"
        echo "$PSQL_OUTPUT"
      fi
    done
    
    # If the password didn't fail, wait and try polling again
    if [ "$DB_READY" = false ] && [ "$PASSWORD_FAILED" = false ]; then
      echo "Waiting 5 seconds before retrying..."
      sleep 5
      ((ATTEMPT++))
    fi
  done

  if [ "$PASSWORD_FAILED" = true ]; then
    echo "💡 Let's try typing the password again. (Press Ctrl+C to abort)"
    echo ""
    continue # Restarts the outermost loop to ask for the password
  elif [ "$DB_READY" = false ]; then
    echo -e "\n❌ Error: Timed out waiting for database to wake up."
    exit 1
  fi
done

echo -e "\n✅ Branch database is awake and accepting connections!"

# --- 5. Step 3: Capture Fresh Production State ---
echo "📸 Triggering fresh production backup via 3-argument override..."
SAFE_BRANCH_NAME="${BRANCH_NAME//\//_}"
FOLDER_PREFIX="${SAFE_BRANCH_NAME}_source"

# 🛡️ Force PROD_DB_URL to use port 6543 so pg_dump doesn't fail
PROD_DB_URL_SESSION="${PROD_DB_URL//:5432/:6543}"

# Run backup.sh with the passed backup folder, if one was provided
if [ -n "$PROVIDED_BACKUP" ]; then
  if [ -d "$PROVIDED_BACKUP" ]; then
    echo "♻️  Optional backup path provided! Skipping fresh production dump."
    echo "📂 Using existing backup: $PROVIDED_BACKUP"
    BACKUP_DIR="$PROVIDED_BACKUP"
  else
    echo "❌ Error: The provided backup path '$PROVIDED_BACKUP' does not exist."
    exit 1
  fi
else
  echo "📸 Triggering fresh production backup via 3-argument override..."
  ./backup.sh "$PROD_DB_URL" "prod-supa" "${BRANCH_NAME}_source"
  
  # Assuming your script automatically finds the newest folder created by backup.sh
  # KEEP YOUR EXISTING BACKUP FOLDER DETECTION LOGIC HERE
  BACKUP_DIR=$(ls -td backups/${BRANCH_NAME}_source_* | head -1)
fi

# Extract the backup directory path from the final output line
PROD_BACKUP_DIR=$(echo "$BACKUP_OUTPUT" | grep "All files are securely saved in:" | awk '{print $NF}')

if [ -z "$PROD_BACKUP_DIR" ]; then
  echo "❌ Production backup failed. Output was:"
  echo "$BACKUP_OUTPUT"
  exit 1
fi

# --- 6. Step 4: Tricking restore.sh into Populating the Branch ---
echo "============================================================"
echo "⚠️  WARNING: You are about to run a destructive restore."
echo "Target Branch: $BRANCH_NAME"
echo "Target URL:    $BRANCH_DB_URL"
echo "============================================================"
read -p "Overwrite this specific database with a fresh prod clone? [y/N]: " CONFIRM_RESTORE
echo "============================================================"

if [[ ! "$CONFIRM_RESTORE" =~ ^[Yy]$ ]]; then
  echo "🛑 Restore aborted by user. The branch '$BRANCH_NAME' was not modified."
  exit 0
fi

echo "🚀 Hydrating branch database and storage buckets..."

export TEST_DB_URL="$BRANCH_DB_URL"

# We pass --skip-backup because this is a disposable branch!
# We pass --data-only because Supabase Branching already built the schema perfectly!
echo "YES" | ./restore.sh test "$PROD_BACKUP_DIR" --skip-backup --data-only

if [ $? -eq 0 ]; then
  echo "============================================================"
  echo " 🎉 SUCCESS! Your replica environment is ready for testing."
  echo "============================================================"
  echo "Branch Name:       $BRANCH_NAME"
  echo "Connection String: $BRANCH_DB_URL"
  echo "============================================================"
else
  echo "❌ Restore phase failed."
  exit 1
fi
