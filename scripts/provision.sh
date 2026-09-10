#!/usr/bin/env bash
#
# provision.sh <path/to/config.yaml>
#
# Reads an app config YAML and creates/updates, idempotently, via the AWS
# CLI only (no Terraform/CDK/CloudFormation/Pulumi):
#   - IAM roles (Lambda execution, CodeBuild service, CodePipeline service)
#   - SQS queue
#   - Lambda function + SQS event source mapping
#   - CodeBuild project
#   - S3 artifact bucket
#   - CodePipeline (Source: CodeStarSourceConnection -> Build: CodeBuild)
#
set -euo pipefail

CONFIG_FILE="${1:?Usage: provision.sh <config.yaml>}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

echo "=== Loading config: $CONFIG_FILE ==="

# If AWS_ENDPOINT_URL is set (e.g. http://localhost:4566 for LocalStack, or
# a moto server for testing), route every `aws` call in this script to it.
# Defined as a shell function rather than relying on the AWS CLI's own
# AWS_ENDPOINT_URL support, since that's a v2.13+-only feature and this
# works identically on any CLI version.
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

# If AWS_ENDPOINT_URL is set (e.g. http://localhost:4566 for LocalStack),
# every AWS CLI call in this script automatically targets it - no code
# changes needed, just environment. Requires aws-cli >= 2.13.
#
# SKIP_CODE_SERVICES=true skips CodeBuild/CodePipeline provisioning. Use
# this for LocalStack testing, since CodeBuild and CodePipeline are
# LocalStack Pro (paid) features not available in the free/community image.
SKIP_CODE_SERVICES="${SKIP_CODE_SERVICES:-false}"

# ---------- Config values ----------
AWS_REGION=$(jqv_or '.aws_region' "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_NAME=$(jqv '.app_name')

LAMBDA_NAME=$(jqv '.lambda.function_name')
LAMBDA_RUNTIME=$(jqv '.lambda.runtime')
LAMBDA_HANDLER=$(jqv '.lambda.handler')
LAMBDA_MEMORY=$(jqv_or '.lambda.memory_size' "128")
LAMBDA_TIMEOUT=$(jqv_or '.lambda.timeout' "30")
LAMBDA_SRC_DIR=$(jqv_or '.lambda.source_dir' "src")

QUEUE_NAME=$(jqv '.sqs.queue_name')
VISIBILITY_TIMEOUT=$(jqv_or '.sqs.visibility_timeout' "30")

CB_PROJECT=$(jqv '.codebuild.project_name')
CB_BUILDSPEC=$(jqv_or '.codebuild.buildspec' "buildspec.yml")
CB_IMAGE=$(jqv_or '.codebuild.image' "aws/codebuild/amazonlinux2-x86_64-standard:5.0")
CB_COMPUTE=$(jqv_or '.codebuild.compute_type' "BUILD_GENERAL1_SMALL")

CP_NAME=$(jqv '.codepipeline.pipeline_name')
GH_OWNER=$(jqv '.codepipeline.github_owner')
GH_REPO=$(jqv '.codepipeline.github_repo')
GH_BRANCH=$(jqv_or '.codepipeline.github_branch' "main")
CONNECTION_ARN=$(jqv_or '.codepipeline.connection_arn' "")
ARTIFACT_BUCKET=$(jqv_or '.codepipeline.artifact_bucket' "${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}")

LAMBDA_ROLE_NAME="${APP_NAME}-lambda-role"
CB_ROLE_NAME="${APP_NAME}-codebuild-role"
CP_ROLE_NAME="${APP_NAME}-codepipeline-role"

echo "App: $APP_NAME | Region: $AWS_REGION | Account: $ACCOUNT_ID"

# ---------- Fail fast on obviously-unfinished config ----------
# These would otherwise surface as confusing AWS API errors much later
# (mid-way through provisioning, after other resources already changed).
if [ "$SKIP_CODE_SERVICES" != "true" ]; then
  if [ -z "$CONNECTION_ARN" ] || [[ "$CONNECTION_ARN" == *REPLACE-ME* ]]; then
    echo "ERROR: codepipeline.connection_arn in $CONFIG_FILE is empty or still a placeholder." >&2
    echo "       Authorize a CodeStar Connection to GitHub in the AWS console first (see README)," >&2
    echo "       then put its real ARN in the config." >&2
    exit 1
  fi
  if [ "$GH_OWNER" = "your-github-org" ] || [ "$GH_REPO" = "your-repo-name" ]; then
    echo "ERROR: codepipeline.github_owner/github_repo in $CONFIG_FILE are still placeholders." >&2
    echo "       Set them to the real GitHub org/repo this pipeline should pull from." >&2
    exit 1
  fi
fi

# ---------- Helpers ----------
role_arn_if_exists() {
  aws iam get-role --role-name "$1" --query 'Role.Arn' --output text 2>/dev/null || true
}

wait_for_role_propagation() {
  echo "Waiting for IAM role propagation..." >&2
  sleep 10
}

# A freshly created/updated IAM role can take anywhere from a few seconds to
# ~30-60s to actually be usable by Lambda/CodeBuild/CodePipeline, even after
# the fixed sleep above. Rather than guessing a "safe enough" sleep, retry
# the AWS call itself with backoff whenever it fails with one of the
# well-known role-propagation error signatures, and only bail out for
# anything else.
run_with_role_retry() {
  local max_attempts=8 attempt=1 delay=5 output rc
  while :; do
    if output=$("$@" 2>&1); then
      [ -n "$output" ] && printf '%s\n' "$output"
      return 0
    fi
    rc=$?
    if echo "$output" | grep -qiE \
      "cannot be assumed by (Lambda|CodeBuild|CodePipeline)|is not authorized to perform|InvalidParameterValueException.*[Rr]ole" \
      && [ "$attempt" -lt "$max_attempts" ]; then
      echo "  ...role not propagated yet (attempt ${attempt}/${max_attempts}), retrying in ${delay}s" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      delay=$((delay * 2))
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$rc"
  done
}

# ---------- SQS ----------
ensure_sqs_queue() {
  local url
  url=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null || true)
  if [ -z "$url" ]; then
    echo "Creating SQS queue: $QUEUE_NAME" >&2
    url=$(aws sqs create-queue \
      --queue-name "$QUEUE_NAME" \
      --attributes "VisibilityTimeout=${VISIBILITY_TIMEOUT}" \
      --query 'QueueUrl' --output text)
  else
    echo "SQS queue already exists: $QUEUE_NAME" >&2
    aws sqs set-queue-attributes \
      --queue-url "$url" \
      --attributes "VisibilityTimeout=${VISIBILITY_TIMEOUT}" >/dev/null
  fi
  echo "$url"
}

