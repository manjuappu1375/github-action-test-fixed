#!/usr/bin/env bash
#
# provision.sh <path/to/config.yaml>
#
# Reads an app config YAML and creates/updates, idempotently, via the AWS
# CLI only (no Terraform/CDK/CloudFormation/Pulumi):
#   - IAM roles (Lambda execution, CodeBuild service, CodePipeline service)
#   - SQS queue
#   - Lambda function + SQS event source mapping
#   - Optional Lambda Layer
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

# If AWS_ENDPOINT_URL is set (e.g. http://localhost:4566 for LocalStack,
# or a moto server for testing), route every aws call to it.
if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  aws() {
    command aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"
  }
fi

# ---------- YAML -> JSON ----------
CONFIG_JSON=$(python3 - "$CONFIG_FILE" <<'PY'
import sys
import json
import yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

print(json.dumps(data))
PY
)

jqv() {
  echo "$CONFIG_JSON" | jq -r "$1"
}

jqv_or() {
  local v
  v=$(jqv "$1")
  [ "$v" = "null" ] && echo "$2" || echo "$v"
}

# LocalStack / test configuration.
SKIP_CODE_SERVICES="${SKIP_CODE_SERVICES:-false}"

# ---------- Config values ----------

AWS_REGION=$(jqv_or '.aws_region' "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_NAME=$(jqv '.app_name')

# ---------- Lambda ----------

LAMBDA_NAME=$(jqv '.lambda.function_name')
LAMBDA_RUNTIME=$(jqv '.lambda.runtime')
LAMBDA_HANDLER=$(jqv '.lambda.handler')
LAMBDA_MEMORY=$(jqv_or '.lambda.memory_size' "128")
LAMBDA_TIMEOUT=$(jqv_or '.lambda.timeout' "30")
LAMBDA_SRC_DIR=$(jqv_or '.lambda.source_dir' "src")

# ---------- Optional Lambda Layer ----------
#
# Example:
#
# lambda:
#   layer:
#     name: my-deps-layer
#     source_dir: lambda-layer
#     compatible_runtimes: [python3.12]
#     description: "Shared dependencies"
#
# Optional existing layers:
#
# lambda:
#   layers:
#     - arn:aws:lambda:us-east-1:123456789012:layer:some-layer:3

LAYER_NAME=$(jqv_or '.lambda.layer.name' "")
LAYER_SRC_DIR=$(jqv_or '.lambda.layer.source_dir' "")
LAYER_DESC=$(jqv_or '.lambda.layer.description' "Layer for ${APP_NAME}")

LAYER_RUNTIMES=$(
  echo "$CONFIG_JSON" |
    jq -r '.lambda.layer.compatible_runtimes[]? // empty'
)

if [ -z "$LAYER_RUNTIMES" ]; then
  LAYER_RUNTIMES="$LAMBDA_RUNTIME"
fi

# Read existing layer ARNs.
#
# IMPORTANT:
# Do not allow jq's null/missing output to become an empty array element.
mapfile -t EXTRA_LAYER_ARNS < <(
  echo "$CONFIG_JSON" |
    jq -r '.lambda.layers[]? // empty' |
    awk 'NF'
)

# ---------- SQS ----------

QUEUE_NAME=$(jqv '.sqs.queue_name')
VISIBILITY_TIMEOUT=$(jqv_or '.sqs.visibility_timeout' "30")

# ---------- CodeBuild ----------

CB_PROJECT=$(jqv '.codebuild.project_name')
CB_BUILDSPEC=$(jqv_or '.codebuild.buildspec' "buildspec.yml")
CB_IMAGE=$(jqv_or '.codebuild.image' "aws/codebuild/amazonlinux2-x86_64-standard:5.0")
CB_COMPUTE=$(jqv_or '.codebuild.compute_type' "BUILD_GENERAL1_SMALL")

# ---------- CodePipeline ----------

CP_NAME=$(jqv '.codepipeline.pipeline_name')
GH_OWNER=$(jqv '.codepipeline.github_owner')
GH_REPO=$(jqv '.codepipeline.github_repo')
GH_BRANCH=$(jqv_or '.codepipeline.github_branch' "main")
CONNECTION_ARN=$(jqv_or '.codepipeline.connection_arn' "")

ARTIFACT_BUCKET=$(
  jqv_or \
    '.codepipeline.artifact_bucket' \
    "${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}"
)

# ---------- IAM role names ----------

LAMBDA_ROLE_NAME="${APP_NAME}-lambda-role"
CB_ROLE_NAME="${APP_NAME}-codebuild-role"
CP_ROLE_NAME="${APP_NAME}-codepipeline-role"

echo "App: $APP_NAME | Region: $AWS_REGION | Account: $ACCOUNT_ID"

# ---------- Fail-fast validation ----------

if [ "$SKIP_CODE_SERVICES" != "true" ]; then

  if [ -z "$CONNECTION_ARN" ] ||
     [[ "$CONNECTION_ARN" == *REPLACE-ME* ]]; then

    echo "ERROR: codepipeline.connection_arn in $CONFIG_FILE is empty or still a placeholder." >&2
    echo "       Authorize a CodeStar/CodeConnections connection to GitHub first." >&2
    echo "       Then put its real ARN in the config." >&2
    exit 1
  fi

  if [ "$GH_OWNER" = "your-github-org" ] ||
     [ "$GH_REPO" = "your-repo-name" ]; then

    echo "ERROR: codepipeline.github_owner/github_repo in $CONFIG_FILE are still placeholders." >&2
    echo "       Set them to the real GitHub repository." >&2
    exit 1
  fi
fi

# ---------- Helpers ----------

role_arn_if_exists() {
  aws iam get-role \
    --role-name "$1" \
    --query 'Role.Arn' \
    --output text \
    2>/dev/null || true
}

wait_for_role_propagation() {
  echo "Waiting for IAM role propagation..." >&2
  sleep 10
}

# Retry only when AWS reports a service-role propagation problem.
run_with_role_retry() {
  local max_attempts=8
  local attempt=1
  local delay=5
  local output
  local rc

  while :; do

    if output=$("$@" 2>&1); then
      [ -n "$output" ] && printf '%s\n' "$output"
      return 0
    fi

    rc=$?

    if echo "$output" |
      grep -qiE \
        "cannot be assumed by (Lambda|CodeBuild|CodePipeline)|InvalidParameterValueException.*[Rr]ole|InvalidStructureException.*[Rr]ole" &&
      [ "$attempt" -lt "$max_attempts" ]; then

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

# ============================================================
# SQS
# ============================================================

ensure_sqs_queue() {
  local url

  url=$(
    aws sqs get-queue-url \
      --queue-name "$QUEUE_NAME" \
      --query 'QueueUrl' \
      --output text \
      2>/dev/null || true
  )

  if [ -z "$url" ] || [ "$url" = "None" ]; then

    echo "Creating SQS queue: $QUEUE_NAME" >&2

    url=$(
      aws sqs create-queue \
        --queue-name "$QUEUE_NAME" \
        --attributes "VisibilityTimeout=${VISIBILITY_TIMEOUT}" \
        --query 'QueueUrl' \
        --output text
    )

  else

    echo "SQS queue already exists: $QUEUE_NAME" >&2

    aws sqs set-queue-attributes \
      --queue-url "$url" \
      --attributes "VisibilityTimeout=${VISIBILITY_TIMEOUT}" \
      >/dev/null
  fi

  echo "$url"
}

sqs_arn_from_url() {
  aws sqs get-queue-attributes \
    --queue-url "$1" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text
}

# ============================================================
# Lambda execution role
# ============================================================

ensure_lambda_role() {
  local arn

  arn=$(role_arn_if_exists "$LAMBDA_ROLE_NAME")

  if [ -z "$arn" ] || [ "$arn" = "None" ]; then

    echo "Creating IAM role: $LAMBDA_ROLE_NAME" >&2

    arn=$(
      aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {
              "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }]
        }' \
        --query 'Role.Arn' \
        --output text
    )

    aws iam attach-role-policy \
      --role-name "$LAMBDA_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

    wait_for_role_propagation

  else

    echo "IAM role already exists: $LAMBDA_ROLE_NAME" >&2

  fi

  # Allow Lambda to consume this specific SQS queue.
  aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "${APP_NAME}-sqs-access" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": [
          \"sqs:ReceiveMessage\",
          \"sqs:DeleteMessage\",
          \"sqs:GetQueueAttributes\"
        ],
        \"Resource\": \"arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${QUEUE_NAME}\"
      }]
    }" \
    >/dev/null

  echo "$arn"
}

