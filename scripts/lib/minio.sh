#!/usr/bin/env bash

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

    cat >> "$ENV_FILE" <<EOF

# MinIO
S3_ENDPOINT=https://minio.static4j.app
S3_BUCKET=$MINIO_BUCKET
S3_ACCESS_KEY=$MINIO_USER
S3_SECRET_KEY=$password
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
EOF

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

    mc mb "provisioning-local/$MINIO_BUCKET"

    mc admin policy create \
        provisioning-local \
        "$MINIO_POLICY" \
        "$PROJECT_DIR/minio-policy.json"

    mc admin user add \
        provisioning-local \
        "$MINIO_USER" \
        "$password"

    mc admin policy attach \
        provisioning-local \
        "$MINIO_POLICY" \
        --user "$MINIO_USER"

    set_service_state minio true

    echo "MinIO provisioned successfully."
)

remove_minio() (
    require_container infra-minio

    command -v mc >/dev/null

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

    mc admin user disable \
        deletion-local \
        "$MINIO_USER"

    mc admin policy detach \
        deletion-local \
        "$MINIO_POLICY" \
        --user "$MINIO_USER"

    mc admin user remove \
        deletion-local \
        "$MINIO_USER"

    mc rb --force \
        "deletion-local/$MINIO_BUCKET"

    mc admin policy remove \
        deletion-local \
        "$MINIO_POLICY"

    rm -f "$PROJECT_DIR/minio-policy.json"

    remove_env_vars '^S3_.*$'

    set_service_state minio false

    echo "MinIO removed successfully."
)