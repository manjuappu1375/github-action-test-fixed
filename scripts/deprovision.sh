#!/usr/bin/env bash
#
# deprovision.sh <path/to/config.yaml> [--yes] [--with-iam-and-bucket] [--dry-run]
#
# Deletes exactly the resources named in the given config YAML - and only
# those. It never touches resources from any other config file, even if
# they share the same app_name.
#
# Deletes by default:
#   - CodePipeline               (codepipeline.pipeline_name)
#   - CodeBuild project          (codebuild.project_name)
#   - The SQS -> Lambda event source mapping(s) for THIS queue and THIS
#     function specifically (not any other trigger the function might have)
#   - Lambda function            (lambda.function_name)
#   - SQS queue                  (sqs.queue_name)
#
# NOT deleted unless you pass --with-iam-and-bucket:
#   - The three IAM roles (<app_name>-lambda-role / -codebuild-role /
#     -codepipeline-role) and the S3 artifact bucket. These are named from
#     app_name alone, so if you have more than one config file sharing the
#     same app_name (e.g. you copy-pasted a config for a second Lambda),
#     deleting them here would break the other config's resources too.
#     Only pass this flag once you're sure nothing else shares the app_name.
#
# Safety:
#   - Prints exactly what it's about to delete and asks for confirmation,
#     unless --yes is passed (for CI / workflow_dispatch use).
#   - --dry-run prints the plan and exits without deleting anything.
#   - Every delete is idempotent: if a resource is already gone, it's
#     reported and skipped rather than erroring out.
#
set -euo pipefail

CONFIG_FILE="${1:?Usage: deprovision.sh <config.yaml> [--yes] [--with-iam-and-bucket] [--dry-run]}"
shift || true

ASSUME_YES=false
WITH_IAM_AND_BUCKET=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=true ;;
    --with-iam-and-bucket) WITH_IAM_AND_BUCKET=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  aws() { command aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
fi

CONFIG_JSON=$(python3 - "$CONFIG_FILE" <<'PY'
import sys, json, yaml
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f)))
PY
)

jqv() { echo "$CONFIG_JSON" | jq -r "$1"; }
jqv_or() { local v; v=$(jqv "$1"); [ "$v" = "null" ] && echo "$2" || echo "$v"; }

# ---------- Warn about the exact silent-YAML-duplicate-key footgun that
# usually causes people to reach for this script in the first place ----------
DUP_KEYS=$(python3 - "$CONFIG_FILE" <<'PY'
import sys, re
seen = {}
dupes = []
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^(\w[\w-]*):\s*$', line) or re.match(r'^(\w[\w-]*):\s+\S', line)
        if m and not line.startswith(' '):
            key = m.group(1)
            if key in seen:
                dupes.append(key)
            seen[key] = True
print(','.join(sorted(set(dupes))))
PY
)
if [ -n "$DUP_KEYS" ]; then
  echo "WARNING: $CONFIG_FILE has duplicate top-level key(s): $DUP_KEYS" >&2
  echo "         YAML silently keeps only the LAST occurrence of each - the resource" >&2
  echo "         names below reflect only what's actually being read, not everything" >&2
  echo "         visually present in the file. Fix the file to avoid confusion." >&2
  echo >&2
fi