# ============================================================
# Lambda package
# ============================================================

package_lambda() {

  if [ ! -d "$LAMBDA_SRC_DIR" ]; then

    echo "ERROR: lambda.source_dir '$LAMBDA_SRC_DIR' does not exist (relative to repo root)." >&2

    exit 1
  fi

  local zip_path="/tmp/${LAMBDA_NAME}.zip"

  rm -f "$zip_path"

  (
    cd "$LAMBDA_SRC_DIR"
    zip -r -q "$zip_path" .
  )

  echo "$zip_path"
}

# ============================================================
# Lambda Layer
# ============================================================

ensure_lambda_layer() {

  # No layer configured.
  #
  # IMPORTANT:
  # Return successfully without printing anything.
  [ -z "$LAYER_NAME" ] && return 0

  if [ ! -d "$LAYER_SRC_DIR" ]; then

    echo "ERROR: lambda.layer.source_dir '$LAYER_SRC_DIR' does not exist (relative to repo root)." >&2

    exit 1
  fi

  local zip_path="/tmp/${LAYER_NAME}-layer.zip"

  rm -f "$zip_path"

  (
    cd "$LAYER_SRC_DIR"
    zip -r -q "$zip_path" .
  )

  echo "Publishing Lambda layer version: $LAYER_NAME" >&2
  echo "Compatible runtimes: $LAYER_RUNTIMES" >&2

  aws lambda publish-layer-version \
    --layer-name "$LAYER_NAME" \
    --description "$LAYER_DESC" \
    --zip-file "fileb://${zip_path}" \
    --compatible-runtimes $LAYER_RUNTIMES \
    --query 'LayerVersionArn' \
    --output text
}

