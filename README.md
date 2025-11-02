# PostgreSQL with pgBackRest & SFTP Upload

Modern PostgreSQL backup solution using **pgBackRest** with automatic SFTP upload to remote servers.

## Features

- **pgBackRest** - Enterprise-grade PostgreSQL backup tool
- **Multiple backup types**: Full and Differential backups
- **Automatic SFTP upload** to remote servers
- **Configurable schedules** via cron expressions
- **WAL archiving** for point-in-time recovery
- **Compression** and efficient storage
- **Easy restore** process

## Quick Start

### 1. Basic Setup (No SFTP)

```bash
# Build and start PostgreSQL with local backups
docker compose build
docker compose up -d

# View logs
docker compose logs -f
```

**Note**: PostgreSQL 18+ compatibility is handled by setting `PGDATA=/var/lib/postgresql/data` directly in the container.

### 2. With SFTP Upload (SSH Key Required)

**Step 1: Generate SSH Key**

```bash
mkdir -p ssh
ssh-keygen -t rsa -b 4096 -f ssh/id_rsa -N "" -C "postgres-backup"
```

**Step 2: Copy Public Key to SFTP Server**

```bash
ssh-copy-id -i ssh/id_rsa.pub user@sftp.example.com
```

**Step 3: Configure docker-compose.yml**

Add your SSH private key content to the `SFTP_SSH_KEY` environment variable:

```yaml
environment:
  SFTP_ENABLED: "true"
  SFTP_HOST: "sftp.example.com"
  SFTP_USER: "backup_user"
  SFTP_SSH_KEY: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    ... (paste your full SSH private key content here) ...
    -----END OPENSSH PRIVATE KEY-----
```

**Or use a .env file** (recommended to keep secrets out of docker-compose.yml):

```bash
# Create .env file (never commit this!)
cat > .env << 'EOF'
SFTP_SSH_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
... (your full SSH private key) ...
-----END OPENSSH PRIVATE KEY-----"
EOF

chmod 600 .env
```

Then reference in docker-compose.yml:
```yaml
environment:
  SFTP_SSH_KEY: ${SFTP_SSH_KEY}
```

**Step 4: Start Container**

```bash
docker compose up -d
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | postgres | PostgreSQL username |
| `POSTGRES_PASSWORD` | postgres | PostgreSQL password |
| `POSTGRES_DB` | mydb | Database name |
| `FULL_BACKUP_SCHEDULE` | `0 2 * * 0` | Full backup cron (Sunday 2 AM) |
| `DIFF_BACKUP_SCHEDULE` | `0 2 * * 1,2,3,4,5,6` | Differential backup (Mon-Sat 2 AM) |
| `SFTP_ENABLED` | `false` | Enable SFTP upload |
| `SFTP_HOST` | - | SFTP server hostname |
| `SFTP_USER` | - | SFTP username |
| `SFTP_SSH_KEY` | - | SSH private key content (multiline string) |
| `SFTP_PORT` | `22` | SFTP port |
| `SFTP_REMOTE_PATH` | `/backups` | Remote directory path (exact upload location) |
| `SFTP_UPLOAD_SCHEDULE` | `0 3 * * *` | Upload schedule (3 AM daily) |
| `SFTP_KEEP_BACKUPS` | `7` | Number of backups to keep |

### Backup Types

**Full Backup**: Complete database backup (baseline)
- Schedule: Sunday 2 AM (default)
- Size: Largest
- Required for restore

**Differential Backup**: Changes since last full backup
- Schedule: Monday-Saturday 2 AM (default)
- Size: Smaller than full backup
- Faster than full backup

## Usage

### Check Backup Status

```bash
# View backup info
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info"

# View logs
docker compose exec postgres tail -f /var/log/pgbackrest-cron.log
```

### Manual Backup

```bash
# Full backup
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh full

# Differential backup
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh diff
```

### Manual SFTP Upload

```bash
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/sftp-upload.sh
```

### Restore from Backup

```bash
# Stop PostgreSQL
docker compose down

# Remove old data
docker volume rm postgres_postgres_data

# Start container
docker compose up -d

# Restore (as postgres user inside container)
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main --delta restore"

# Restart PostgreSQL
docker compose restart postgres
```

### Restore from SFTP

```bash
# Download backup from SFTP
sftp user@sftp.example.com
cd /backups/postgres/pgbackrest
get pgbackrest-backup-YYYYMMDD_HHMMSS.tar.gz
exit

# Extract to volume
tar xzf pgbackrest-backup-YYYYMMDD_HHMMSS.tar.gz -C /path/to/volume

