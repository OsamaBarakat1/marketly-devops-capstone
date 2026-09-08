#!/usr/bin/env bash
#
# Verifies that this machine can actually drive the project: the CLIs the
# other three scripts shell out to, and the local configuration they read.
#
# Every check runs before anything is reported, rather than dying on the
# first missing tool. "Install these four things" is one trip to a package
# manager; four consecutive failures are four.
#
# Missing tools are fatal. Missing configuration — AWS credentials, a
# terraform.tfvars, a reachable cluster — is reported as a warning instead,
# because it is normal not to have them yet on a fresh clone.
#
#   scripts/setup.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# The floor declared in terraform/versions.tf. Anything older cannot parse
# this configuration.
readonly TERRAFORM_MIN_VERSION="1.6.0"

# Colour only when someone is watching. Piped into a log or a CI step, the
# escape codes are noise.
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi
readonly RED GREEN YELLOW BOLD DIM RESET

failures=0
warnings=0

pass() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; failures=$((failures + 1)); }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; warnings=$((warnings + 1)); }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$RESET"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [-h|--help]

Checks that the tools and local configuration this project needs are in
place. Exits non-zero if a required tool is missing.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *)
    printf 'unknown argument: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

# --- tools ---------------------------------------------------------------

# require <command> <what it is used for> <how to install it>
require() {
  local cmd="$1" purpose="$2" hint="$3"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd — $purpose"
  else
    fail "$cmd is not installed — $purpose"
    note "$hint"
  fi
}

heading "Required tools"

require aws       "reads RDS, ECR, SSM and Secrets Manager at deploy time" \
                  "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
require terraform "provisions and destroys the AWS stack" \
                  "https://developer.hashicorp.com/terraform/install"
require kubectl   "applies manifests and reports rollout status" \
                  "https://kubernetes.io/docs/tasks/tools/"
require docker    "builds the images and runs the local compose stack" \
                  "https://docs.docker.com/engine/install/"
require git       "supplies the commit SHA that images are tagged with" \
                  "apt install git / brew install git"
require curl      "probes the /health endpoints and the load balancer" \
                  "apt install curl / brew install curl"
require envsubst  "substitutes AWS-derived values into the k8s manifests" \
                  "part of gettext: apt install gettext-base / brew install gettext"
require python3   "parses AWS JSON and URL-encodes the database password" \
                  "apt install python3 / brew install python3"

# --- versions ------------------------------------------------------------

# True when $1 is at least $2, comparing as dotted version numbers rather
# than as strings: "1.10.0" is newer than "1.9.8" but sorts before it.
#
# The first line is taken with a parameter expansion rather than `head -n1`,
# because `set -o pipefail` turns the SIGPIPE that head gives sort into a
# failure of the whole check.
version_at_least() {
  local sorted
  sorted="$(printf '%s\n%s\n' "$2" "$1" | sort -V)"
  [ "${sorted%%$'\n'*}" = "$2" ]
}

heading "Versions"

if command -v terraform >/dev/null 2>&1; then
  tf_version="$(terraform version)"
  tf_version="${tf_version%%$'\n'*}"
  tf_version="${tf_version#Terraform v}"
  if version_at_least "$tf_version" "$TERRAFORM_MIN_VERSION"; then
    pass "terraform $tf_version (>= $TERRAFORM_MIN_VERSION)"
  else
    fail "terraform $tf_version is older than $TERRAFORM_MIN_VERSION"
    note "terraform/versions.tf sets required_version = \">= $TERRAFORM_MIN_VERSION\""
  fi
else
  warn "skipped the terraform version check — terraform is not installed"
fi

if command -v aws >/dev/null 2>&1; then
  aws_version="$(aws --version 2>&1 | sed 's|^aws-cli/\([^ ]*\).*|\1|')"
  if version_at_least "$aws_version" "2.0.0"; then
    pass "aws-cli $aws_version"
  else
    # v1 lacks `aws ssm start-session`, which is the only route into the
    # cluster, and reads some outputs differently.
    fail "aws-cli $aws_version is v1; this project needs v2"
    note "v1 has no 'aws ssm start-session', and that is the only way into the cluster"
  fi