# ============================================================
# Lambda deployment
# ============================================================

deploy_lambda() {

  local role_arn="$1"
  local zip_path="$2"
  local queue_url="$3"
  local built_layer_arn="$4"

  # ----------------------------------------------------------
  # Build a clean list of layer ARNs.
  # ----------------------------------------------------------

  local layer_arns=()
  local layers_args=()

  # Add newly-created layer only if a real ARN exists.
  if [ -n "$built_layer_arn" ] &&
     [ "$built_layer_arn" != "None" ]; then

    layer_arns+=("$built_layer_arn")
  fi

  # Add existing layer ARNs from configuration.
  for arn in "${EXTRA_LAYER_ARNS[@]}"; do

    if [ -n "$arn" ] &&
       [ "$arn" != "None" ]; then

      layer_arns+=("$arn")
    fi

  done

  # ----------------------------------------------------------
  # IMPORTANT FIX
  #
  # Only create --layers when at least one real ARN exists.
  #
  # For example-app.yaml:
  #
  #   layer_arns=()
  #   layers_args=()
  #
  # Therefore AWS receives NO --layers argument.
  #
  # This prevents:
  #
  #   Invalid length for parameter Layers[0], value: 0
  # ----------------------------------------------------------

  if [ "${#layer_arns[@]}" -gt 0 ]; then

    layers_args=(--layers "${layer_arns[@]}")

    echo "Lambda layer count: ${#layer_arns[@]}"

    for arn in "${layer_arns[@]}"; do
      echo "Lambda layer: $arn"
    done

  else

    echo "Lambda layers: none"

  fi

  # ----------------------------------------------------------
  # Existing Lambda
  # ----------------------------------------------------------

  if aws lambda get-function \
    --function-name "$LAMBDA_NAME" \
    >/dev/null 2>&1; then

    echo "Updating existing Lambda: $LAMBDA_NAME"

    aws lambda update-function-code \
      --function-name "$LAMBDA_NAME" \
      --zip-file "fileb://${zip_path}" \
      >/dev/null

    aws lambda wait function-updated \
      --function-name "$LAMBDA_NAME"

    # IMPORTANT:
    #
    # If there are no layers, do not pass --layers.
    #

    if [ "${#layer_arns[@]}" -gt 0 ]; then

      aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --runtime "$LAMBDA_RUNTIME" \
        --handler "$LAMBDA_HANDLER" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --environment "Variables={QUEUE_URL=${queue_url}}" \
        "${layers_args[@]}" \
        >/dev/null

    else

      aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --runtime "$LAMBDA_RUNTIME" \
        --handler "$LAMBDA_HANDLER" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --environment "Variables={QUEUE_URL=${queue_url}}" \
        >/dev/null

    fi

    aws lambda wait function-updated \
      --function-name "$LAMBDA_NAME"

  # ----------------------------------------------------------
  # New Lambda
  # ----------------------------------------------------------

  else

    echo "Creating Lambda: $LAMBDA_NAME"

    # IMPORTANT:
    #
    # Separate the two cases instead of relying on an empty
    # Bash array at the end of the AWS command.
    #

    if [ "${#layer_arns[@]}" -gt 0 ]; then

      run_with_role_retry aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime "$LAMBDA_RUNTIME" \
        --role "$role_arn" \
        --handler "$LAMBDA_HANDLER" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --zip-file "fileb://${zip_path}" \
        --environment "Variables={QUEUE_URL=${queue_url}}" \
        "${layers_args[@]}" \
        >/dev/null

    else

      run_with_role_retry aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime "$LAMBDA_RUNTIME" \
        --role "$role_arn" \
        --handler "$LAMBDA_HANDLER" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --zip-file "fileb://${zip_path}" \
        --environment "Variables={QUEUE_URL=${queue_url}}" \
        >/dev/null

    fi

    aws lambda wait function-active \
      --function-name "$LAMBDA_NAME"

  fi
}

