#!/bin/bash
# /opt/morning_sync.sh
# Master script for daily morning git workflow and project builds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/morning_sync.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Error: $ENV_FILE not found. Please create it with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
    exit 1
fi

LOG_FILE="/var/log/morning_sync.log"
echo "=== Morning Sync Started at $(date) ===" >> "$LOG_FILE"

# Helper function to send Telegram messages to multiple IDs
send_telegram_message() {
    local message="$1"
    IFS=',' read -ra CHAT_IDS <<< "$TELEGRAM_CHAT_ID"
    for id in "${CHAT_IDS[@]}"; do
        # Trim whitespace
        id=$(echo "$id" | xargs)
        if [ -n "$id" ]; then
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$id" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null
        fi
    done
}

# Send start notification
START_MSG="🚀 *Morning Sync Pipeline Started*"
send_telegram_message "$START_MSG"

if ! docker info >> "$LOG_FILE" 2>&1; then
    SUMMARY="🚨 Docker daemon is not running! Aborting builds.%0A"
    send_telegram_message "$SUMMARY"
    exit 1
fi

# Define projects: "DirectoryPath|BuildCommand"
PROJECTS=(
  "/opt/docker/containers/vision-health-app|docker compose build && docker compose up -d"
  "/opt/docker/containers/hugo-site/prod|docker compose build && docker compose up -d"
  "/opt/docker/containers/nutrisnap/NutriSnap|docker compose build && docker compose up -d"
)

# Output log
SUMMARY="*Morning Sync Report* %0A"
date_str=$(date)
SUMMARY+="Date: ${date_str} %0A%0A"

