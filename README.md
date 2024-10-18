# Parittion ECR Replicate

This is a Lambda function and CodeBuild Project to replicate an images between
repositories in different AWS partitions. Because there is no trust
relationship between partitions, the normal ECR Replication process cannot be
used.

This solution uses an SQS FIFO Queue to process events for the same image tags
in the order they are received. However, there is the chance that if an image
is quickly modified then the events might arrive to the queue out of order. You
should be cautious about using this when the same image is being modified
quickly. State between the Lambda and the project that does the work is stored
in a DynamoDB table.

Requirements:

- ECR repositories must already be created in both the source and destination.

The terraform will create the required IAM User in the destination account
(using the `aws.destination` provider you specify), and a Secret for those
credentials in the source account. You will need to create the access keys for
the IAM User and store them in the secret with these fields:

- `user`: name of the IAM User in the destination account.
- `accesskey`, `secretaccesskey`: the generated pair of access keys.
- `partition`: either `aws` (commercial) or `aws-us-gov` (US GovCloud).
- `accountid`: the destination account ID.

## buildspec.yml

CodeBuild uses this to call the `Makefile` to build the Lambda and upload its
build artifact (a zip for deploying Lambda) to S3. If you want to customize
something about the build process then you should likely be editing the
`Makefile` instead.

### Variables

The pipeline and CodeBuild set several custom variables to control the
CodeBuild process. You do not need to change or set these values when cerating
a Lambda, they are just provided for documentation:

| Name               | Default                                             | Description |
| ------------------ | --------------------------------------------------- | ----------- |
| ENVIRONMENT        |                                                     | The type of build being performed: prod, dev, test, qa, etc. If not specified then the build artifact will not be uploaded. |
| PACKAGE_BUCKET     |                                                     | The S3 bucket name to place the build artifact in. If not specified then the build artifact will not be uploaded. |
| PACKAGE_PREFIX     |                                                     | An optional prefix to use when uploading the build artifact to S3. If specified this must not begin with a `/` and must end with a `/`. It is appended in addition to the app name specified in the buildspec. |
| PACKAGE_KMS_KEY_ID | `alias/aws/s3`                                      | The AWS KMS Key ID (alias name, ID, or ARN) to use for encrypting the build artifact in S3. |
| REPO_NAME          | `auto-account-provisioning/partition-ecr-replicate` | The ECR repository name to push the image to. If not specified then the image will not be uploaded. |

## Makefile

This is the main way to control the build process for the Lambda. It has a
couple top level targets, and then several utility targets.

### clean

Removes all of the build artifact directories. This should return the Lambda
directory to when it was checked out.

### build

Builds the Lambda by installing the dependencies and copying the source code
to the build directory (usually `build/`).

### lint

Run pylint on the built Lambda. Lint errors and warnings should be corrected,
or individually disabled in the code if they are reviewed and not an issue.
Running pylint before a checkin can help find many common, subtle errors.

Module, class, and function docstrings should follow the
[Google Python Style Guide](https://google.github.io/styleguide/pyguide.html#s3.8-comments-and-docstrings).

### test

Run pytest from the `tests/` directory on the built Lambda. The majority of
the Lambda functions and classes should be covered by comprehensive unit tests.
Running pytest before a checkin is SOP, and pipeline builds will fail if a
Lambda's tests fail.

### validate

Run `terraform validate` from the `terraform/` directory. It will catch basic
errors in the terraform, but many classes of error slip through.

### dist

Take the built Lambda and package it in a zip for deployment. This produces an
artifact in the dist directory (usually `dist/`). Any Lambda built and deployed
for the project must be built on Linux (macOS and Windows builds will sometimes
not work in AWS Lambda).

### package

Take the files from the `build/` directory, package them for Lambda in a zip,
and upload it to S3. This will compute a hash of the artifact and only upload
if the hash has changed from previous builds.

### ecr-login

Login to the ECR repository using AWS credentials.

### image-build

Run `docker build` for the image. It will first pull the base image to make
sure it has the latest updates.

### image-push-latest, image-push-dev, image-push-test, image-push-prod

Push the image from `image-build` to the ECR repository, with the specified
tag. When using `image-push-latest` it will also push with the git short commit
ID as a tag.

### internal targets

Some of the make targets are for internal use:

- **.lint-setup:** install requirements for pylint.
- **.test-setup:** install requirements for pytest.
- **.validate-setup:** install requirements for terraform validate.
- **lint-report:** run pylint and output a JUnit XML.
- **test-report:** run pytest and output a JUnit XML.