# ============================================================
# SQS -> Lambda event source mapping
# ============================================================

ensure_event_source_mapping() {

  local queue_arn="$1"
  local existing

  existing=$(
    aws lambda list-event-source-mappings \
      --function-name "$LAMBDA_NAME" \
      --event-source-arn "$queue_arn" \
      --query 'EventSourceMappings[0].UUID' \
      --output text \
      2>/dev/null || true
  )

  if [ -z "$existing" ] ||
     [ "$existing" = "None" ]; then

    echo "Wiring SQS -> Lambda event source mapping"

    aws lambda create-event-source-mapping \
      --function-name "$LAMBDA_NAME" \
      --event-source-arn "$queue_arn" \
      --batch-size 10 \
      >/dev/null

  else

    echo "Event source mapping already exists"

  fi
}

# ============================================================
# Artifact S3 bucket
# ============================================================

ensure_artifact_bucket() {

  if aws s3api head-bucket \
    --bucket "$ARTIFACT_BUCKET" \
    >/dev/null 2>&1; then

    echo "Artifact bucket already exists: $ARTIFACT_BUCKET"

  else

    echo "Creating artifact bucket: $ARTIFACT_BUCKET"

    if [ "$AWS_REGION" = "us-east-1" ]; then

      aws s3api create-bucket \
        --bucket "$ARTIFACT_BUCKET" \
        >/dev/null

    else

      aws s3api create-bucket \
        --bucket "$ARTIFACT_BUCKET" \
        --create-bucket-configuration \
          LocationConstraint="$AWS_REGION" \
        >/dev/null

    fi
  fi

  # CodePipeline artifact stores must be versioned.
  aws s3api put-bucket-versioning \
    --bucket "$ARTIFACT_BUCKET" \
    --versioning-configuration Status=Enabled \
    >/dev/null

  # Enable server-side encryption.
  aws s3api put-bucket-encryption \
    --bucket "$ARTIFACT_BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    >/dev/null

  # Block public access.
  aws s3api put-public-access-block \
    --bucket "$ARTIFACT_BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null
}

# ============================================================
# CodeBuild IAM role
# ============================================================