sqs_arn_from_url() {
  aws sqs get-queue-attributes \
    --queue-url "$1" --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text
}

# ---------- Lambda execution role ----------
ensure_lambda_role() {
  local arn
  arn=$(role_arn_if_exists "$LAMBDA_ROLE_NAME")
  if [ -z "$arn" ]; then
    echo "Creating IAM role: $LAMBDA_ROLE_NAME" >&2
    arn=$(aws iam create-role \
      --role-name "$LAMBDA_ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "lambda.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' --query 'Role.Arn' --output text)
    aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    wait_for_role_propagation
  else
    echo "IAM role already exists: $LAMBDA_ROLE_NAME" >&2
  fi

  # Scope SQS access to just this queue instead of a broad managed policy.
  aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "${APP_NAME}-sqs-access" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": [\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],
        \"Resource\": \"arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${QUEUE_NAME}\"
      }]
    }" >/dev/null

  echo "$arn"
}

# ---------- Lambda function ----------
package_lambda() {
  if [ ! -d "$LAMBDA_SRC_DIR" ]; then
    echo "ERROR: lambda.source_dir '$LAMBDA_SRC_DIR' does not exist (relative to repo root)." >&2
    exit 1
  fi
  local zip_path="/tmp/${LAMBDA_NAME}.zip"
  rm -f "$zip_path"
  (cd "$LAMBDA_SRC_DIR" && zip -r -q "$zip_path" .)
  echo "$zip_path"
}

deploy_lambda() {
  local role_arn="$1" zip_path="$2" queue_url="$3"

  if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
    echo "Updating existing Lambda: $LAMBDA_NAME"
    aws lambda update-function-code \
      --function-name "$LAMBDA_NAME" \
      --zip-file "fileb://${zip_path}" >/dev/null
    aws lambda wait function-updated --function-name "$LAMBDA_NAME"

    aws lambda update-function-configuration \
      --function-name "$LAMBDA_NAME" \
      --runtime "$LAMBDA_RUNTIME" \
      --handler "$LAMBDA_HANDLER" \
      --memory-size "$LAMBDA_MEMORY" \
      --timeout "$LAMBDA_TIMEOUT" \
      --environment "Variables={QUEUE_URL=${queue_url}}" >/dev/null
    aws lambda wait function-updated --function-name "$LAMBDA_NAME"
  else
    echo "Creating Lambda: $LAMBDA_NAME"
    run_with_role_retry aws lambda create-function \
      --function-name "$LAMBDA_NAME" \
      --runtime "$LAMBDA_RUNTIME" \
      --role "$role_arn" \
      --handler "$LAMBDA_HANDLER" \
      --memory-size "$LAMBDA_MEMORY" \
      --timeout "$LAMBDA_TIMEOUT" \
      --zip-file "fileb://${zip_path}" \
      --environment "Variables={QUEUE_URL=${queue_url}}" >/dev/null
    aws lambda wait function-active --function-name "$LAMBDA_NAME"
  fi
}

