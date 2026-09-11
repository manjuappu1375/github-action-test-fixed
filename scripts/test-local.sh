#!/usr/bin/env bash
#
# Run the provisioning script against a local LocalStack instance instead of
# real AWS. Nothing here touches your actual AWS account.
#
# Usage: ./scripts/test-local.sh [path/to/config.yaml]
#   defaults to test/configs/example-app.local-test.yaml
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG_FILE="${1:-test/configs/example-app.local-test.yaml}"
COMPOSE_FILE="docker-compose.localstack.yml"

echo "=== Starting LocalStack ==="
docker compose -f "$COMPOSE_FILE" up -d

cleanup() {
  echo "=== Stopping LocalStack ==="
  docker compose -f "$COMPOSE_FILE" down
}
trap cleanup EXIT

echo "=== Waiting for LocalStack to be healthy ==="
for i in $(seq 1 30); do
  if curl -fs http://localhost:4566/_localstack/health | grep -q '"sqs": "\(available\|running\)"'; then
    echo "LocalStack is up."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "LocalStack did not become healthy in time." >&2
    docker compose -f "$COMPOSE_FILE" logs
    exit 1
  fi
  sleep 2
done

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ENDPOINT_URL="http://localhost:4566"
export SKIP_CODE_SERVICES="true"

echo "=== Running provision.sh against LocalStack ==="
chmod +x scripts/provision.sh
./scripts/provision.sh "$CONFIG_FILE"

echo "=== Verifying resources ==="
LAMBDA_NAME=$(python3 -c "
import yaml
print(yaml.safe_load(open('$CONFIG_FILE'))['lambda']['function_name'])
")

echo "-- Queues --"
aws sqs list-queues

echo "-- Lambda functions --"
aws lambda list-functions --query "Functions[].FunctionName"

echo "-- Event source mappings --"
aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME"

echo "-- Invoking the Lambda with a fake SQS-shaped payload --"
aws lambda invoke \
  --function-name "$LAMBDA_NAME" \
  --payload '{"Records":[{"body":"test message from LocalStack"}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/localstack-invoke-output.json
cat /tmp/localstack-invoke-output.json
echo

echo "=== Re-running provision.sh to confirm idempotency ==="
./scripts/provision.sh "$CONFIG_FILE"

echo "=== LocalStack test run complete ==="