ensure_codebuild_role() {

  local arn

  arn=$(role_arn_if_exists "$CB_ROLE_NAME")

  if [ -z "$arn" ] ||
     [ "$arn" = "None" ]; then

    echo "Creating IAM role: $CB_ROLE_NAME" >&2

    arn=$(
      aws iam create-role \
        --role-name "$CB_ROLE_NAME" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {
              "Service": "codebuild.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }]
        }' \
        --query 'Role.Arn' \
        --output text
    )

    wait_for_role_propagation

  else

    echo "IAM role already exists: $CB_ROLE_NAME" >&2

  fi

  aws iam put-role-policy \
    --role-name "$CB_ROLE_NAME" \
    --policy-name "${APP_NAME}-codebuild-policy" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"logs:CreateLogGroup\",
            \"logs:CreateLogStream\",
            \"logs:PutLogEvents\"
          ],
          \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/codebuild/${CB_PROJECT}*\"
        },

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"s3:GetObject\",
            \"s3:GetObjectVersion\",
            \"s3:PutObject\"
          ],
          \"Resource\": \"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"
        },

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"s3:GetBucketAcl\",
            \"s3:GetBucketLocation\",
            \"s3:GetBucketVersioning\"
          ],
          \"Resource\": \"arn:aws:s3:::${ARTIFACT_BUCKET}\"
        },

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"lambda:UpdateFunctionCode\",
            \"lambda:GetFunction\"
          ],
          \"Resource\": \"arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}\"
        }

      ]
    }" \
    >/dev/null

  echo "$arn"
}

# ============================================================
# CodeBuild project
# ============================================================

ensure_codebuild_project() {

  local role_arn="$1"

  local env_vars="[{name=LAMBDA_NAME,value=${LAMBDA_NAME}},{name=LAMBDA_SRC_DIR,value=${LAMBDA_SRC_DIR}}]"

  if aws codebuild batch-get-projects \
    --names "$CB_PROJECT" \
    --query 'projects[0].name' \
    --output text \
    2>/dev/null |
    grep -qx "$CB_PROJECT"; then

    echo "Updating CodeBuild project: $CB_PROJECT"

    run_with_role_retry aws codebuild update-project \
      --name "$CB_PROJECT" \
      --source "type=CODEPIPELINE,buildspec=${CB_BUILDSPEC}" \
      --artifacts "type=CODEPIPELINE" \
      --environment "type=LINUX_CONTAINER,image=${CB_IMAGE},computeType=${CB_COMPUTE},environmentVariables=${env_vars}" \
      --service-role "$role_arn" \
      >/dev/null

  else

    echo "Creating CodeBuild project: $CB_PROJECT"

    run_with_role_retry aws codebuild create-project \
      --name "$CB_PROJECT" \
      --source "type=CODEPIPELINE,buildspec=${CB_BUILDSPEC}" \
      --artifacts "type=CODEPIPELINE" \
      --environment "type=LINUX_CONTAINER,image=${CB_IMAGE},computeType=${CB_COMPUTE},environmentVariables=${env_vars}" \
      --service-role "$role_arn" \
      >/dev/null

  fi
}

# ============================================================
# CodePipeline IAM role
# ============================================================

ensure_codepipeline_role() {

  local arn
  local connection_status

  arn=$(role_arn_if_exists "$CP_ROLE_NAME")

  if [ -z "$arn" ] ||
     [ "$arn" = "None" ]; then

    echo "Creating IAM role: $CP_ROLE_NAME" >&2

    arn=$(
      aws iam create-role \
        --role-name "$CP_ROLE_NAME" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {
              "Service": "codepipeline.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }]
        }' \
        --query 'Role.Arn' \
        --output text
    )

    wait_for_role_propagation

  else

    echo "IAM role already exists: $CP_ROLE_NAME" >&2

  fi

  # ----------------------------------------------------------
  # Verify GitHub connection
  # ----------------------------------------------------------

  if aws codeconnections get-connection \
    --connection-arn "$CONNECTION_ARN" \
    --query 'Connection.ConnectionStatus' \
    --output text \
    >/dev/null 2>&1; then

    connection_status=$(
      aws codeconnections get-connection \
        --connection-arn "$CONNECTION_ARN" \
        --query 'Connection.ConnectionStatus' \
        --output text
    )

    if [ "$connection_status" != "AVAILABLE" ]; then

      echo "ERROR: CodeConnections connection is not AVAILABLE:" >&2
      echo "       $CONNECTION_ARN" >&2
      echo "       Status: $connection_status" >&2

      return 1
    fi

  else

    echo "ERROR: Could not read CodeConnections connection:" >&2
    echo "       $CONNECTION_ARN" >&2

    return 1
  fi

  # ----------------------------------------------------------
  # CodePipeline service role policy
  # ----------------------------------------------------------

  aws iam put-role-policy \
    --role-name "$CP_ROLE_NAME" \
    --policy-name "${APP_NAME}-codepipeline-policy" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"s3:GetObject\",
            \"s3:GetObjectVersion\",
            \"s3:PutObject\",
            \"s3:PutObjectAcl\",
            \"s3:GetBucketVersioning\",
            \"s3:GetBucketAcl\",
            \"s3:GetBucketLocation\",
            \"s3:ListBucket\"
          ],
          \"Resource\": [
            \"arn:aws:s3:::${ARTIFACT_BUCKET}\",
            \"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"
          ]
        },

        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"codebuild:BatchGetBuilds\",
            \"codebuild:StartBuild\"
          ],
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
    }" \
    >/dev/null

  echo "$arn"
}