for item in "${PROJECTS[@]}"; do
    PROJECT_DIR="${item%%|*}"
    BUILD_CMD="${item#*|}"
    PROJECT_NAME=$(basename "$PROJECT_DIR")
    
    if [ "$PROJECT_NAME" = "prod" ]; then
        PROJECT_NAME=$(basename "$(dirname "$PROJECT_DIR")")
    fi

    SUMMARY+="*Project:* ${PROJECT_NAME}%0A"

    if [ ! -d "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR/.git" ]; then
        SUMMARY+="⚠️ Skipping (Not a git repo or directory missing)%0A%0A"
        continue
    fi

    echo "Processing $PROJECT_NAME in $PROJECT_DIR..."
    cd "$PROJECT_DIR" || continue

    # 1. Check for changes and stash if necessary
    NEEDS_STASH=0
    if [ -n "$(git status --porcelain)" ]; then
        NEEDS_STASH=1
        git stash push -m "morning-backup" >> "$LOG_FILE" 2>&1
    fi
    
    # 2. Fetch and prune dead branches
    git fetch --prune --all >> "$LOG_FILE" 2>&1

    # Make sure main is checked out and fully up to date before the loop
    git checkout main >> "$LOG_FILE" 2>&1
    git pull origin main >> "$LOG_FILE" 2>&1

    # Get remote branches excluding main
    BRANCHES=$(git branch -r | grep -v 'origin/main' | sed 's/  origin\///' | grep -v HEAD)
    
    PROJECT_FAILED=0
    SUCCESS_COUNT=0

    while read -r BRANCH; do
        [ -z "$BRANCH" ] && continue
        # Count how many commits this remote branch has that local main does NOT have
        COMMITS_AHEAD=$(git rev-list --count main.."origin/$BRANCH")

        if [ "$COMMITS_AHEAD" -eq 0 ]; then
            echo "  Skipping $BRANCH (No new commits)" >> "$LOG_FILE"
            continue
        fi

        echo "  New commits found in $BRANCH. Attempting to merge..."
        
        # Attempt merge directly from the remote-tracking branch (much faster)
        git merge "origin/$BRANCH" --no-edit >> "$LOG_FILE" 2>&1
        MERGE_STATUS=$?

        if [ $MERGE_STATUS -ne 0 ]; then
            echo "    Merge conflict in $BRANCH. Triggering AGY..."
            
            # Use AGY to resolve
            PROMPT="There is a git merge conflict in $PROJECT_DIR when merging origin/$BRANCH into main. Please resolve the conflict, commit the resolution, and push to main. Return a JSON response like { \"status\": \"success\" } or { \"status\": \"error\", \"reason\": \"error message\" }"
            
            # Run AGY
            AGY_OUT=$(timeout 10m agy --print "$PROMPT" --dangerously-skip-permissions)
            
            # Check if still in conflict
            CONFLICTS=$(git diff --name-only --diff-filter=U)
            if [ -n "$CONFLICTS" ]; then
                # AGY failed to resolve
                git merge --abort >> "$LOG_FILE" 2>&1
                SUMMARY+="❌ Merge failed for ${BRANCH}: AGY could not resolve conflicts.%0A"
                PROJECT_FAILED=1
                break
            else
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                git push origin main >> "$LOG_FILE" 2>&1
            fi
        else
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            git push origin main >> "$LOG_FILE" 2>&1
        fi
    done <<< "$BRANCHES"
    
    if [ $SUCCESS_COUNT -gt 0 ]; then
        SUMMARY+="✅ Merged $SUCCESS_COUNT branches successfully.%0A"
    fi
    
    # Always ensure we are on main and up to date
    git checkout main >> "$LOG_FILE" 2>&1
    git pull origin main >> "$LOG_FILE" 2>&1
    
    # Only pop if we actually stashed something earlier
    if [ $NEEDS_STASH -eq 1 ]; then
        git stash pop >> "$LOG_FILE" 2>&1
    fi

    if [ $PROJECT_FAILED -eq 1 ]; then
        SUMMARY+="⚠️ Skipping build for $PROJECT_NAME due to unresolved conflicts.%0A%0A"
        continue
    fi

    # 3. Build project
    echo "  Building $PROJECT_NAME..."
    
    MAX_RETRIES=5
    RETRY_COUNT=0
    BUILD_SUCCESS=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        BUILD_LOG="/tmp/build_${PROJECT_NAME}.log"
        bash -c "$BUILD_CMD" > "$BUILD_LOG" 2>&1
        BUILD_STATUS=$?
        
        cat "$BUILD_LOG" >> "$LOG_FILE"
        
        if [ $BUILD_STATUS -eq 0 ]; then
            BUILD_SUCCESS=1
            break
        fi
        
        echo "  Build failed (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES). Asking AGY for a fix..." >> "$LOG_FILE"
        
        ERROR_LOG=$(tail -n 100 "$BUILD_LOG")
        PROMPT="The build command '$BUILD_CMD' failed in $PROJECT_DIR. Here is the tail of the error log:\n\n$ERROR_LOG\n\nYou are an automated recovery agent. Please provide a safe bash command to fix this issue. \nCRITICAL RULES:\n1. The project uses Docker. Do NOT suggest host-level package installations (like apt-get or npm) unless fixing a host docker issue.\n2. Do NOT suggest firewall, network, or destructive commands (like rm -rf /).\n3. If the fix requires modifying a file instead of running a command, use 'sed' or 'echo' safely.\nReturn ONLY a valid JSON object like { \"command\": \"<bash_command>\" }. Do not include markdown formatting."
        
        AGY_RESPONSE=$(timeout 10m agy --print "$PROMPT" --dangerously-skip-permissions)
        
        SUGGESTED_CMD=$(echo "$AGY_RESPONSE" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("command", ""))' 2>/dev/null)
        
        if [ -n "$SUGGESTED_CMD" ]; then
            echo "  AGY suggested command: $SUGGESTED_CMD" >> "$LOG_FILE"
            echo "  Executing suggested command..." >> "$LOG_FILE"
            bash -c "$SUGGESTED_CMD" >> "$LOG_FILE" 2>&1
        else
            echo "  AGY did not return a valid command. Aborting retries." >> "$LOG_FILE"
            break
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
    if [ $BUILD_SUCCESS -eq 1 ]; then
        if [ $RETRY_COUNT -eq 0 ]; then
            SUMMARY+="🏗️ Build SUCCESS.%0A%0A"
        else
            SUMMARY+="🏗️ Build SUCCESS (after $RETRY_COUNT AI interventions).%0A%0A"
        fi
    else
        SUMMARY+="🚨 Build FAILED after $RETRY_COUNT AI attempts.%0A%0A"
    fi
done

# Send Telegram Message
send_telegram_message "$SUMMARY"

echo "Sync complete."
