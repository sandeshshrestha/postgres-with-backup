#!/bin/bash
set -e

echo "=== pgBackRest PostgreSQL Backup System ==="

# Fix permissions on mounted volumes
echo "Setting up directory permissions..."
chown -R postgres:postgres /var/lib/pgbackrest
chown -R postgres:postgres /var/log/pgbackrest
chown -R postgres:postgres /var/spool/pgbackrest
chmod 750 /var/lib/pgbackrest
chmod 750 /var/log/pgbackrest
chmod 750 /var/spool/pgbackrest

# Create pgBackRest stanza only (before archive_mode is enabled)
create_stanza_only() {
    echo "Checking pgBackRest stanza..."

    # Create .pgpass file for postgres user to authenticate
    echo "Setting up pgBackRest authentication..."
    cat > /var/lib/postgresql/.pgpass << EOF
localhost:5432:*:${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD:-postgres}
EOF
    chown postgres:postgres /var/lib/postgresql/.pgpass
    chmod 600 /var/lib/postgresql/.pgpass

    # Always try to create stanza (it will error if it exists, which is fine)
    echo "Creating pgBackRest stanza..."
    if su - postgres -c "pgbackrest --stanza=main --log-level-console=info stanza-create" 2>&1; then
        echo "Stanza created successfully"
    else
        echo "Stanza may already exist, checking..."
        if su - postgres -c "pgbackrest --stanza=main info" >/dev/null 2>&1; then
            echo "Stanza verified successfully"
        else
            echo "ERROR: Stanza creation failed and stanza does not exist!"
            return 1
        fi
    fi
}

# Create initial backup (after archive_mode is enabled)
create_initial_backup() {
    # Perform initial full backup if none exists
    if ! su - postgres -c "pgbackrest --stanza=main info" 2>&1 | grep -q "full backup"; then
        echo "No full backup found, creating initial backup..."
        su - postgres -c "pgbackrest --stanza=main --type=full backup"
        if [ $? -eq 0 ]; then
            echo "Initial backup completed successfully"
        else
            echo "ERROR: Initial backup failed!"
            return 1
        fi
    else
        echo "Existing backups found"
    fi
}

# Set up cron jobs for backups and SFTP upload
setup_cron() {
    echo "Setting up backup schedule..."

    FULL_BACKUP_SCHEDULE=${FULL_BACKUP_SCHEDULE:-"0 2 * * 0"}
    DIFF_BACKUP_SCHEDULE=${DIFF_BACKUP_SCHEDULE:-"0 2 * * 1,2,3,4,5,6"}

    echo "Full backup schedule: ${FULL_BACKUP_SCHEDULE}"
    echo "Differential backup schedule: ${DIFF_BACKUP_SCHEDULE}"

    # Create cron jobs
    cat > /etc/cron.d/pgbackrest << EOF
${FULL_BACKUP_SCHEDULE} root /usr/local/bin/pgbackrest-scripts/backup.sh full >> /var/log/pgbackrest-cron.log 2>&1
${DIFF_BACKUP_SCHEDULE} root /usr/local/bin/pgbackrest-scripts/backup.sh diff >> /var/log/pgbackrest-cron.log 2>&1
EOF

    # Add SFTP upload cron if enabled
    if [ "${SFTP_ENABLED}" = "true" ]; then
        SFTP_UPLOAD_SCHEDULE=${SFTP_UPLOAD_SCHEDULE:-"0 3 * * *"}
        echo "SFTP upload schedule: ${SFTP_UPLOAD_SCHEDULE}"
        echo "${SFTP_UPLOAD_SCHEDULE} root /usr/local/bin/pgbackrest-scripts/sftp-upload.sh >> /var/log/pgbackrest-cron.log 2>&1" >> /etc/cron.d/pgbackrest
    fi

    # Add trailing newline (required by cron specification)
    echo "" >> /etc/cron.d/pgbackrest

    chmod 0644 /etc/cron.d/pgbackrest

    # Start cron
    echo "Starting cron daemon..."
    cron
}

# Configure PostgreSQL for pgBackRest
# PGDATA is set via environment variable in docker-compose.yml

# Start PostgreSQL with archive_mode on
# archive_command will be set via ALTER SYSTEM after stanza creation
docker-entrypoint.sh postgres \
    -c wal_level=replica \
    -c archive_mode=on \
    -c archive_timeout=300 \
    -c max_wal_senders=3 \
    -c wal_keep_size=1GB \
    -c checkpoint_timeout=15min \
    -c max_wal_size=2GB &

PG_PID=$!

# Wait for PostgreSQL to be ready, then initialize stanza
(
    # Wait for PostgreSQL to accept connections
    until pg_isready -U "${POSTGRES_USER:-postgres}" -h localhost; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 2
    done

    # Give it a bit more time to ensure the database is fully initialized
    sleep 3

    # Verify the user and database exist
    echo "Verifying PostgreSQL setup..."
    until PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-mydb}" -h localhost -c "SELECT 1" >/dev/null 2>&1; do
        echo "Waiting for database initialization..."
        sleep 2
    done

    echo "PostgreSQL is ready, creating pgBackRest stanza..."

    # Create stanza first (doesn't require archive_mode)
    create_stanza_only

    echo "Activating pgBackRest archive command..."
    # Update archive_command to use pgBackRest (archive_mode is already on)
    PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-mydb}" -h localhost -c "ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=main archive-push %p';"

    # Reload PostgreSQL configuration
    PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-mydb}" -h localhost -c "SELECT pg_reload_conf();"

    # Give PostgreSQL a moment to apply the new configuration
    sleep 2

    echo "pgBackRest archive command activated"

    # Now create initial backup (requires archive_mode to be on)
    create_initial_backup

    setup_cron
) &

# Wait for PostgreSQL process
wait $PG_PID
