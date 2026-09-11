#!/usr/bin/env bash
#
# ONE-TIME, run manually by someone with admin AWS creds (not by GitHub Actions).
# Creates the GitHub OIDC identity provider (if missing) and an IAM role that
# GitHub Actions assumes to run scripts/provision.sh. Do this once per AWS
# account, not per app.
#
# Usage: ./bootstrap-oidc-role.sh <github_org> <github_repo> [role_name]
#
set -euo pipefail

GH_ORG="${1:?Usage: bootstrap-oidc-role.sh <github_org> <github_repo> [role_name]}"
GH_REPO="${2:?Usage: bootstrap-oidc-role.sh <github_org> <github_repo> [role_name]}"
ROLE_NAME="${3:-github-actions-deploy-role}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "Creating GitHub OIDC provider"
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
else
  echo "GitHub OIDC provider already exists"
fi

TRUST_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "repo:${GH_ORG}/${GH_REPO}:*"}
    }
  }]
}
JSON
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Updating trust policy on existing role: $ROLE_NAME"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  echo "Creating role: $ROLE_NAME"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

# Permissions the deploy role needs to run provision.sh. Tighten resource
# ARNs for production use; broad here for bootstrapping.
#
# NOTE: iam:PassRole is required and easy to miss - without it, every
# `aws lambda create-function`, `codebuild create-project`, and
# `codepipeline create-pipeline` call in provision.sh fails with an
# AccessDenied error the moment it tries to hand its service role to the
# Lambda/CodeBuild/CodePipeline service. It's scoped to the three role
# name suffixes provision.sh creates (<app>-lambda-role, <app>-codebuild-role,
# <app>-codepipeline-role) rather than left wide open.
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "provisioning-permissions" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"iam:CreateRole\",\"iam:GetRole\",\"iam:PutRolePolicy\",\"iam:AttachRolePolicy\",
          \"sqs:*\",
          \"lambda:*\",
          \"codebuild:*\",
          \"codepipeline:*\",
          \"codestar-connections:UseConnection\",\"codestar-connections:GetConnectionToken\",\"codestar-connections:GetConnection\",
          \"codeconnections:UseConnection\",\"codeconnections:GetConnectionToken\",\"codeconnections:GetConnection\",
          \"s3:CreateBucket\",\"s3:PutBucketEncryption\",\"s3:PutPublicAccessBlock\",
          \"s3:GetObject\",\"s3:PutObject\",\"s3:HeadBucket\",\"s3:ListBucket\",
          \"logs:*\",
          \"sts:GetCallerIdentity\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"iam:PassRole\",
        \"Resource\": [
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-lambda-role\",
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-codebuild-role\",
          \"arn:aws:iam::${ACCOUNT_ID}:role/*-codepipeline-role\"
        ]
      }
    ]
  }" >/dev/null

echo "Done. Role ARN:"
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text
echo "Add this ARN as the GitHub secret AWS_DEPLOY_ROLE_ARN."