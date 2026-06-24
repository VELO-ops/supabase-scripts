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

# Query the CLI to see if a branch with this name is already in the project
EXISTING_BRANCH=$(supabase branch list --project-ref "$PROJECT_ID" --output json 2>/dev/null | jq -r ".[] | select(.name == \"$BRANCH_NAME\") | .name")

if [ "$EXISTING_BRANCH" == "$BRANCH_NAME" ]; then
  echo "♻️  Branch '$BRANCH_NAME' already exists! Skipping creation and reusing..."
else
  echo "🏗️  Creating isolated Supabase branch on project $PROJECT_ID..."
  supabase branch create "$BRANCH_NAME" --project-ref "$PROJECT_ID"

  if [ $? -ne 0 ]; then
    echo "❌ Failed to create cloud branch. Aborting."
    exit 1
  fi
fi

# --- 4. Step 2: Grab the New Branch's Connection Details ---
echo "⏳ Waiting for the database branch to finish provisioning (this usually takes 1-3 minutes)..."

BRANCH_DB_URL="null"
MAX_ATTEMPTS=60  # 60 attempts * 5 seconds = 5 minutes max timeout
ATTEMPT=0

while [ "$BRANCH_DB_URL" == "null" ] || [ -z "$BRANCH_DB_URL" ]; do
  if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
    echo -e "\n❌ Error: Timed out waiting for branch to finish creating."
    exit 1
  fi
  
  # Print a dot to show progress
  echo -n "."
  sleep 5
  
  # Suppress standard error just in case the CLI throws a transient warning while booting
  BRANCH_DB_URL=$(supabase branch list --project-ref "$PROJECT_ID" --output json 2>/dev/null | jq -r ".[] | select(.name == \"$BRANCH_NAME\") | .connectionString")
  
  ((ATTEMPT++))
done

echo -e "\n✅ Branch provisioned! Connection string retrieved."

# --- 5. Step 3: Capture Fresh Production State ---
echo "📸 Triggering fresh production backup via 3-argument override..."
# We format the folder prefix to replace slashes in the branch name with underscores
SAFE_BRANCH_NAME="${BRANCH_NAME//\//_}"
FOLDER_PREFIX="${SAFE_BRANCH_NAME}_source"

# Run backup.sh using the 3-argument automated override to prevent prompts
BACKUP_OUTPUT=$(./backup.sh "$PROD_DB_URL" "$RCLONE_REMOTE" "$FOLDER_PREFIX")

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
echo "YES" | ./restore.sh test "$PROD_BACKUP_DIR" --skip-backup

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
