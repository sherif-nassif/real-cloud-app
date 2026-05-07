#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. System updates and base packages
# ============================================================
apt-get update -y && apt-get upgrade -y
apt-get install -y \
  curl gnupg lsb-release ca-certificates \
  ufw awscli cron

# ============================================================
# 2. Create deploy user with SSH key-only access
# ============================================================
useradd -m -s /bin/bash -G sudo deploy || true
mkdir -p /home/deploy/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAEXAMPLEKEY deploy@host" > /home/deploy/.ssh/authorized_keys
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy

# ============================================================
# 3. Harden SSH - no root login, no password auth
# ============================================================
cat > /etc/ssh/sshd_config <<'SSHD'
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHD
systemctl restart sshd

# ============================================================
# 4. Firewall (UFW) - only SSH, HTTP, HTTPS
# ============================================================
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ============================================================
# 5. Journald - daily logs, 6 month retention
# ============================================================
cat > /etc/systemd/journald.conf <<'JOURNALD'
[Journal]
Storage=persistent
SplitMode=day
MaxRetentionSec=6month
Compress=yes
JOURNALD
systemctl restart systemd-journald

# ============================================================
# 6. Install PostgreSQL 18
# ============================================================
apt-get install -y postgresql postgresql-contrib
systemctl start postgresql
systemctl enable postgresql

until systemctl is-active --quiet postgresql; do
  sleep 2
done

PG_VERSION=$(psql --version | grep -oE '[0-9]+' | head -1)
CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

# Custom PostgreSQL config
cat >> "$CONF_FILE" <<'PGCONF'
max_connections = 100
shared_buffers = 128MB
effective_cache_size = 512MB
maintenance_work_mem = 64MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
work_mem = 4MB
min_wal_size = 1GB
max_wal_size = 4GB
log_timezone = 'UTC'
timezone = 'UTC'
PGCONF

sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/g" "$CONF_FILE"
echo "host    all    all    127.0.0.1/32    scram-sha-256" >> "$HBA_FILE"

# Create database and users
sudo -u postgres psql <<'EOF'
CREATE DATABASE app;

CREATE USER appuser WITH ENCRYPTED PASSWORD 'appuser_secret_password';
GRANT ALL PRIVILEGES ON DATABASE app TO appuser;

CREATE USER readonly WITH ENCRYPTED PASSWORD 'readonly_secret_password';
GRANT CONNECT ON DATABASE app TO readonly;

\c app

GRANT ALL ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;

GRANT USAGE ON SCHEMA public TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;
EOF

systemctl restart postgresql

# ============================================================
# 7. Install Redis 8 with persistence
# ============================================================
apt-get install -y redis-server

cat > /etc/redis/redis.conf <<'REDISCONF'
bind 127.0.0.1
port 6379
requirepass redis_secret_password
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec
dir /var/lib/redis
maxmemory 256mb
maxmemory-policy allkeys-lru
loglevel notice
REDISCONF

systemctl enable redis-server
systemctl restart redis-server

# ============================================================
# 8. Install Docker
# ============================================================
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker deploy
systemctl enable docker
systemctl start docker

# ============================================================
# 9. Install Nginx with TLS and reverse proxy
# ============================================================
apt-get install -y nginx

cat > /etc/nginx/sites-available/app.conf <<'NGINX'
upstream app {
    server 127.0.0.1:8000;
}

server {
    listen 80;
    server_name app.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name app.example.com;

    ssl_certificate     /etc/ssl/certs/app.crt;
    ssl_certificate_key /etc/ssl/private/app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://app;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 90;
    }

    location /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny  all;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx

# ============================================================
# 10. App directories and docker-compose
# ============================================================
mkdir -p /opt/app /opt/storage
chown -R deploy:deploy /opt/app /opt/storage

mkdir -p /opt/app/src
cat > /opt/app/docker-compose.yml <<'COMPOSE'
services:
  app:
    image: app:latest
    build:
      context: ./src/app
      dockerfile: Dockerfile
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      DATABASE_URL: "postgresql://appuser:appuser_secret_password@host.docker.internal:5432/app"
      REDIS_URL: "redis://:redis_secret_password@host.docker.internal:6379/0"
      LOG_FORMAT: "json"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - /opt/storage:/app/storage
    logging:
      driver: journald
      options:
        tag: "app"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 30s
COMPOSE
chown -R deploy:deploy /opt/app

# ============================================================
# 11. Systemd service for app reload
# ============================================================
cat > /etc/systemd/system/app-reload.service <<'SYSTEMD'
[Unit]
Description=Reload application stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=deploy
WorkingDirectory=/opt/app
ExecStart=/usr/bin/docker compose pull
ExecStart=/usr/bin/docker compose up -d --remove-orphans
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload
systemctl enable app-reload.service

# ============================================================
# 12. Database backup script - hourly to S3
# ============================================================
cat > /usr/local/bin/db_backup.sh <<'BACKUP'
#!/bin/bash
set -euo pipefail

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="/opt/storage/backups/app_${TIMESTAMP}.sql.gz"

export AWS_ACCESS_KEY_ID="s3_access_key_here"
export AWS_SECRET_ACCESS_KEY="s3_secret_key_here"

mkdir -p /opt/storage/backups

echo "[$(date)] Starting backup..."

sudo -u postgres pg_dump app | gzip > "${BACKUP_FILE}"

aws s3 cp "${BACKUP_FILE}" "s3://your-backup-bucket/db-backups/${TIMESTAMP}.sql.gz" \
  --endpoint-url "https://s3.amazonaws.com"

rm -f "${BACKUP_FILE}"
find /opt/storage/backups/ -name "*.sql.gz" -mtime +30 -delete

echo "[$(date)] Backup complete: ${TIMESTAMP}.sql.gz"
BACKUP
chmod 750 /usr/local/bin/db_backup.sh
chown deploy:deploy /usr/local/bin/db_backup.sh

echo "0 * * * * root /usr/local/bin/db_backup.sh >> /var/log/db_backup.log 2>&1" > /etc/cron.d/db_backup
chmod 644 /etc/cron.d/db_backup

# ============================================================
# 13. Start nginx (app will be deployed via CI/CD pipeline)
# ============================================================
systemctl start nginx

echo "[$(date)] Startup script complete. Waiting for app deployment via CI/CD."
