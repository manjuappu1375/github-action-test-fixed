#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:?Usage: deprovision.sh <config.yaml> [flags]}"
shift || true

ASSUME_YES=false
WITH_IAM_AND_BUCKET=false
WITH_LAMBDA_LAYER=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=true ;;
    --with-iam-and-bucket) WITH_IAM_AND_BUCKET=true ;;
    --with-lambda-layer) WITH_LAMBDA_LAYER=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

[ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  aws() { command aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
fi

CONFIG_JSON=$(python3 - "$CONFIG_FILE" <<'PY'
import sys, json, yaml
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f) or {}))
PY
)

jqv() { echo "$CONFIG_JSON" | jq -r "$1"; }
jqv_or() { local v; v=$(jqv "$1"); [ "$v" = "null" ] && echo "$2" || echo "$v"; }

AWS_REGION=$(jqv_or '.aws_region' "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_NAME=$(jqv '.app_name')
LAMBDA_NAME=$(jqv '.lambda.function_name')
QUEUE_NAME=$(jqv '.sqs.queue_name')
CB_PROJECT=$(jqv '.codebuild.project_name')
CP_NAME=$(jqv '.codepipeline.pipeline_name')
ARTIFACT_BUCKET=$(jqv_or '.codepipeline.artifact_bucket' "${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}")

LAMBDA_ROLE_NAME="${LAMBDA_NAME}-role"
CB_ROLE_NAME="${LAMBDA_NAME}-codebuild-role"
CP_ROLE_NAME="${LAMBDA_NAME}-codepipeline-role"

LAYER_NAME=$(jqv_or '.lambda.layer.name' "")
LAYER_ARN=$(jqv_or '.lambda.layer.arn' "")
LAYER_MANAGED=$(jqv_or '.lambda.layer.managed' "false")
LAYER_ARN_NAME=""
LAYER_ARN_VERSION=""
if [ -n "$LAYER_ARN" ]; then
  LAYER_ARN_NAME=$(echo "$LAYER_ARN" | awk -F: '{print $(NF-1)}')
  LAYER_ARN_VERSION=$(echo "$LAYER_ARN" | awk -F: '{print $NF}')
fi

queue_url() {
  aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text 2>/dev/null || true
}

lambda_uses_layer_arn() {
  local target="$1" fn="$2"
  aws lambda get-function-configuration --function-name "$fn"     --query 'Layers[].Arn' --output text 2>/dev/null |
    tr '\t' '\n' | grep -Fxq "$target"
}

any_lambda_uses_layer_version() {
  local target="$1" functions fn
  functions=$(aws lambda list-functions --query 'Functions[].FunctionName' --output text 2>/dev/null || true)
  for fn in $functions; do
    if lambda_uses_layer_arn "$target" "$fn"; then
      echo "$fn"
      return 0
    fi
  done
  return 1
}

echo "=== Deprovision plan for ONE selected config ==="
echo "Config:              $CONFIG_FILE"
echo "App:                 $APP_NAME"
echo "Lambda:              $LAMBDA_NAME"
echo "SQS:                 $QUEUE_NAME"
echo "CodeBuild:           $CB_PROJECT"
echo "CodePipeline:        $CP_NAME"
echo "IAM role namespace:  $LAMBDA_NAME"

if [ "$WITH_LAMBDA_LAYER" = "true" ]; then
  if [ "$LAYER_MANAGED" != "true" ]; then
    echo "Layer deletion:      BLOCKED (lambda.layer.managed is not true)"
  elif [ -n "$LAYER_ARN" ]; then
    echo "Layer deletion:      exact version $LAYER_ARN"
  elif [ -n "$LAYER_NAME" ]; then
    echo "Layer deletion:      only unused versions of $LAYER_NAME"
  else
    echo "Layer deletion:      none configured"
  fi
else
  echo "Layer deletion:      no"
fi

echo "IAM/bucket deletion: $WITH_IAM_AND_BUCKET"
echo

[ "$DRY_RUN" = "true" ] && { echo "--dry-run: nothing deleted."; exit 0; }

if [ "$ASSUME_YES" != "true" ]; then
  read -r -p "Type the app name (${APP_NAME}) to confirm deletion: " confirm
  [ "$confirm" = "$APP_NAME" ] || { echo "Confirmation did not match. Aborting." >&2; exit 1; }
fi

if aws codepipeline get-pipeline --name "$CP_NAME" >/dev/null 2>&1; then
  echo "Deleting CodePipeline: $CP_NAME"
  aws codepipeline delete-pipeline --name "$CP_NAME"
else
  echo "CodePipeline already gone: $CP_NAME"
fi

if aws codebuild batch-get-projects --names "$CB_PROJECT" --query 'projects[0].name' --output text 2>/dev/null | grep -qx "$CB_PROJECT"; then
  echo "Deleting CodeBuild project: $CB_PROJECT"
  aws codebuild delete-project --name "$CB_PROJECT" >/dev/null
else
  echo "CodeBuild already gone: $CB_PROJECT"
fi

QUEUE_URL=$(queue_url)
if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
  QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text 2>/dev/null || true)
  if [ -n "$QUEUE_ARN" ] && [ "$QUEUE_ARN" != "None" ]; then
    UUIDS=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" --event-source-arn "$QUEUE_ARN" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true)
    for uuid in $UUIDS; do
      [ -z "$uuid" ] || [ "$uuid" = "None" ] && continue
      echo "Deleting ONLY this Lambda/queue mapping: $uuid"
      aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null
    done
  fi
