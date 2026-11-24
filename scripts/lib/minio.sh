#!/usr/bin/env bash

# ==========================================
# Create MinIO resources
# ==========================================

create_minio() (
    require_container infra-minio

    if ! command -v mc >/dev/null 2>&1; then
        echo "MinIO Client is missing."
        return 1
    fi

    echo "Creating MinIO resources..."

    local root_user
    local root_password
    local password
    local users
    local buckets
    local policies

    read -r -p "MinIO root username: " root_user
    read -r -s -p "MinIO root password: " root_password
    echo

    export MC_CONFIG_DIR
    MC_CONFIG_DIR="$(mktemp -d)"

    trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

    mc alias set provisioning-local \
        http://127.0.0.1:9000 \
        "$root_user" \
        "$root_password" >/dev/null

    mc admin info provisioning-local >/dev/null

    # Check existing resources
    users="$(mc admin user list provisioning-local)"
    buckets="$(mc ls provisioning-local)"
    policies="$(mc admin policy list provisioning-local)"

    if grep -Fwq "$MINIO_USER" <<< "$users" ||
       grep -Fq "$MINIO_BUCKET/" <<< "$buckets" ||
       grep -Fxq "$MINIO_POLICY" <<< "$policies"; then

        echo "MinIO resources already exist."
        return 1
    fi

    password="$(generate_password)"

    # Save connection credentials
    cat >> "$ENV_FILE" <<EOF

# MinIO
S3_ENDPOINT=https://minio.static4j.app
S3_BUCKET=$MINIO_BUCKET
S3_ACCESS_KEY=$MINIO_USER
S3_SECRET_KEY=$password
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
EOF

    # Generate bucket-scoped IAM policy
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

    chmod 600 "$ENV_FILE"
    chmod 600 "$PROJECT_DIR/minio-policy.json"

    # Create bucket
    echo "Creating MinIO bucket..."

    mc mb "provisioning-local/$MINIO_BUCKET"

    # Create policy
    echo "Creating MinIO policy..."

    mc admin policy create \
        provisioning-local \
        "$MINIO_POLICY" \
        "$PROJECT_DIR/minio-policy.json"

    # Create user
    echo "Creating MinIO user..."

    mc admin user add \
        provisioning-local \
        "$MINIO_USER" \
        "$password"

    # Attach policy
    echo "Attaching MinIO policy..."

    mc admin policy attach \
        provisioning-local \
        "$MINIO_POLICY" \
        --user "$MINIO_USER"

    # Update project manifest
    set_service_state minio true

    echo "MinIO provisioned successfully."
)

# ==========================================
# Remove MinIO resources
# ==========================================

remove_minio() (
    require_container infra-minio

    if ! command -v mc >/dev/null 2>&1; then
        echo "MinIO Client is missing."
        return 1
    fi

    echo "Removing MinIO resources..."

    local root_user
    local root_password

    read -r -p "MinIO root username: " root_user
    read -r -s -p "MinIO root password: " root_password
    echo

    export MC_CONFIG_DIR
    MC_CONFIG_DIR="$(mktemp -d)"

    trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

    mc alias set deletion-local \
        http://127.0.0.1:9000 \
        "$root_user" \
        "$root_password" >/dev/null

    mc admin info deletion-local >/dev/null

    # Disable user access
    echo "Disabling MinIO user..."

    mc admin user disable \
        deletion-local \
        "$MINIO_USER"

    # Remove user directly.
    # Policy detach is not required.
    echo "Removing MinIO user..."

    mc admin user remove \
        deletion-local \
        "$MINIO_USER"

    # Remove bucket and its objects
    echo "Removing MinIO bucket..."

    mc rb --force \
        "deletion-local/$MINIO_BUCKET"

    # Remove project policy
    echo "Removing MinIO policy..."

    mc admin policy remove \
        deletion-local \
        "$MINIO_POLICY"

    # Remove local policy configuration
    rm -f "$PROJECT_DIR/minio-policy.json"

    # Remove MinIO environment variables
    remove_env_vars '^S3_.*$'

    # Update project manifest
    set_service_state minio false

    echo "MinIO removed successfully."
)