# Follow restore steps above
```

## Project Structure

```
postgres/
├── Dockerfile                         # Custom PostgreSQL image with pgBackRest
├── docker-compose.yml                 # Main configuration
├── .github/
│   └── workflows/
│       └── docker-build.yml          # GitHub Actions CI/CD pipeline
├── config/
│   └── pgbackrest.conf               # pgBackRest configuration
├── scripts/
│   └── pgbackrest-scripts/
│       ├── entrypoint.sh             # Container initialization
│       ├── backup.sh                 # Backup execution script
│       └── sftp-upload.sh            # SFTP upload script
└── README.md                         # Documentation
```

## Container Directory Structure

```
/var/lib/postgresql/data/     # PostgreSQL data directory (PGDATA)
/var/lib/pgbackrest/          # pgBackRest backup repository
  ├── archive/                # WAL archives
  └── backup/                 # Backup files
/var/log/pgbackrest/          # pgBackRest logs
/var/log/pgbackrest-cron.log  # Cron job logs
```

## SFTP Upload Structure

Backups are uploaded directly to the configured `SFTP_REMOTE_PATH`:

```
/backups/                     # SFTP_REMOTE_PATH (default)
  ├── pgbackrest-backup-20251031_020000.tar.gz
  ├── pgbackrest-backup-20251101_020000.tar.gz
  └── ...
```

**To organize by database or service**, customize the remote path:

```yaml
# In docker-compose.yml
environment:
  SFTP_REMOTE_PATH: "/backups/postgres"  # Or /backups/mydb, /backups/production, etc.
```

This will upload to:
```
/backups/postgres/
  ├── pgbackrest-backup-20251031_020000.tar.gz
  └── ...
```

## SFTP Authentication

**SSH key authentication is required** for SFTP uploads. Password authentication is not supported for security reasons.

The SSH private key must be provided via the `SFTP_SSH_KEY` environment variable.

### Setup SSH Authentication

**1. Generate SSH key pair**:
```bash
mkdir -p ssh
ssh-keygen -t rsa -b 4096 -f ssh/id_rsa -N "" -C "postgres-backup"
```

**2. Add public key to SFTP server**:
```bash
ssh-copy-id -i ssh/id_rsa.pub user@sftp.example.com
```

**3. Get the private key content**:
```bash
cat ssh/id_rsa
```

**4. Configure the SSH key**:

**Option A: Direct in docker-compose.yml**
```yaml
environment:
  SFTP_ENABLED: "true"
  SFTP_HOST: "sftp.example.com"
  SFTP_USER: "backup_user"
  SFTP_SSH_KEY: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    ... (paste your full SSH private key content) ...
    -----END OPENSSH PRIVATE KEY-----
```

**Option B: Using .env file (Recommended)**
```bash
# Create .env file (never commit this!)
cat > .env << 'EOF'
SFTP_SSH_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
... (your full SSH private key) ...
-----END OPENSSH PRIVATE KEY-----"
EOF

chmod 600 .env
```

Then reference in docker-compose.yml:
```yaml
environment:
  SFTP_SSH_KEY: ${SFTP_SSH_KEY}
```

**Option C: Kubernetes Secret**
```bash
# Create Kubernetes secret from SSH key file
kubectl create secret generic postgres-sftp-key \
  --from-file=ssh-key=ssh/id_rsa

# Reference in your deployment
env:
  - name: SFTP_SSH_KEY
    valueFrom:
      secretKeyRef:
        name: postgres-sftp-key
        key: ssh-key
```

### Security Best Practices

**⚠️ Important**: Never commit your private key to version control!

The `.gitignore` file is already configured to protect:
- `ssh/id_rsa` and all SSH private keys
- `.env` files
- All private key patterns

**Test SSH connection**:
```bash
# Test from your local machine
ssh -i ssh/id_rsa user@sftp.example.com
```

### Why Environment Variable Only?

- ✅ **Cloud-native**: Works seamlessly with Kubernetes, Docker Swarm, AWS ECS
- ✅ **Secrets management**: Integrates with all major secrets managers (Kubernetes Secrets, Docker Secrets, AWS Secrets Manager, HashiCorp Vault, etc.)
- ✅ **Secure**: No files on disk, automatic cleanup of temporary files
- ✅ **Flexible**: Easy to rotate keys via CI/CD pipelines
- ✅ **Universal**: Same approach works everywhere (local, cloud, Kubernetes)

## Monitoring

### Check Backup Status
```bash
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info"
```

### View Logs
```bash
# Cron logs
docker compose exec postgres tail -f /var/log/pgbackrest-cron.log

# pgBackRest logs
docker compose exec postgres tail -f /var/log/pgbackrest/main-backup.log
```

### Verify Backups
```bash
# List backups
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info --output=json" | jq

# Check last backup
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main info" | grep "full backup"
```

## Troubleshooting

### PostgreSQL 18+ pg_ctlcluster error

If you see an error about "pg_ctlcluster" or data directory format, ensure `PGDATA` is set correctly:

**Correct Configuration** (already set in docker-compose.yml):
```yaml
environment:
  PGDATA: /var/lib/postgresql/data
volumes:
  - postgres_data:/var/lib/postgresql/data