ensure_event_source_mapping() {
  local queue_arn="$1"
  local existing
  existing=$(aws lambda list-event-source-mappings \
    --function-name "$LAMBDA_NAME" \
    --event-source-arn "$queue_arn" \
    --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)

  if [ -z "$existing" ] || [ "$existing" = "None" ]; then
    echo "Wiring SQS -> Lambda event source mapping"
    aws lambda create-event-source-mapping \
      --function-name "$LAMBDA_NAME" \
      --event-source-arn "$queue_arn" \
      --batch-size 10 >/dev/null
  else
    echo "Event source mapping already exists"
  fi
}

# ---------- Artifact bucket ----------
ensure_artifact_bucket() {
  if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
    echo "Artifact bucket already exists: $ARTIFACT_BUCKET"
  else
    echo "Creating artifact bucket: $ARTIFACT_BUCKET"
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi
    aws s3api put-bucket-encryption --bucket "$ARTIFACT_BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
    aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  fi
}

# ---------- CodeBuild role + project ----------
ensure_codebuild_role() {
  local arn
  arn=$(role_arn_if_exists "$CB_ROLE_NAME")
  if [ -z "$arn" ]; then
    echo "Creating IAM role: $CB_ROLE_NAME" >&2
    arn=$(aws iam create-role \
      --role-name "$CB_ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "codebuild.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' --query 'Role.Arn' --output text)
    wait_for_role_propagation
  else
    echo "IAM role already exists: $CB_ROLE_NAME" >&2
  fi

  aws iam put-role-policy --role-name "$CB_ROLE_NAME" \
    --policy-name "${APP_NAME}-codebuild-policy" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
          \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/codebuild/${CB_PROJECT}*\"
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\",\"s3:GetObjectVersion\",\"s3:PutObject\"],
          \"Resource\": \"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"lambda:UpdateFunctionCode\",\"lambda:GetFunction\"],
          \"Resource\": \"arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}\"
        }
      ]
    }" >/dev/null

  echo "$arn"
}

ensure_codebuild_project() {
  local role_arn="$1"
  local env_vars="[{name=LAMBDA_NAME,value=${LAMBDA_NAME}},{name=LAMBDA_SRC_DIR,value=${LAMBDA_SRC_DIR}}]"

  if aws codebuild batch-get-projects --names "$CB_PROJECT" \
      --query 'projects[0].name' --output text 2>/dev/null | grep -qx "$CB_PROJECT"; then
    echo "Updating CodeBuild project: $CB_PROJECT"
    run_with_role_retry aws codebuild update-project \
      --name "$CB_PROJECT" \
      --source "type=CODEPIPELINE,buildspec=${CB_BUILDSPEC}" \
      --artifacts "type=CODEPIPELINE" \
      --environment "type=LINUX_CONTAINER,image=${CB_IMAGE},computeType=${CB_COMPUTE},environmentVariables=${env_vars}" \
      --service-role "$role_arn" >/dev/null
  else
    echo "Creating CodeBuild project: $CB_PROJECT"
    run_with_role_retry aws codebuild create-project \
      --name "$CB_PROJECT" \
      --source "type=CODEPIPELINE,buildspec=${CB_BUILDSPEC}" \
      --artifacts "type=CODEPIPELINE" \
      --environment "type=LINUX_CONTAINER,image=${CB_IMAGE},computeType=${CB_COMPUTE},environmentVariables=${env_vars}" \
      --service-role "$role_arn" >/dev/null
  fi
}

