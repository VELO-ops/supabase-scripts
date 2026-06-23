#!/bin/bash

# --- 1. Validation & Input ---
BRANCH_NAME=$1
PROD_DB_URL=$2

if [ -z "$BRANCH_NAME" ] || [ -z "$PROD_DB_URL" ]; then
  echo "❌ Error: Missing arguments."
  echo "Usage: ./spawn-branch-replica.sh <branch-name> <prod-db-url>"
  exit 1
fi

echo "============================================================"
echo " 🌀 Creating Live Replica on Branch: $BRANCH_NAME"
echo "============================================================"

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

# --- 3. Step 1: Create the Supabase Cloud Branch ---
echo "🏗️  Creating isolated Supabase branch on project $PROJECT_ID..."
supabase branch create "$BRANCH_NAME" --project-ref "$PROJECT_ID"

if [ $? -ne 0 ]; then
  echo "❌ Failed to create cloud branch. Aborting."
  exit 1
fi

# --- 4. Step 2: Grab the New Branch's Connection Details ---
echo "🔍 Fetching credentials for the new branch..."
BRANCH_DB_URL=$(supabase branch list --project-ref "$PROJECT_ID" --output json | jq -r ".[] | select(.name == \"$BRANCH_NAME\") | .connectionString")

if [ -z "$BRANCH_DB_URL" ] || [ "$BRANCH_DB_URL" == "null" ]; then
  echo "❌ Error: Could not retrieve connection string for branch '$BRANCH_NAME'."
  exit 1
fi

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
echo "🚀 Hydrating branch database and storage buckets..."

export TEST_DB_URL="$BRANCH_DB_URL"

echo "YES" | ./restore.sh test "$PROD_BACKUP_DIR"

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