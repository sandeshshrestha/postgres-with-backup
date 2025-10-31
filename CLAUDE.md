# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a PostgreSQL backup system using **pgBackRest** with optional SFTP upload to remote servers. The system runs PostgreSQL 18 in a Docker container with automated backup scheduling via cron.

## Architecture

### Container Structure

**Single Container Design**: Unlike typical backup solutions that use separate containers, this uses a single container that runs both PostgreSQL and the backup system. This is achieved through:

1. **Custom Dockerfile** (`Dockerfile`):
   - Extends `postgres:18` base image
   - Installs pgBackRest, cron, and SFTP tools (openssh-client, sshpass)
   - Sets up directory structure for pgBackRest repository, logs, and spools
   - Copies configuration and scripts into the container

2. **Custom Entrypoint** (`scripts/pgbackrest-scripts/entrypoint.sh`):
   - Wraps the standard PostgreSQL entrypoint (`docker-entrypoint.sh`)
   - Starts PostgreSQL in background with pgBackRest-specific configurations
   - Waits for PostgreSQL to be ready, then initializes pgBackRest stanza
   - Sets up cron jobs for scheduled backups and SFTP uploads
   - PostgreSQL runs with WAL archiving enabled (`archive_command='pgbackrest --stanza=main archive-push %p'`)

### pgBackRest Integration

**Stanza**: Named "main" - this is pgBackRest's configuration unit that defines the PostgreSQL cluster to backup.

**Initialization Flow**:
1. Container starts → PostgreSQL starts with `archive_mode=on` and dummy `archive_command=/bin/true`
2. Wait for PostgreSQL to be ready (pg_isready check)
3. Verify database and user exist
4. Create pgBackRest stanza
5. Change archive_command to use pgBackRest via ALTER SYSTEM
6. Reload PostgreSQL configuration
7. Create initial full backup
8. Set up cron jobs based on environment variables

This approach ensures:
- `archive_mode=on` from startup (no restart needed, pgBackRest can backup immediately)
- Dummy archive_command prevents failures before stanza creation
- Real archive_command activated only after stanza exists

**Archive Command**: PostgreSQL is configured to push WAL files to pgBackRest automatically via `archive_command`. This enables point-in-time recovery.

### Backup Scripts

Three bash scripts in `scripts/pgbackrest-scripts/`:

1. **backup.sh**: Wrapper that runs pgBackRest with specified type (full/diff), then triggers SFTP upload if enabled
2. **sftp-upload.sh**: Creates tar.gz of entire pgBackRest repository and uploads to remote SFTP server
3. **entrypoint.sh**: Container initialization (described above)

### Configuration Files

- **config/pgbackrest.conf**: pgBackRest configuration with stanza definition, retention policies, and archive settings
- **docker-compose.yml**: Main configuration with SFTP disabled by default
- **.github/workflows/docker-build.yml**: GitHub Actions workflow for building and pushing Docker image to GitHub Container Registry

## Key Commands

### Build and Run

```bash
# Build the image
docker compose build

# Start container
docker compose up -d

# View logs
docker compose logs -f

# Stop and remove
docker compose down
```

### Manual Backups

```bash
# Full backup
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh full

# Differential backup
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh diff
```

### Monitoring

```bash
# Check backup status
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info"

# View cron logs
docker compose exec postgres tail -f /var/log/pgbackrest-cron.log

# View pgBackRest logs
docker compose exec postgres tail -f /var/log/pgbackrest/main-backup.log

# Check PostgreSQL status
docker compose exec postgres pg_isready -U postgres
```

### Manual SFTP Upload

```bash
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/sftp-upload.sh
```

### Restore

```bash
# Stop and clean
docker compose down
docker volume rm postgres_postgres_data

# Start and restore
docker compose up -d
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main --delta restore"
docker compose restart postgres
```

## Important Implementation Details

### Environment Variable Handling

All backup schedules and SFTP settings are controlled via environment variables in docker-compose.yml. The entrypoint script reads these at runtime to configure cron jobs.

**Critical**: SFTP_ENABLED must be exactly "true" (string) for SFTP to work. The bash scripts use string comparison: `[ "${SFTP_ENABLED}" = "true" ]`

### Authentication Methods

SFTP supports two auth methods checked in order:
1. Password: If `SFTP_PASSWORD` is set
2. SSH Key: If `/root/.ssh/sftp_key` file exists (mounted volume)

The sftp-upload.sh script detects which method is available and uses appropriate SFTP commands.

### Backup Types and Strategy

- **Full**: Complete backup, baseline for all other backups (Sunday 2 AM default)
- **Differential**: Changes since last full backup (Monday-Saturday 2 AM default)

Retention is controlled in `config/pgbackrest.conf` (repo1-retention-* settings).

### Container Volumes

Three persistent volumes:
- `postgres_data`: PostgreSQL data directory (mounted at `/var/lib/postgresql/data`)
- `pgbackrest_repo`: Backup repository (archives and backups)
- `pgbackrest_logs`: pgBackRest operation logs

### Cron Job Setup

Cron jobs are dynamically written to `/etc/cron.d/pgbackrest` based on environment variables. The entrypoint uses here-doc syntax to create the cron file at container startup.

## Modifying the System

### Changing Backup Schedules

Edit environment variables in docker-compose.yml (cron syntax), then restart:
```bash
docker compose restart postgres
```