# ============================================================
# CodePipeline
# ============================================================

ensure_codepipeline() {

  local role_arn="$1"
  local pipeline_def
  local pipeline_file

  pipeline_def=$(cat <<JSON
{
  "pipeline": {
    "name": "${CP_NAME}",
    "roleArn": "${role_arn}",
    "artifactStore": {
      "type": "S3",
      "location": "${ARTIFACT_BUCKET}"
    },
    "stages": [

      {
        "name": "Source",
        "actions": [{
          "name": "Source",
          "actionTypeId": {
            "category": "Source",
            "owner": "AWS",
            "provider": "CodeStarSourceConnection",
            "version": "1"
          },
          "outputArtifacts": [
            {
              "name": "SourceOutput"
            }
          ],
          "configuration": {
            "ConnectionArn": "${CONNECTION_ARN}",
            "FullRepositoryId": "${GH_OWNER}/${GH_REPO}",
            "BranchName": "${GH_BRANCH}",
            "OutputArtifactFormat": "CODE_ZIP",
            "DetectChanges": "true"
          }
        }]
      },

      {
        "name": "Build",
        "actions": [{
          "name": "BuildAndDeployLambda",
          "actionTypeId": {
            "category": "Build",
            "owner": "AWS",
            "provider": "CodeBuild",
            "version": "1"
          },
          "inputArtifacts": [
            {
              "name": "SourceOutput"
            }
          ],
          "outputArtifacts": [
            {
              "name": "BuildOutput"
            }
          ],
          "configuration": {
            "ProjectName": "${CB_PROJECT}"
          }
        }]
      }

    ]
  }
}
JSON
)

  # Use a real temporary file rather than /dev/stdin.
  pipeline_file=$(mktemp)

  printf '%s' "$pipeline_def" > "$pipeline_file"

  if aws codepipeline get-pipeline \
    --name "$CP_NAME" \
    >/dev/null 2>&1; then

    echo "Updating CodePipeline: $CP_NAME"

    if ! run_with_role_retry aws codepipeline update-pipeline \
      --cli-input-json "file://${pipeline_file}" \
      >/dev/null; then

      rm -f "$pipeline_file"

      echo "ERROR: CodePipeline update failed: $CP_NAME" >&2

      return 1
    fi

  else

    echo "Creating CodePipeline: $CP_NAME"

    if ! run_with_role_retry aws codepipeline create-pipeline \
      --cli-input-json "file://${pipeline_file}" \
      >/dev/null; then

      rm -f "$pipeline_file"

      echo "ERROR: CodePipeline creation failed: $CP_NAME" >&2

      return 1
    fi

  fi

  rm -f "$pipeline_file"

  # Verify that the pipeline exists after create/update.
  if ! aws codepipeline get-pipeline \
    --name "$CP_NAME" \
    >/dev/null 2>&1; then

    echo "ERROR: CodePipeline was not found after create/update: $CP_NAME" >&2

    return 1
  fi

  echo "CodePipeline verified: $CP_NAME"
}

# ============================================================
# Run
# ============================================================

echo "=== Starting provisioning ==="

QUEUE_URL=$(ensure_sqs_queue)

QUEUE_ARN=$(sqs_arn_from_url "$QUEUE_URL")

LAMBDA_ROLE_ARN=$(ensure_lambda_role)

ZIP_PATH=$(package_lambda)

BUILT_LAYER_ARN=$(ensure_lambda_layer)

deploy_lambda \
  "$LAMBDA_ROLE_ARN" \
  "$ZIP_PATH" \
  "$QUEUE_URL" \
  "$BUILT_LAYER_ARN"

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