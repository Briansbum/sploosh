#!/usr/bin/env bash
# register-ami.sh — upload a nixos-generators amazon image to EC2 and register it.
#
# Called by .github/workflows/ami.yml after `nix build .#amis.<modpack>`.
#
# Usage:
#   ./scripts/register-ami.sh <modpack> <nix-result-path>
#
# Requires: awscli2, jq
# Env vars: AWS_REGION, S3_BUCKET, CF_WORKER_URL, CF_WORKER_SECRET

set -euo pipefail

MODPACK="${1:?Usage: register-ami.sh <modpack> <nix-result-path>}"
NIX_RESULT="${2:?Usage: register-ami.sh <modpack> <nix-result-path>}"
REGION="${AWS_REGION:-eu-west-2}"
BUCKET="${S3_BUCKET:-sploosh-minecraft-backups}"

# nixos-generators amazon format produces a .vhd file
VHD=$(find "$NIX_RESULT" -name "*.vhd" -o -name "nixos-amazon-image-*.vhd" | head -1)
if [ -z "$VHD" ]; then
  echo "ERROR: no .vhd file found in $NIX_RESULT"
  ls "$NIX_RESULT/"
  exit 1
fi

SHA=$(sha256sum "$VHD" | cut -d' ' -f1 | head -c16)
S3_KEY="ami-staging/${MODPACK}/${SHA}.vhd"

echo "==> Uploading $VHD → s3://$BUCKET/$S3_KEY"
aws s3 cp "$VHD" "s3://$BUCKET/$S3_KEY" --region "$REGION"

echo "==> Importing snapshot..."
IMPORT_TASK=$(aws ec2 import-snapshot \
  --region "$REGION" \
  --description "sploosh-${MODPACK}" \
  --disk-container "{
    \"Description\": \"sploosh-${MODPACK}\",
    \"Format\": \"VHD\",
    \"UserBucket\": {
      \"S3Bucket\": \"$BUCKET\",
      \"S3Key\": \"$S3_KEY\"
    }
  }" \
  --query 'ImportTaskId' \
  --output text)

echo "  ImportTaskId: $IMPORT_TASK"

# Poll until complete
while true; do
  STATUS=$(aws ec2 describe-import-snapshot-tasks \
    --region "$REGION" \
    --import-task-ids "$IMPORT_TASK" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' \
    --output text)
  PROGRESS=$(aws ec2 describe-import-snapshot-tasks \
    --region "$REGION" \
    --import-task-ids "$IMPORT_TASK" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Progress' \
    --output text 2>/dev/null || echo "?")
  echo "  Status: $STATUS ($PROGRESS%)"
  [ "$STATUS" = "completed" ] && break
  [ "$STATUS" = "deleted" ] && echo "ERROR: import failed" && exit 1
  sleep 15
done

SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
  --region "$REGION" \
  --import-task-ids "$IMPORT_TASK" \
  --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
  --output text)

echo "  SnapshotId: $SNAPSHOT_ID"

echo "==> Registering AMI..."
AMI_ID=$(aws ec2 register-image \
  --region "$REGION" \
  --name "sploosh-${MODPACK}-$(date +%Y%m%d%H%M%S)" \
  --description "sploosh ${MODPACK}" \
  --architecture x86_64 \
  --root-device-name /dev/xvda \
  --virtualization-type hvm \
  --ena-support \
  --block-device-mappings "[{
    \"DeviceName\": \"/dev/xvda\",
    \"Ebs\": {
      \"SnapshotId\": \"$SNAPSHOT_ID\",
      \"VolumeSize\": 16,
      \"VolumeType\": \"gp3\",
      \"DeleteOnTermination\": true
    }
  }]" \
  --query 'ImageId' \
  --output text)

echo "  AMI_ID: $AMI_ID"

echo "==> Updating D1 via worker admin endpoint..."
if [ -n "${CF_WORKER_URL:-}" ]; then
  BODY="{\"ami_id\": \"${AMI_ID}\"}"
  HMAC=$(echo -n "${MODPACK}:${BODY}" | \
    openssl dgst -sha256 -hmac "${CF_WORKER_SECRET:?}" | awk '{print $2}')
  curl -sf -X PATCH "${CF_WORKER_URL}/admin/modpacks/${MODPACK}" \
    -H "Content-Type: application/json" \
    -H "X-Sploosh-Sig: $HMAC" \
    -d "$BODY"
  echo "  D1 updated."
fi

echo "==> Updating launch template to new AMI..."
LT_ID=$(aws ec2 describe-launch-templates \
  --region "$REGION" \
  --filters "Name=launch-template-name,Values=sploosh-${MODPACK}" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text)
if [ -z "$LT_ID" ] || [ "$LT_ID" = "None" ]; then
  echo "ERROR: launch template sploosh-${MODPACK} not found"
  exit 1
fi
echo "  LaunchTemplateId: $LT_ID"

NEW_VER=$(aws ec2 create-launch-template-version \
  --region "$REGION" \
  --launch-template-id "$LT_ID" \
  --source-version '$Default' \
  --launch-template-data "{\"ImageId\":\"${AMI_ID}\"}" \
  --query 'LaunchTemplateVersion.VersionNumber' \
  --output text)

aws ec2 modify-launch-template \
  --region "$REGION" \
  --launch-template-id "$LT_ID" \
  --default-version "$NEW_VER"
echo "  Launch template $LT_ID default → version $NEW_VER"

echo "Done. AMI: $AMI_ID"