### Changing pgBackRest Configuration

1. Edit `config/pgbackrest.conf`
2. **Important**: If changing `pg1-path`, ensure it matches `PGDATA` environment variable (`/var/lib/postgresql/data`)
3. Rebuild: `docker compose build`
4. Recreate container: `docker compose up -d --force-recreate`

### Adding New Scripts

1. Add script to `scripts/pgbackrest-scripts/`
2. Make executable: `chmod +x scripts/pgbackrest-scripts/your-script.sh`
3. Rebuild container (Dockerfile copies all scripts)

### Enabling SFTP

Set these environment variables in docker-compose.yml:
```yaml
SFTP_ENABLED: "true"
SFTP_HOST: "your-server.com"
SFTP_USER: "username"
SFTP_PASSWORD: "password"  # OR mount SSH key
```

For SSH key auth, mount the key:
```yaml
volumes:
  - ./ssh/id_rsa:/root/.ssh/sftp_key:ro
```

## Common Issues

### Stanza Creation Fails

The stanza must be created after PostgreSQL is fully initialized. The entrypoint waits 10 seconds and checks `pg_isready` before attempting stanza creation. If this fails, manually run:
```bash
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main stanza-create"
```

### Backups Not Running

Cron daemon must be running inside the container. Check with:
```bash
docker compose exec postgres ps aux | grep cron
```

If cron is not running, the entrypoint script failed. Check container logs.

### SFTP Upload Fails But Backup Succeeds

This is by design. The backup.sh script runs the backup first, then optionally uploads. SFTP failures don't affect local backup success. Check SFTP credentials and connectivity.

## CI/CD Pipeline

### GitHub Actions

The `.github/workflows/docker-build.yml` workflow builds and pushes the Docker image to Docker Hub:

**Image Name**: `<username>/postgres-with-backup`

**Trigger Events**:
- Push to main/master branch
- Git tags (e.g., v1.0.0)
- Pull requests (build only, no push)

**Image Tags Generated**:

*PostgreSQL version-specific tags (primary):*
- `18-latest`: Latest PostgreSQL 18 build from main branch
- `18`: Alias for 18-latest
- `18-<sha>`: Commit-specific (e.g., `18-a1b2c3d`)
- `18-v1.0.0`, `18-1.0`: Versioned releases with PostgreSQL version

*Generic tags (for backward compatibility):*
- `latest`: Latest build (currently PostgreSQL 18)
- `v1.0.0`, `1.0`: Versioned releases

**Important**: The PostgreSQL version is defined in the workflow file as `POSTGRES_VERSION: "18"` and should match the base image in the Dockerfile.

**Features**:
- Uses GitHub Actions cache for faster builds
- Multi-platform support via Docker Buildx
- Metadata extraction for proper tagging
- Automatic publishing to Docker Hub

**Setup Requirements**:
1. Create a Docker Hub access token at https://hub.docker.com/settings/security
2. Add GitHub repository secrets (Settings → Secrets and variables → Actions):
   - `DOCKERHUB_USERNAME`: Your Docker Hub username
   - `DOCKERHUB_TOKEN`: Your Docker Hub access token
3. Workflow runs automatically on push to main or tags

**Pulling the Image**:
```bash
# Recommended: Use PostgreSQL version tag
docker pull <username>/postgres-with-backup:18-latest

# Or use specific version
docker pull <username>/postgres-with-backup:18

# Generic latest (not recommended for production)
docker pull <username>/postgres-with-backup:latest
```

## Testing Changes

When modifying scripts or configuration:

1. Rebuild: `docker compose build`
2. Test with temporary container: `docker compose up` (without -d to see logs)
3. Manually trigger backup to verify: `docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh full`
4. Check logs: `docker compose exec postgres tail -f /var/log/pgbackrest-cron.log`
5. Verify backup exists: `docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info"`

## PostgreSQL Configuration

PostgreSQL archiving is configured in two phases:

**Phase 1 (startup)**: PostgreSQL starts with these base settings:
- `wal_level=replica`: Required for archiving
- `max_wal_senders=3`, `wal_keep_size=1GB`, etc.

**Phase 2 (after stanza creation)**: Archiving is enabled via ALTER SYSTEM:
- `archive_mode=on`: Enable WAL archiving
- `archive_command='pgbackrest --stanza=main archive-push %p'`: Send WAL to pgBackRest
- `archive_timeout=300`: Force WAL archiving every 5 minutes

See entrypoint.sh lines 69-95 for the complete initialization sequence.

### PostgreSQL 18+ Data Directory

PostgreSQL 18+ Docker images have a new directory structure. This project handles it simply by setting `PGDATA` directly:

**Configuration**:
- `PGDATA=/var/lib/postgresql/data` (set in docker-compose.yml environment)
- Volume mounted at: `/var/lib/postgresql/data`
- pgBackRest points to: `/var/lib/postgresql/data`

**Key Files**:
- docker-compose.yml line 15: `PGDATA: /var/lib/postgresql/data`
- docker-compose.yml line 35: `postgres_data:/var/lib/postgresql/data`
- config/pgbackrest.conf line 19: `pg1-path=/var/lib/postgresql/data`

This bypasses the pg_ctlcluster compatibility layer and uses a traditional PostgreSQL data directory structure.