fi

if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  echo "Deleting ONLY Lambda: $LAMBDA_NAME"
  aws lambda delete-function --function-name "$LAMBDA_NAME" >/dev/null
else
  echo "Lambda already gone: $LAMBDA_NAME"
fi

if [ "$WITH_LAMBDA_LAYER" = "true" ]; then
  if [ "$LAYER_MANAGED" != "true" ]; then
    echo "Layer deletion skipped: lambda.layer.managed is not true."
  elif [ -n "$LAYER_ARN" ]; then
    consumer=$(any_lambda_uses_layer_version "$LAYER_ARN" || true)
    if [ -n "$consumer" ]; then
      echo "Keeping layer version; still used by $consumer: $LAYER_ARN"
    else
      echo "Deleting exact layer version: $LAYER_ARN"
      aws lambda delete-layer-version --layer-name "$LAYER_ARN_NAME" --version-number "$LAYER_ARN_VERSION" >/dev/null 2>&1 || true
    fi
  elif [ -n "$LAYER_NAME" ]; then
    versions=$(aws lambda list-layer-versions --layer-name "$LAYER_NAME" --query 'Versions[].{Arn:LayerVersionArn,Version:Version}' --output text 2>/dev/null || true)
    while read -r arn version; do
      [ -z "$arn" ] || [ "$arn" = "None" ] && continue
      consumer=$(any_lambda_uses_layer_version "$arn" || true)
      if [ -n "$consumer" ]; then
        echo "Keeping layer version $version; still used by $consumer"
      else
        echo "Deleting unused layer version $version of $LAYER_NAME"
        aws lambda delete-layer-version --layer-name "$LAYER_NAME" --version-number "$version" >/dev/null 2>&1 || true
      fi
    done <<< "$versions"
  fi
fi

if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
  echo "Deleting ONLY SQS queue: $QUEUE_NAME"
  aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null
else
  echo "SQS already gone: $QUEUE_NAME"
fi

if [ "$WITH_IAM_AND_BUCKET" = "true" ]; then
  delete_role() {
    local role="$1"
    if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      echo "Deleting IAM role: $role"
      policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null || true)
      for policy in $policies; do
        [ -z "$policy" ] || [ "$policy" = "None" ] && continue
        aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
      done
      attached=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
      for policy_arn in $attached; do
        [ -z "$policy_arn" ] || [ "$policy_arn" = "None" ] && continue
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
    aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive >/dev/null || true
    aws s3api delete-bucket --bucket "$ARTIFACT_BUCKET"
  else
    echo "S3 bucket already gone: $ARTIFACT_BUCKET"
  fi
fi

echo
echo "=== Done: ONLY $APP_NAME resources from $CONFIG_FILE were deprovisioned ==="
