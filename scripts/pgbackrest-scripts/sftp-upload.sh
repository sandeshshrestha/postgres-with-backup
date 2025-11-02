#!/bin/bash
set -e

# SFTP Upload Script for pgBackRest backups
# Uploads the entire pgBackRest repository to remote SFTP server

echo "[$(date)] === SFTP Upload Starting ==="

# Check if SFTP is enabled
if [ "${SFTP_ENABLED}" != "true" ]; then
  echo "[$(date)] SFTP upload disabled (SFTP_ENABLED != true)"
  exit 0
fi

# Validate required SFTP variables
if [ -z "${SFTP_HOST}" ] || [ -z "${SFTP_USER}" ]; then
  echo "[$(date)] ERROR: SFTP_HOST and SFTP_USER are required when SFTP_ENABLED=true"
  exit 1
fi

# SSH key authentication - requires SFTP_SSH_KEY environment variable
if [ -z "${SFTP_SSH_KEY}" ]; then
  echo "[$(date)] ERROR: SFTP_SSH_KEY environment variable is required!"
  echo "[$(date)]"
  echo "[$(date)] Please provide your SSH private key as an environment variable:"
  echo "[$(date)]   SFTP_SSH_KEY='-----BEGIN OPENSSH PRIVATE KEY-----"
  echo "[$(date)]   b3BlbnNzaC1rZXktdjEAAAAA..."
  echo "[$(date)]   -----END OPENSSH PRIVATE KEY-----'"
  echo "[$(date)]"
  echo "[$(date)] Example in docker-compose.yml:"
  echo "[$(date)]   environment:"
  echo "[$(date)]     SFTP_SSH_KEY: |"
  echo "[$(date)]       -----BEGIN OPENSSH PRIVATE KEY-----"
  echo "[$(date)]       (your full SSH private key content)"
  echo "[$(date)]       -----END OPENSSH PRIVATE KEY-----"
  exit 1
fi

echo "[$(date)] Using SSH key from SFTP_SSH_KEY environment variable"

# Create temporary file for SSH key
TEMP_KEY_FILE="/tmp/sftp_key_$$"
echo "${SFTP_SSH_KEY}" > "${TEMP_KEY_FILE}"
chmod 600 "${TEMP_KEY_FILE}"
SSH_KEY_FILE="${TEMP_KEY_FILE}"

echo "[$(date)] SSH key configured successfully"

SFTP_PORT=${SFTP_PORT:-22}
SFTP_REMOTE_PATH=${SFTP_REMOTE_PATH:-/backups}
BACKUP_REPO="/var/lib/pgbackrest"
TEMP_ARCHIVE="/tmp/pgbackrest-backup-$(date +%Y%m%d_%H%M%S).tar.gz"

echo "[$(date)] Creating backup archive..."
tar czf ${TEMP_ARCHIVE} -C /var/lib pgbackrest

if [ $? -ne 0 ]; then
  echo "[$(date)] ERROR: Failed to create backup archive"
  exit 1
fi

ARCHIVE_SIZE=$(du -h ${TEMP_ARCHIVE} | cut -f1)
echo "[$(date)] Archive created: ${TEMP_ARCHIVE} (${ARCHIVE_SIZE})"

# Upload to SFTP using SSH key
upload_to_sftp() {
  sftp -o StrictHostKeyChecking=no -P ${SFTP_PORT} -i "${SSH_KEY_FILE}" ${SFTP_USER}@${SFTP_HOST} << EOF
-mkdir ${SFTP_REMOTE_PATH}
-mkdir ${SFTP_REMOTE_PATH}/postgres
-mkdir ${SFTP_REMOTE_PATH}/postgres/pgbackrest
cd ${SFTP_REMOTE_PATH}/postgres/pgbackrest
put ${TEMP_ARCHIVE}
bye
EOF
}

echo "[$(date)] Uploading to ${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}${SFTP_REMOTE_PATH}/pgbackrest/"

upload_to_sftp

if [ $? -eq 0 ]; then
  echo "[$(date)] Upload successful: $(basename ${TEMP_ARCHIVE})"

  # Clean up local archive
  rm -f ${TEMP_ARCHIVE}
  echo "[$(date)] Local archive removed"

  # Optional: Clean up old remote backups (keep last N backups)
  KEEP_BACKUPS=${SFTP_KEEP_BACKUPS:-7}
  echo "[$(date)] Note: Configure remote cleanup to keep last ${KEEP_BACKUPS} backups"

else
  echo "[$(date)] ERROR: Upload failed"
  rm -f ${TEMP_ARCHIVE}

  # Clean up temporary SSH key
  rm -f "${TEMP_KEY_FILE}"
  echo "[$(date)] Temporary SSH key removed"

  exit 1
fi

# Clean up temporary SSH key
rm -f "${TEMP_KEY_FILE}"
echo "[$(date)] Temporary SSH key removed"

echo "[$(date)] === SFTP Upload Completed ==="
