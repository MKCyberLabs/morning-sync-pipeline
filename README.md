# Morning Sync Automation

This directory contains the production-grade automation scripts for the daily Git sync, conflict resolution, and self-healing Docker deployment workflow.

## Files

- `morning_sync.sh`: The master execution script.
- `morning_sync.env`: The environment variables (Telegram API Keys).
- `morning_sync.logrotate`: The log rotation configuration.

## How it works

The script iterates through all projects defined in the `PROJECTS` array inside `morning_sync.sh`. For each project:

1. **Safety First (Intelligent Stash)**: It uses `git status --porcelain` to check for dirty working trees and only executes a stash if active changes are present, preventing "ghost pops" of ancient stashes later in the pipeline.
2. **Fetch and Clean**: It runs `git fetch --prune --all` to fetch all branches and strictly remove any local references to branches that were deleted from the remote repository.
3. **Smart Branch Merging**: It efficiently cycles through remote branches and uses `git rev-list --count main.."origin/$BRANCH"` to skip branches with no new commits, preventing unnecessary disk I/O.
4. **Direct Merges**: New commits are merged directly from the tracking branches (`origin/$BRANCH`) into the `main` branch.
5. **AI Conflict Resolution**: If a merge conflict occurs, the pipeline pauses and hands the conflict over to `agy` (an AI agent), which resolves it directly in the working tree and commits it. If `agy` takes longer than 10 minutes, the process times out safely.
6. **Graceful Degradation**: If a conflict is entirely unresolvable, the script sets `PROJECT_FAILED=1`. It adheres to DRY principles by safely checking out the `main` branch, updating it, and popping the stash *before* isolating the failure and skipping the build. It then immediately continues to the next project.
7. **Build & Self-Healing CI**: The Docker build commands are executed. If the build fails, a fully autonomous self-healing loop triggers:
   - The `stderr/stdout` error logs are passed to `agy`, which returns a JSON payload containing a bash command to fix the issue.
   - **Hardened Security**: The AI is strictly bounded by critical rules forbidding destructive operations (e.g., `rm -rf /`), firewall modifications, or unnecessary host-level installations, keeping it focused securely on Docker configuration and safe file patching.
   - **Fail-Safe Parsing**: The AI's JSON output is parsed securely via Python. If the AI hallucinates markdown or invalid JSON, the script cleanly catches the exception and aborts the retry cycle rather than running garbage commands.
   - The script executes the suggested fix and retries the build up to **5 times**.
8. **Reporting**: The script manages communication with you via Telegram, bookending the execution with start and end reports.

## Telegram Notifications

To keep you informed without requiring you to manually check server logs, the script utilizes Telegram for live reporting:
- **Startup Alert**: At the exact moment the cronjob triggers the script, it fires a "🚀 *Morning Sync Pipeline Started*" notification to your device.
- **Completion Report**: Upon finishing all builds, it delivers a comprehensive final payload detailing the total branches merged per project, and explicitly marking each build status (Clean Success, AI-Intervention Success, or Failure).

*Note: You can easily broadcast these alerts to your entire team! Simply add multiple comma-separated chat IDs to the `TELEGRAM_CHAT_ID` variable in your `.env` file (e.g., `TELEGRAM_CHAT_ID="1234567,9876543"`).*

## Observability

All operations (including `stdout` and `stderr` from git, docker, and bash) are recorded in `/var/log/morning_sync.log`.

To prevent disk bloat, a logrotate configuration has been established. 

### Server Migration Instructions

If you migrate this setup to a new server:

1. Copy this entire folder to the new server (e.g. `/opt/automation-scripts/morning-sync`).
2. Make the script executable: `chmod +x morning_sync.sh`
3. Copy the log rotation config into the system directory:
   ```bash
   sudo cp morning_sync.logrotate /etc/logrotate.d/morning_sync
   ```
4. Set up your cronjob to execute the script daily (e.g., at 6:00 AM server time) by adding this exact line to your root crontab (`crontab -e`):
   ```bash
   0 6 * * * /opt/automation-scripts/morning-sync/morning_sync.sh
   ```