# ---------- CodePipeline role + pipeline ----------
ensure_codepipeline_role() {
  local arn
  arn=$(role_arn_if_exists "$CP_ROLE_NAME")
  if [ -z "$arn" ]; then
    echo "Creating IAM role: $CP_ROLE_NAME" >&2
    arn=$(aws iam create-role \
      --role-name "$CP_ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "codepipeline.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' --query 'Role.Arn' --output text)
    wait_for_role_propagation
  else
    echo "IAM role already exists: $CP_ROLE_NAME" >&2
  fi

  # AWS renamed "CodeStar Connections" to "CodeConnections" in 2024. Connections
  # created via the console now get an arn:aws:codeconnections:... ARN instead of
  # the old arn:aws:codestar-connections:... one. Both IAM action prefixes are
  # granted here (harmless if your connection ARN happens to be the old style),
  # plus GetConnectionToken/GetConnection which CodePipeline needs alongside
  # UseConnection but is easy to miss and not obvious from the error you'd get
  # without it.
  aws iam put-role-policy --role-name "$CP_ROLE_NAME" \
    --policy-name "${APP_NAME}-codepipeline-policy" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\",\"s3:GetObjectVersion\",\"s3:PutObject\",\"s3:GetBucketVersioning\"],
          \"Resource\": [\"arn:aws:s3:::${ARTIFACT_BUCKET}\",\"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"]
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"codebuild:BatchGetBuilds\",\"codebuild:StartBuild\"],
          \"Resource\": \"arn:aws:codebuild:${AWS_REGION}:${ACCOUNT_ID}:project/${CB_PROJECT}\"
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"codestar-connections:UseConnection\",
            \"codestar-connections:GetConnectionToken\",
            \"codestar-connections:GetConnection\",
            \"codeconnections:UseConnection\",
            \"codeconnections:GetConnectionToken\",
            \"codeconnections:GetConnection\"
          ],
          \"Resource\": \"${CONNECTION_ARN}\"
        }
      ]
    }" >/dev/null

  echo "$arn"
}

ensure_codepipeline() {
  local role_arn="$1"
  local pipeline_def
  pipeline_def=$(cat <<JSON
{
  "pipeline": {
    "name": "${CP_NAME}",
    "roleArn": "${role_arn}",
    "artifactStore": {"type": "S3", "location": "${ARTIFACT_BUCKET}"},
    "stages": [
      {
        "name": "Source",
        "actions": [{
          "name": "Source",
          "actionTypeId": {"category": "Source", "owner": "AWS", "provider": "CodeStarSourceConnection", "version": "1"},
          "outputArtifacts": [{"name": "SourceOutput"}],
          "configuration": {
            "ConnectionArn": "${CONNECTION_ARN}",
            "FullRepositoryId": "${GH_OWNER}/${GH_REPO}",
            "BranchName": "${GH_BRANCH}"
          }
        }]
      },
      {
        "name": "Build",
        "actions": [{
          "name": "BuildAndDeployLambda",
          "actionTypeId": {"category": "Build", "owner": "AWS", "provider": "CodeBuild", "version": "1"},
          "inputArtifacts": [{"name": "SourceOutput"}],
          "outputArtifacts": [{"name": "BuildOutput"}],
          "configuration": {"ProjectName": "${CB_PROJECT}"}
        }]
      }
    ]
  }
}
JSON
)

  # aws codepipeline ... --cli-input-json file:///dev/stdin doesn't play well
  # inside run_with_role_retry's command substitution (stdin gets consumed on
  # the first attempt), so write the definition to a real temp file instead.
  local pipeline_file
  pipeline_file=$(mktemp)
  printf '%s' "$pipeline_def" > "$pipeline_file"

  if aws codepipeline get-pipeline --name "$CP_NAME" >/dev/null 2>&1; then
    echo "Updating CodePipeline: $CP_NAME"
    run_with_role_retry aws codepipeline update-pipeline \
      --cli-input-json "file://${pipeline_file}" >/dev/null
  else
    echo "Creating CodePipeline: $CP_NAME"
    run_with_role_retry aws codepipeline create-pipeline \
      --cli-input-json "file://${pipeline_file}" >/dev/null
  fi
  rm -f "$pipeline_file"
}

# ---------- Run ----------
QUEUE_URL=$(ensure_sqs_queue)
QUEUE_ARN=$(sqs_arn_from_url "$QUEUE_URL")

LAMBDA_ROLE_ARN=$(ensure_lambda_role)
ZIP_PATH=$(package_lambda)
deploy_lambda "$LAMBDA_ROLE_ARN" "$ZIP_PATH" "$QUEUE_URL"
ensure_event_source_mapping "$QUEUE_ARN"

ensure_artifact_bucket

if [ "$SKIP_CODE_SERVICES" = "true" ]; then
  echo "SKIP_CODE_SERVICES=true - skipping CodeBuild and CodePipeline"
  echo "(these aren't emulated by LocalStack's free/community edition)"
  CB_PROJECT="(skipped)"
  CP_NAME="(skipped)"
else
  CB_ROLE_ARN=$(ensure_codebuild_role)
  ensure_codebuild_project "$CB_ROLE_ARN"

  CP_ROLE_ARN=$(ensure_codepipeline_role)
  ensure_codepipeline "$CP_ROLE_ARN"
fi

echo "=== Done: $APP_NAME provisioned ==="
echo "Lambda:       $LAMBDA_NAME"
echo "SQS Queue:    $QUEUE_URL"
echo "CodeBuild:    $CB_PROJECT"
echo "CodePipeline: $CP_NAME"