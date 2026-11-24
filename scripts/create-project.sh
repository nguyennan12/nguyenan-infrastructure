#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <project-name>"
    exit 1
fi

PROJECT="$1"

if [[ ! "$PROJECT" =~ ^[a-z][a-z0-9]{2,29}$ ]]; then
    echo "Use 3-30 lowercase letters or numbers."
    exit 1
fi

DB_NAME="${PROJECT}_db"
DB_USER="${PROJECT}_user"
REDIS_USER="${PROJECT}_user"
MINIO_USER="${PROJECT}_user"
MINIO_BUCKET="$PROJECT"
MINIO_POLICY="${PROJECT}-policy"

PROJECT_DIR="/opt/infra/projects/$PROJECT"

umask 077

if [ -e "$PROJECT_DIR" ]; then
    echo "Project directory already exists."
    exit 1
fi

DB_PASSWORD="$(openssl rand -hex 24)"
REDIS_PASSWORD="$(openssl rand -hex 24)"
MINIO_PASSWORD="$(openssl rand -hex 24)"

# Check required containers
for container in infra-postgres infra-redis infra-minio; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
        echo "Container $container is not running."
        exit 1
    fi
done

command -v mc >/dev/null

# Load Redis admin credentials
REDIS_ADMIN_PASSWORD="$(cat /opt/infra/backup/.redis-password)"

# Read MinIO root credentials without displaying them
read -r -p "MinIO root username: " MINIO_ROOT_USER
read -r -s -p "MinIO root password: " MINIO_ROOT_PASSWORD
echo

MC_CONFIG_DIR="$(mktemp -d)"
export MC_CONFIG_DIR

trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc alias set provisioning-local \
    http://127.0.0.1:9000 \
    "$MINIO_ROOT_USER" \
    "$MINIO_ROOT_PASSWORD" >/dev/null

pg() {
    docker exec -i infra-postgres \
        psql -X -v ON_ERROR_STOP=1 \
        -U infra_admin -d postgres "$@"
}

redis() {
    docker exec -i \
        -e REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" \
        infra-redis redis-cli --raw "$@"
}

echo "Checking existing resources..."

DB_EXISTS="$(pg -Atc "
SELECT count(*) FROM pg_database
WHERE datname = '$DB_NAME';
")"

ROLE_EXISTS="$(pg -Atc "
SELECT count(*) FROM pg_roles
WHERE rolname = '$DB_USER';
")"

if [ "$DB_EXISTS" != "0" ] || [ "$ROLE_EXISTS" != "0" ]; then
    echo "PostgreSQL resources already exist."
    exit 1
fi

test "$(redis PING)" = "PONG"

REDIS_USERS="$(redis ACL USERS)"

if grep -Fxq "$REDIS_USER" <<< "$REDIS_USERS"; then
    echo "Redis user already exists."
    exit 1
fi

mc admin info provisioning-local >/dev/null

MINIO_USERS="$(mc admin user list provisioning-local)"
MINIO_BUCKETS="$(mc ls provisioning-local)"
MINIO_POLICIES="$(mc admin policy list provisioning-local)"

if grep -Fwq "$MINIO_USER" <<< "$MINIO_USERS" ||
   grep -Fq "$MINIO_BUCKET/" <<< "$MINIO_BUCKETS" ||
   grep -Fxq "$MINIO_POLICY" <<< "$MINIO_POLICIES"; then
    echo "MinIO resources already exist."
    exit 1
fi

# Save credentials before provisioning
install -d -m 700 "$PROJECT_DIR"

trap 'rm -rf "$MC_CONFIG_DIR"; echo "Provisioning failed. Check partial resources in $PROJECT_DIR."' ERR

cat > "$PROJECT_DIR/.env" <<EOF
PROJECT_NAME=$PROJECT

POSTGRES_HOST=postgres.static4j.app
POSTGRES_PORT=6433
POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASSWORD
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@postgres.static4j.app:6433/$DB_NAME?sslmode=verify-full

REDIS_HOST=redis.static4j.app
REDIS_PORT=6380
REDIS_USER=$REDIS_USER
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_KEY_PREFIX=$PROJECT:
REDIS_URL=rediss://$REDIS_USER:$REDIS_PASSWORD@redis.static4j.app:6380

S3_ENDPOINT=https://minio.static4j.app
S3_BUCKET=$MINIO_BUCKET
S3_ACCESS_KEY=$MINIO_USER
S3_SECRET_KEY=$MINIO_PASSWORD
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
EOF

chmod 600 "$PROJECT_DIR/.env"

echo "[1/3] Creating PostgreSQL resources..."

pg <<SQL
CREATE ROLE "$DB_USER"
    LOGIN
    PASSWORD '$DB_PASSWORD'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

CREATE DATABASE "$DB_NAME"
    OWNER "$DB_USER";

REVOKE CONNECT ON DATABASE "$DB_NAME" FROM PUBLIC;

GRANT CONNECT ON DATABASE "$DB_NAME" TO "$DB_USER";
SQL

echo "[2/3] Creating Redis user..."

RESULT="$(redis ACL SETUSER "$REDIS_USER" \
    reset on ">$REDIS_PASSWORD" \
    "~$PROJECT:*" \
    +ping +get +set +del +unlink \
    +exists +expire +pexpire +ttl +pttl \
    +mget +mset +incr +decr \
    +hget +hset +hdel +hgetall)"

test "$RESULT" = "OK"
test "$(redis ACL SAVE)" = "OK"

echo "[3/3] Creating MinIO resources..."

mc mb "provisioning-local/$MINIO_BUCKET"

cat > "$PROJECT_DIR/minio-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::$MINIO_BUCKET"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::$MINIO_BUCKET/*"
      ]
    }
  ]
}
EOF

mc admin policy create \
    provisioning-local \
    "$MINIO_POLICY" \
    "$PROJECT_DIR/minio-policy.json"

mc admin user add \
    provisioning-local \
    "$MINIO_USER" \
    "$MINIO_PASSWORD"

mc admin policy attach \
    provisioning-local \
    "$MINIO_POLICY" \
    --user "$MINIO_USER"

touch "$PROJECT_DIR/.provisioned"

echo "======================================"
echo "Project created successfully: $PROJECT"
echo "Database: $DB_NAME"
echo "Redis prefix: $PROJECT:*"
echo "MinIO bucket: $MINIO_BUCKET"
echo "Credentials: $PROJECT_DIR/.env"
echo "======================================"