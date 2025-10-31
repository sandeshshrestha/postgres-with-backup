#!/bin/bash
set -e

BACKUP_TYPE=${1:-incr}

echo "[$(date)] Starting ${BACKUP_TYPE} backup..."

# Run backup as postgres user
su - postgres -c "pgbackrest --stanza=main --type=${BACKUP_TYPE} backup"

if [ $? -eq 0 ]; then
    echo "[$(date)] ${BACKUP_TYPE} backup completed successfully"

    # Show backup info
    su - postgres -c "pgbackrest --stanza=main info"

    # Trigger SFTP upload if enabled
    if [ "${SFTP_ENABLED}" = "true" ]; then
        echo "[$(date)] Triggering SFTP upload..."
        /usr/local/bin/pgbackrest-scripts/sftp-upload.sh
    fi
else
    echo "[$(date)] ERROR: ${BACKUP_TYPE} backup failed"
    exit 1
fi
