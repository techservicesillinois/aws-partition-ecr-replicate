APP_NAME   := partitionECRReplicate
BUILDDIR   := $(PWD)/build/
DISTDIR    := $(PWD)/dist/
REPORTSDIR := $(PWD)/reports/

REQUIREMENTS      := src/requirements.txt
TEST_REQUIREMENTS := tests/requirements.txt
SOURCES           := $(wildcard src/./*.py src/./**/*.py)

PYTHON        := python3.11
TERRAFORM_BIN := terraform

PROJECT   ?=auto-account-provisioning
REPO_NAME ?=$(PROJECT)/partition-ecr-replicate
REPO_URI  ?=$(shell aws ecr describe-repositories --repository-names $(REPO_NAME) --output text --query 'repositories[].repositoryUri' --region us-east-2)
COMMIT_ID :=$(shell git rev-parse --short HEAD)

.PHONY: clean build lint lint-report test test-report validate dist package .lint-setup .test-setup .validate-setup

clean:
	rm -fr -- .venv || :
	rm -fr -- terraform/1.x-aws4/.terraform  || :
	rm -f  -- terraform/1.x-aws4/.terraform.lock.hcl || :
	rm -fr -- "$(BUILDDIR)" || :
	rm -fr -- "$(DISTDIR)" || :
	rm -fr -- "$(REPORTSDIR)" || :

build:
	[ -e .venv ] || $(PYTHON) -mvenv .venv
	[ -e "$(BUILDDIR)" ] || mkdir -p "$(BUILDDIR)"
	.venv/bin/pip install -qq --target "$(BUILDDIR)" -r $(REQUIREMENTS)
	rsync -R $(SOURCES) "$(BUILDDIR)"

.lint-setup: build
	.venv/bin/pip install -qq -r $(REQUIREMENTS)
	[ -e .venv/bin/pylint ] || .venv/bin/pip install -qq pylint
lint: .lint-setup
	.venv/bin/pylint $(SOURCES)
lint-report: .lint-setup
	[ -e "$(REPORTSDIR)" ] || mkdir -p "$(REPORTSDIR)"
	.venv/bin/pip install -qq pylint_junit
	.venv/bin/pylint --output-format="pylint_junit.JUnitReporter:$(REPORTSDIR)/pylint.xml,text" $(SOURCES)

.test-setup: build
	.venv/bin/pip install -qq -r $(REQUIREMENTS)
	.venv/bin/pip install -qq -r $(TEST_REQUIREMENTS)
test: .test-setup
	.venv/bin/pytest -v tests/
test-report: .test-setup
	[ -e "$(REPORTSDIR)" ] || mkdir -p "$(REPORTSDIR)"
	.venv/bin/pytest --junitxml="$(REPORTSDIR)/pytest.xml" tests/

.validate-setup:
	cd tests/terraform/1.x-aws4 && $(TERRAFORM_BIN) init -backend=false
validate: .validate-setup
	cd tests/terraform/1.x-aws4 && $(TERRAFORM_BIN) validate

dist: build
	[ -e "$(DISTDIR)" ] || mkdir -p "$(DISTDIR)"
	cd "$(BUILDDIR)" && zip -yr "$(DISTDIR)/$(APP_NAME).zip" *

package:
	[ -e .venv ] || $(PYTHON) -mvenv .venv
	.venv/bin/pip install -qq -r scripts/requirements.txt
	[ -e "$(DISTDIR)" ] || mkdir -p "$(DISTDIR)"
	.venv/bin/python scripts/lambda-package-zip.py -a "$(APP_NAME)" -o "$(DISTDIR)/$(APP_NAME).zip" build/

ecr-login:
	@:$(call check_defined, REPO_URI, Repository URI)
	_repo='$(REPO_URI)'; aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin $${_repo%%/*}

image-build:
	[ -e "$(DISTDIR)" ] || mkdir -p "$(DISTDIR)"
	docker pull public.ecr.aws/ubuntu/ubuntu:24.04
	docker build -t $(REPO_NAME):latest --iidfile "$(DISTDIR)/$(APP_NAME).image-id" .
	docker tag $(REPO_NAME):latest $(REPO_NAME):commit-$(COMMIT_ID)

image-push-latest:
	@:$(call check_defined, REPO_URI, Repository URI)
	docker tag $(REPO_NAME):latest $(REPO_URI):latest
	docker push $(REPO_URI):latest
	sleep 10
	docker tag $(REPO_NAME):latest $(REPO_URI):commit-$(COMMIT_ID)
	docker push $(REPO_URI):commit-$(COMMIT_ID)

image-push:
	@:$(call check_defined, REPO_URI, Repository URI)
	@:$(call check_defined, IMAGE_TAG, Image Tag)
	docker tag $(REPO_NAME):latest $(REPO_URI):$(IMAGE_TAG)
	docker push $(REPO_URI):$(IMAGE_TAG)

image-push-dev:
	@:$(call check_defined, REPO_URI, Repository URI)
	docker tag $(REPO_NAME):latest $(REPO_URI):dev
	docker push $(REPO_URI):dev

image-push-test:
	@:$(call check_defined, REPO_URI, Repository URI)
	docker tag $(REPO_NAME):latest $(REPO_URI):test
	docker push $(REPO_URI):test

image-push-prod:
	@:$(call check_defined, REPO_URI, Repository URI)
	docker tag $(REPO_NAME):latest $(REPO_URI):prod
	docker push $(REPO_URI):prod

