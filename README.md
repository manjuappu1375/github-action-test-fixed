# YAML-driven AWS provisioning (no IaC tools)

Push/update a YAML file under `configs/` and GitHub Actions creates or updates,
via plain **AWS CLI calls only** (no Terraform/CDK/CloudFormation/Pulumi):

- SQS queue
- Lambda function (packaged from a folder in this repo) + SQS trigger
- CodeBuild project
- CodePipeline (Source: GitHub → Build: CodeBuild, which redeploys the Lambda)
- The IAM roles all of the above need

## Files

```
.github/workflows/provision.yml        # real deploy: triggers on push to configs/**
.github/workflows/test-localstack.yml  # test: triggers on PRs / non-main branches
scripts/provision.sh                   # does the actual AWS CLI work, idempotent
scripts/bootstrap-oidc-role.sh         # ONE-TIME, run manually, not by CI
scripts/test-local.sh                  # run the LocalStack test from your own machine
docker-compose.localstack.yml          # local LocalStack instance for testing
configs/example-app.yaml               # real config schema / example -> triggers deploy
test/configs/example-app.local-test.yaml  # test fixture -> never triggers real deploy
lambda-src/app.py                      # sample Lambda handler
buildspec.yml                          # used by the CodeBuild project
```

**Important:** only files under `configs/*.yaml` trigger the real deploy workflow. Test
fixtures live under `test/configs/` specifically so they can never accidentally
provision real AWS resources.

## Test first, then deploy

1. **Local, before pushing anything:**
   ```bash
   ./scripts/test-local.sh
   ```
   This starts a free LocalStack container, runs `provision.sh` against it with
   `SKIP_CODE_SERVICES=true`, verifies the SQS queue, Lambda function, and
   event source mapping actually exist, invokes the Lambda, runs `provision.sh`
   a second time to confirm idempotency, then tears LocalStack down. Nothing
   touches your real AWS account.

2. **On every PR / non-`main` push:** `.github/workflows/test-localstack.yml`
   runs the same check in CI automatically.

3. **Only on push to `main` under `configs/*.yaml`:**
   `.github/workflows/provision.yml` runs `provision.sh` against real AWS.

### Why CodeBuild/CodePipeline aren't in the LocalStack test

They're LocalStack **Pro** (paid) features — the free/community image doesn't
emulate them at all. Setting `SKIP_CODE_SERVICES=true` makes `provision.sh`
skip those two steps entirely rather than fail or fake a pass. So the
LocalStack test gives you real coverage of SQS + Lambda + IAM + S3, but
CodeBuild/CodePipeline are only exercised on the real deploy — get those
right by reviewing the JSON that `provision.sh` builds for them (it's plain
`create-project` / `create-pipeline` CLI calls, easy to read) and by using
`workflow_dispatch` against a real but disposable/sandbox AWS account first
if you want a dry run before pointing this at production.

## One-time manual prerequisites

These two things genuinely can't be automated by CLI/CI without either IaC or
a human clicking a button in the AWS console — everything else is scripted.

### 1. Bootstrap the GitHub OIDC deploy role (once per AWS account)

From a machine with admin AWS credentials:

```bash
./scripts/bootstrap-oidc-role.sh your-github-org your-repo-name
```

This creates the GitHub OIDC provider and an IAM role GitHub Actions assumes
(no long-lived AWS keys in GitHub secrets). Copy the printed role ARN and add
repo secrets:

- `AWS_DEPLOY_ROLE_ARN` – the role ARN it printed
- `AWS_REGION` – e.g. `us-east-1`

### 2. Authorize a CodeStar Connection to GitHub (once per repo, or reuse one)

AWS requires this handshake to be completed in the console — there's no API
to finish the OAuth step:

1. AWS Console → **Developer Tools → Settings → Connections → Create connection**
2. Choose **GitHub**, authorize the AWS Connector app for your org/repo
3. Copy the resulting connection ARN into your config's `codepipeline.connection_arn`

## Using it

1. Copy `configs/example-app.yaml`, rename it, fill in your values (function
   name, queue name, GitHub repo, the connection ARN from step 2 above).
2. Put your Lambda code in the `source_dir` referenced by the config.
3. Commit and push to `main`. The workflow detects the new/changed YAML under
   `configs/` and runs `scripts/provision.sh <your-file>` for each one.
4. Re-running (pushing an edited config, or `workflow_dispatch`) is safe —
   every step checks for existing resources and updates them instead of
   failing.

To (re)provision on demand without a config change, use **Actions → Provision
AWS Resources from YAML → Run workflow** and give it the config path.

## Notes / things to tighten before production

- `bootstrap-oidc-role.sh` grants broad permissions to the deploy role to
  keep bootstrapping simple — scope down `Resource` entries once you know
  your naming conventions. (It does already scope the `iam:PassRole`
  statement to the `*-lambda-role` / `*-codebuild-role` / `*-codepipeline-role`
  names `provision.sh` creates, since that permission is required and easy
  to accidentally leave off.)
- The CodeBuild role's inline policy already scopes `lambda:UpdateFunctionCode`
  to the specific function ARN — follow that pattern for any extra
  permissions you add.
- `provision.sh` assumes one Lambda + one queue + one pipeline per config
  file. If you need multiple functions per app, extend the YAML schema and
  loop inside the script.
- State: this approach has no state file. "Does resource X exist" is
  answered by asking AWS directly on every run, which is what keeps it safe
  to skip IaC — but it also means there's no drift detection beyond that.
- `provision.sh` retries the Lambda/CodeBuild/CodePipeline create/update
  calls with backoff if AWS reports the just-created IAM role "cannot be
  assumed" yet — freshly created roles can take longer to propagate than a
  fixed sleep can reliably cover.
- Before running a real deploy, `provision.sh` now checks that
  `codepipeline.connection_arn`, `codepipeline.github_owner`, and
  `codepipeline.github_repo` aren't still the example placeholders, and
  fails immediately with a clear message instead of partway through
  provisioning.
