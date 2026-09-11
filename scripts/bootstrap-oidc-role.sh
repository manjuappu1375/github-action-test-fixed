#!/usr/bin/env bash
#
# ONE-TIME, run manually by someone with admin AWS creds (not by GitHub Actions).
# Creates the GitHub OIDC identity provider (if missing) and an IAM role that
# GitHub Actions assumes to run scripts/provision.sh.
#
# Usage:
#   ./bootstrap-oidc-role.sh <github_owner> <github_repo> [role_name] [branch]
#
# GitHub repositories created after July 15, 2026 use immutable OIDC subjects
# by default, so this script resolves the owner/repository IDs through `gh`
# and creates a branch-scoped immutable trust policy.
#
set -euo pipefail

GH_ORG="${1:?Usage: bootstrap-oidc-role.sh <github_owner> <github_repo> [role_name] [branch]}"
GH_REPO="${2:?Usage: bootstrap-oidc-role.sh <github_owner> <github_repo> [role_name] [branch]}"
ROLE_NAME="${3:-github-actions-deploy-role}"
GH_BRANCH="${4:-main}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI (gh) is required to resolve immutable OIDC repository IDs." >&2
  echo "       Install gh and authenticate with: gh auth login" >&2
  exit 1
fi

echo "Resolving GitHub repository IDs for ${GH_ORG}/${GH_REPO}..."
read -r GH_OWNER_ID GH_REPO_ID < <(
  gh api "repos/${GH_ORG}/${GH_REPO}" \
    --jq '[.owner.id, .id] | @tsv'
)

if [ -z "$GH_OWNER_ID" ] || [ -z "$GH_REPO_ID" ]; then
  echo "ERROR: Could not resolve GitHub owner/repository IDs." >&2
  exit 1
fi

if ! aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "Creating GitHub OIDC provider"
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
else
  echo "GitHub OIDC provider already exists"
fi

IMMUTABLE_SUB="repo:${GH_ORG}@${GH_OWNER_ID}/${GH_REPO}@${GH_REPO_ID}:ref:refs/heads/${GH_BRANCH}"

TRUST_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "GitHubActionsOIDC",
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "${IMMUTABLE_SUB}"
      }
    }
  }]
}
JSON
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Updating trust policy on existing role: $ROLE_NAME"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  echo "Creating role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

# Bootstrap permissions. The provisioning role is intentionally broad enough
# for this CLI-only project, but PassRole and PassConnection are scoped.
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "provisioning-permissions" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"ProvisionResources\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"iam:CreateRole\",\"iam:GetRole\",\"iam:PutRolePolicy\",\"iam:AttachRolePolicy\",
          \"sqs:*\",
          \"lambda:*\",
          \"codebuild:*\",
          \"codepipeline:*\",
          \"codestar-connections:UseConnection\",\"codestar-connections:GetConnectionToken\",\"codestar-connections:GetConnection\",
          \"codeconnections:UseConnection\",\"codeconnections:GetConnectionToken\",\"codeconnections:GetConnection\",
          \"s3:CreateBucket\",\"s3:PutBucketEncryption\",\"s3:PutPublicAccessBlock\",\"s3:PutBucketVersioning\",
          \"s3:GetObject\",\"s3:GetObjectVersion\",\"s3:PutObject\",\"s3:HeadBucket\",\"s3:ListBucket\",
          \"s3:GetBucketAcl\",\"s3:GetBucketLocation\",\"s3:GetBucketVersioning\",
          \"logs:*\",
          \"sts:GetCallerIdentity\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Sid\": \"PassServiceRoles\",
        \"Effect\": \"Allow\",
        \"Action\": \"iam:PassRole\",
        \"Resource\": [
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-lambda-role\",
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-codebuild-role\",
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-codepipeline-role\"
        ],
        \"Condition\": {
          \"StringEquals\": {
            \"iam:PassedToService\": [
              \"lambda.amazonaws.com\",
              \"codebuild.amazonaws.com\",
              \"codepipeline.amazonaws.com\"
            ]
          }
        }
      },
      {
        \"Sid\": \"PassGitHubConnectionToCodePipeline\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"codeconnections:PassConnection\",
          \"codestar-connections:PassConnection\"
        ],
        \"Resource\": \"arn:aws:codeconnections:*:${ACCOUNT_ID}:connection/*\",
        \"Condition\": {
          \"StringEquals\": {
            \"codeconnections:PassedToService\": \"codepipeline.amazonaws.com\"
          }
        }
      }
    ]
  }" >/dev/null

echo "Done. Role ARN:"
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text
echo "OIDC subject:"
echo "  $IMMUTABLE_SUB"
echo "Add the role ARN as the GitHub secret AWS_DEPLOY_ROLE_ARN."
