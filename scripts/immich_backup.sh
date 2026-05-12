#!/bin/bash
set -e
set -o pipefail

## TODO
# rotate logs

# Settings
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
DATE=$(date +"%Y-%m-%d_%H-%M")
LOG_FILE="$LOG_DIR/backup_$DATE.log"

mkdir -p "$LOG_DIR"

# we want outout in files and in std
exec > >(tee -a "$LOG_FILE") 2>&1

# --- vars ---
IMMICH_DIR="$HOME/immich"
DATA_DIR="/mnt/my_ssd"
DEST_HDD_DIR="/mnt/my_hdd/backup/immich"

export RESTIC_REPOSITORY="rclone:onedrive:ImmichBackups"
export RESTIC_PASSWORD_FILE="$HOME/.restic_pwd"

NTFY_URL="https://ntfy.sh/my-unique-url-that-only-i-know"

# will be usefull for push notification
RESTIC_STATS=""

# trap - we want this to run always
cleanup_and_recover() {
    local EXIT_CODE=$?
    echo "=== Finished (Exit code: $EXIT_CODE) ==="

    cd "$IMMICH_DIR" && docker compose up -d

    if [ $EXIT_CODE -ne 0 ]; then
        curl -s \
	     -H "Title: Immich backup failed" \
             -H "Priority: high" \
             -H "Tags: warning" \
             -d "Error code: $EXIT_CODE. Logs: $LOG_FILE" \
             "$NTFY_URL"
    else
        if [ -n "$RESTIC_STATS" ]; then
            curl -s \
                 -H "Title: Immich backup success" \
                 -d "$RESTIC_STATS" \
                 "$NTFY_URL"
        else
            curl -s \
                 -H "Title: Immich backup successed" \
                 -d "Missing stats..." \
                 "$NTFY_URL"
        fi
    fi
}

trap cleanup_and_recover EXIT


echo "=== Start backupu: $DATE ==="
# for first backup you may want to uncomment this to have start point since first backup could potentialy take some time (depending on your library size)
#curl -H "Title: Backup Immich" -d "Backup begin" "$NTFY_URL" 

# stop service to keep DB and files in sync
cd "$IMMICH_DIR"
docker compose stop

# at first backup it could take sometime, but later downtime is negligible 
echo "Backup SSD (source) -> HDD"
rsync -ah --delete --exclude=lost+found/ "$DATA_DIR/" "$DEST_HDD_DIR/immich_data/" --progress # copy new and delete deleted files (it contains thumbnails, originalfiles, profile, encoded videos, db dumps)
rsync -ah "$IMMICH_DIR/docker-compose.yml" "$IMMICH_DIR/.env" "$DEST_HDD_DIR/configs/" --progress # copy settings

# we can start now
docker compose up -d

echo "HDD -> Onedrive"
# temp file for restic sync stat
RESTIC_TMP_LOG="$LOG_DIR/restic_tmp_$DATE.log"

#be cerful if you decide tu use 'sync' but in general feel free to experiment with parameters
restic backup "$DEST_HDD_DIR/immich_data" "$DEST_HDD_DIR/db_dumps" "$DEST_HDD_DIR/configs" --verbose --pack-size 64 --cleanup-cache --skip-if-unchanged --exclude "lost+found/*" | tee "$RESTIC_TMP_LOG"

# simple parsing
RESTIC_STATS=$(grep -E "^Files:|^Added to the repo:|^processed " "$RESTIC_TMP_LOG")

rm -f "$RESTIC_TMP_LOG"

echo "=== Backup finished ==="