```

If you have old data with incompatible format:
```bash
# WARNING: This deletes all existing data
docker compose down -v
docker compose build
docker compose up -d
```

### Stanza creation failed
```bash
# Check PostgreSQL is running
docker compose exec postgres pg_isready

# Manually create stanza
docker compose exec postgres su - postgres -c "pgbackrest --stanza=main stanza-create"
```

### SFTP upload failed
```bash
# Test SFTP connection
docker compose exec postgres sftp user@host

# Check credentials
docker compose exec postgres env | grep SFTP

# View detailed logs
docker compose exec postgres cat /var/log/pgbackrest-cron.log
```

### Backup not running
```bash
# Check cron is running
docker compose exec postgres ps aux | grep cron

# Manually run backup
docker compose exec postgres /usr/local/bin/pgbackrest-scripts/backup.sh full
```

## Performance Tuning

### Faster Backups
```yaml
# In config/pgbackrest.conf
process-max=4  # Increase parallel processes (default: 2)
```

### Compression
```yaml
# In config/pgbackrest.conf
compress-level=3  # 0-9, higher = more compression, slower (default: varies)
compress-type=lz4  # lz4, gz, bz2, zst
```

## Security Best Practices

1. **Use SSH keys** instead of passwords
2. **Restrict SFTP user** permissions to backup directory only
3. **Enable encryption** on SFTP server
4. **Use firewall rules** to limit access
5. **Regular testing** of restore procedures
6. **Monitor logs** for unauthorized access

## Backup Strategy

### Recommended Schedule

**Default Strategy**:
- Full: Weekly (Sunday 2 AM)
- Differential: Daily except Sunday (Mon-Sat 2 AM)

This provides a good balance between backup size, speed, and recovery capabilities.

**Alternative Strategies**:

**For smaller databases (<100GB)**:
- Full: Daily (simpler recovery)

**For larger databases (>1TB)**:
- Full: Bi-weekly or monthly
- Differential: Daily

### Retention Policy

Configure retention in `config/pgbackrest.conf`:
```ini
repo1-retention-full=4        # Keep 4 full backups
repo1-retention-diff=4        # Keep 4 differential backups
repo1-retention-archive=4     # Keep archives for 4 full backups
```

## Why pgBackRest?

- **Production-ready**: Used by many enterprise companies
- **Efficient**: Parallel processing, compression, deduplication
- **Reliable**: Checksums, validation, proven restore
- **Feature-rich**: Encryption, retention, multiple repos
- **Well-documented**: Extensive official documentation
- **Active development**: Regular updates and improvements

## CI/CD Pipeline

This project includes a GitHub Actions workflow (`.github/workflows/docker-build.yml`) that automatically:
- Builds the Docker image on commits to main branch, tags, and pull requests
- Pushes to Docker Hub on main branch and tags
- Creates PostgreSQL version-specific tags: `18-latest`, `18`, `18-<sha>`, `18-v1.0.0`
- Also creates generic tags: `latest`, `v1.0.0` for backward compatibility

The workflow runs on GitHub-hosted runners and uses GitHub Actions cache for faster builds.

**Note**: The PostgreSQL version (currently 18) is defined in the workflow file and corresponds to the base image in the Dockerfile.

### Setup Docker Hub Authentication

To enable automatic publishing to Docker Hub, add these secrets to your GitHub repository:

1. Go to Settings → Secrets and variables → Actions
2. Add the following repository secrets:
   - `DOCKERHUB_USERNAME`: Your Docker Hub username
   - `DOCKERHUB_TOKEN`: Your Docker Hub access token (create at hub.docker.com/settings/security)

### Using the Docker Image

Pull the latest image from Docker Hub:
```bash
# Recommended: Use PostgreSQL version-specific tag
docker pull <your-username>/postgres-with-backup:18-latest

# Or use PostgreSQL version tag (alias for 18-latest)
docker pull <your-username>/postgres-with-backup:18

# Generic latest tag (not recommended)
docker pull <your-username>/postgres-with-backup:latest
```

Or use in docker-compose.yml:
```yaml
services:
  postgres:
    image: <your-username>/postgres-with-backup:18-latest
    # ... rest of configuration
```

### Available Tags

**PostgreSQL 18 tags** (recommended):
- `18-latest` - Latest build for PostgreSQL 18 from main branch
- `18` - Alias for 18-latest
- `18-<sha>` - Specific commit (e.g., `18-a1b2c3d`)
- `18-v1.0.0` - Release version tags

**Generic tags**:
- `latest` - Latest build (currently PostgreSQL 18)
- `v1.0.0` - Release versions without PostgreSQL version prefix

## Additional Resources

- [pgBackRest Documentation](https://pgbackrest.org/user-guide.html)
- [PostgreSQL Backup Best Practices](https://www.postgresql.org/docs/current/backup.html)
- [pgBackRest Configuration Reference](https://pgbackrest.org/configuration.html)
