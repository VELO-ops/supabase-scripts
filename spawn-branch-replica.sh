#!/bin/bash

# --- 1. Validation & Input ---
BRANCH_NAME=$1
PROD_DB_URL=$2

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

echo "🔑 Please enter your Supabase Database Password (the one used for this project):"
read -s DB_PASSWORD
echo ""

ENCODED_PASSWORD=$(jq -nr --arg pwd "$DB_PASSWORD" '$pwd | @uri')

# Extract Prod pooler to try first, but also prepare the default fallback pooler
if [[ "$PROD_DB_URL" =~ @([^:/]+) ]]; then
  PROD_POOLER="${BASH_REMATCH[1]}"
else
  PROD_POOLER="aws-0-us-west-2.pooler.supabase.com"
fi
DEFAULT_POOLER="aws-0-us-west-2.pooler.supabase.com"

# --- The Direct Polling Loop ---
echo "⏳ Testing connections..."

# 🛡️ Force PostgreSQL to output in standard English so our script can read the errors
export LANG=C

MAX_ATTEMPTS=20
ATTEMPT=0
DB_READY=false
BRANCH_DB_URL=""

while [ "$DB_READY" = false ]; do
  if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
    echo -e "\n❌ Error: Timed out waiting for database to wake up."
    exit 1
  fi
  
  # Try both poolers
  for HOST in "$PROD_POOLER" "$DEFAULT_POOLER"; do
    # Ensure we use port 6543 (Session Mode) for heavy restores
    TEST_URL="postgresql://postgres.${BRANCH_ID}:${ENCODED_PASSWORD}@${HOST}:6543/postgres"
    
    echo -e "\n[Attempt $((ATTEMPT+1))] Testing host: $HOST ..."
    
    # Increased timeout to 15s to allow for initial SSL handshakes
    PSQL_OUTPUT=$(PGCONNECT_TIMEOUT=15 psql "$TEST_URL" -c "SELECT 1;" 2>&1)
    PSQL_EXIT_CODE=$?
    
    if [ $PSQL_EXIT_CODE -eq 0 ]; then
      BRANCH_DB_URL="$TEST_URL"
      DB_READY=true
      echo "✅ Connection successful!"
      break
    elif echo "$PSQL_OUTPUT" | grep -q "password authentication failed"; then
      echo "❌ Error: Password authentication failed on host $HOST!"
      echo "💡 Fix: Double-check the password you typed matches the one reset in the dashboard."
      exit 1
    else
      echo "⚠️ Connection failed. Raw output from PostgreSQL:"
      echo "$PSQL_OUTPUT"
    fi
  done
  
  if [ "$DB_READY" = false ]; then
    echo "Waiting 5 seconds before retrying..."
    sleep 5
    ((ATTEMPT++))
  fi
done

echo -e "\n✅ Branch database is awake and accepting connections!"

# --- 5. Step 3: Capture Fresh Production State ---
echo "📸 Triggering fresh production backup via 3-argument override..."
SAFE_BRANCH_NAME="${BRANCH_NAME//\//_}"
FOLDER_PREFIX="${SAFE_BRANCH_NAME}_source"

# 🛡️ Force PROD_DB_URL to use port 6543 so pg_dump doesn't fail
PROD_DB_URL_SESSION="${PROD_DB_URL//:5432/:6543}"

# Run backup.sh using the safely rewritten URL
BACKUP_OUTPUT=$(./backup.sh "$PROD_DB_URL_SESSION" "$RCLONE_REMOTE" "$FOLDER_PREFIX")

# Extract the backup directory path from the final output line
PROD_BACKUP_DIR=$(echo "$BACKUP_OUTPUT" | grep "All files are securely saved in:" | awk '{print $NF}')

if [ -z "$PROD_BACKUP_DIR" ]; then
  echo "❌ Production backup failed. Output was:"
  echo "$BACKUP_OUTPUT"
  exit 1
fi

# --- 6. Step 4: Tricking restore.sh into Populating the Branch ---
echo "============================================================"
read -p "⚠️  Overwrite branch '$BRANCH_NAME' with a fresh prod clone? [y/N]: " CONFIRM_RESTORE
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