fi

# --- daemons -------------------------------------------------------------

heading "Docker"

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass "the Docker daemon is running"
  else
    fail "the Docker daemon is not reachable"
    note "start Docker Desktop, or: sudo systemctl start docker"
  fi

  if docker compose version >/dev/null 2>&1; then
    pass "the 'docker compose' plugin is available"
  else
    fail "'docker compose' is unavailable (the v1 'docker-compose' script is not a substitute)"
    note "docker-compose.yml and .github/workflows/ci.yml both invoke 'docker compose'"
  fi
fi

# --- AWS -----------------------------------------------------------------

heading "AWS access"

if command -v aws >/dev/null 2>&1; then
  if identity="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)"; then
    pass "credentials resolve (account $identity)"
    note "region: ${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo 'not set, defaults to us-east-1')}}"
  else
    warn "no AWS credentials resolve yet"
    note "run 'aws configure', or export AWS_PROFILE — needed by deploy.sh and teardown.sh"
  fi
fi

# --- project configuration ----------------------------------------------

heading "Project configuration"

if [ -f "$REPO_ROOT/terraform/terraform.tfvars" ]; then
  pass "terraform/terraform.tfvars exists"
else
  warn "terraform/terraform.tfvars is missing"
  note "cp terraform/terraform.tfvars.example terraform/terraform.tfvars, then set github_repo"
fi

# github_repo is the one variable with no default, so terraform prompts for
# it interactively when it is absent — which hangs an unattended deploy.sh.
if [ -f "$REPO_ROOT/terraform/terraform.tfvars" ] &&
   ! grep -Eq '^[[:space:]]*github_repo[[:space:]]*=' "$REPO_ROOT/terraform/terraform.tfvars"; then
  warn "terraform.tfvars does not set github_repo"
  note "it is the only variable with no default, so terraform will stop and prompt for it"
fi

if grep -Eq '^[[:space:]]*terraform[[:space:]]*\{' "$REPO_ROOT/terraform/backend.tf"; then
  pass "the S3 remote state backend is configured"
else
  warn "the S3 backend in terraform/backend.tf is still commented out"
  note "state is local until then — see the instructions in that file, and terraform/bootstrap/"
fi

if [ -f "$REPO_ROOT/.git/hooks/pre-commit" ] ||
   [ "$(git -C "$REPO_ROOT" config core.hooksPath 2>/dev/null || true)" = ".githooks" ]; then
  pass "the pre-commit secret-scanning hook is active"
else
  warn "the pre-commit hook is not active in this clone"
  note "git config core.hooksPath .githooks — CI scans anyway, but after the secret is already pushed"
fi

# --- cluster -------------------------------------------------------------

heading "Cluster"

if command -v kubectl >/dev/null 2>&1; then
  if kubectl cluster-info >/dev/null 2>&1; then
    pass "kubectl reaches a cluster ($(kubectl config current-context 2>/dev/null || echo 'unknown context'))"
  else
    # Expected on a laptop: the k3s API has no public address and there is
    # no SSH key. deploy.sh and healthcheck.sh say the same thing when they
    # need the cluster and cannot find it.
    warn "kubectl does not reach a cluster from here"
    note "expected on a laptop — the k3s API is private. Connect with:"
    note "  aws ssm start-session --target \$(terraform -chdir=terraform output -raw k3s_server_instance_id)"
  fi
fi

# --- summary -------------------------------------------------------------

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf '%s%d check(s) failed%s, %d warning(s). Install what is missing and run this again.\n' \
    "$RED" "$failures" "$RESET" "$warnings"
  exit 1
fi

if [ "$warnings" -gt 0 ]; then
  printf '%sAll required tools are present%s, with %d warning(s) above — none of them block building or testing locally.\n' \
    "$GREEN" "$RESET" "$warnings"
else
  printf '%sReady.%s Everything this project needs is installed and configured.\n' "$GREEN" "$RESET"
fi