AWS_REGION=$(jqv_or '.aws_region' "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_NAME=$(jqv '.app_name')
LAMBDA_NAME=$(jqv '.lambda.function_name')
QUEUE_NAME=$(jqv '.sqs.queue_name')
CB_PROJECT=$(jqv '.codebuild.project_name')
CP_NAME=$(jqv '.codepipeline.pipeline_name')
ARTIFACT_BUCKET=$(jqv_or '.codepipeline.artifact_bucket' "${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}")

LAMBDA_ROLE_NAME="${APP_NAME}-lambda-role"
CB_ROLE_NAME="${APP_NAME}-codebuild-role"
CP_ROLE_NAME="${APP_NAME}-codepipeline-role"

echo "=== Deprovision plan for: $CONFIG_FILE (app: $APP_NAME) ==="
echo "  CodePipeline:        $CP_NAME"
echo "  CodeBuild project:   $CB_PROJECT"
echo "  Lambda function:     $LAMBDA_NAME"
echo "  SQS queue:           $QUEUE_NAME"
echo "  (event source mapping between the two above will be removed first)"
if [ "$WITH_IAM_AND_BUCKET" = "true" ]; then
  echo "  --with-iam-and-bucket was passed, ALSO deleting:"
  echo "    IAM roles:         $LAMBDA_ROLE_NAME, $CB_ROLE_NAME, $CP_ROLE_NAME"
  echo "    S3 artifact bucket: $ARTIFACT_BUCKET (will be emptied first)"
else
  echo "  IAM roles and the S3 artifact bucket will be LEFT ALONE (pass"
  echo "  --with-iam-and-bucket to also remove them, once you're sure no"
  echo "  other config shares this app_name)."
fi
echo

if [ "$DRY_RUN" = "true" ]; then
  echo "--dry-run: nothing deleted."
  exit 0
fi

if [ "$ASSUME_YES" != "true" ]; then
  read -r -p "Type the app name (${APP_NAME}) to confirm deletion: " confirm
  if [ "$confirm" != "$APP_NAME" ]; then
    echo "Confirmation did not match. Aborting, nothing deleted." >&2
    exit 1
  fi
fi

# ---------- CodePipeline ----------
if aws codepipeline get-pipeline --name "$CP_NAME" >/dev/null 2>&1; then
  echo "Deleting CodePipeline: $CP_NAME"
  aws codepipeline delete-pipeline --name "$CP_NAME"
else
  echo "CodePipeline already gone: $CP_NAME"
fi

# ---------- CodeBuild project ----------
if aws codebuild batch-get-projects --names "$CB_PROJECT" \
    --query 'projects[0].name' --output text 2>/dev/null | grep -qx "$CB_PROJECT"; then
  echo "Deleting CodeBuild project: $CB_PROJECT"
  aws codebuild delete-project --name "$CB_PROJECT" >/dev/null
else
  echo "CodeBuild project already gone: $CB_PROJECT"
fi

# ---------- Event source mapping(s) for this queue + this function only ----------
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null || true)
if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
  QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text 2>/dev/null || true)
  if [ -n "$QUEUE_ARN" ] && [ "$QUEUE_ARN" != "None" ]; then
    UUIDS=$(aws lambda list-event-source-mappings \
      --function-name "$LAMBDA_NAME" --event-source-arn "$QUEUE_ARN" \
      --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true)
    for uuid in $UUIDS; do
      echo "Deleting event source mapping: $uuid"
      aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null
    done
  fi
fi

# ---------- Lambda function ----------
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  echo "Deleting Lambda: $LAMBDA_NAME"
  aws lambda delete-function --function-name "$LAMBDA_NAME" >/dev/null
else
  echo "Lambda already gone: $LAMBDA_NAME"
fi

# ---------- SQS queue ----------
if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
  echo "Deleting SQS queue: $QUEUE_NAME"
  aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null
else
  echo "SQS queue already gone: $QUEUE_NAME"
fi

# ---------- Optional: IAM roles + artifact bucket ----------
if [ "$WITH_IAM_AND_BUCKET" = "true" ]; then
  delete_role() {
    local role="$1"
    if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      echo "Deleting IAM role: $role"
      for policy in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
      done
      for policy_arn in $(aws iam list-attached-role-policies --role-name "$role" \
          --query 'AttachedPolicies[].PolicyArn' --output text); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn"
      done
      aws iam delete-role --role-name "$role"
    else
      echo "IAM role already gone: $role"
    fi
  }
  delete_role "$LAMBDA_ROLE_NAME"
  delete_role "$CB_ROLE_NAME"
  delete_role "$CP_ROLE_NAME"

  if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
    echo "Emptying and deleting S3 bucket: $ARTIFACT_BUCKET"
    aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive >/dev/null
    aws s3api delete-bucket --bucket "$ARTIFACT_BUCKET"
  else
    echo "S3 bucket already gone: $ARTIFACT_BUCKET"
  fi
fi

echo
echo "=== Done: $APP_NAME deprovisioned ==="
