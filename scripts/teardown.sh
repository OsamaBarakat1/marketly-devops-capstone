#!/usr/bin/env bash
#
# Destroys the AWS stack. Run it at the end of every work session: four
# t3.micro instances, an ALB and an RDS instance running continuously will
# exhaust the free tier well before the month does.
#
# It shows the destroy plan before asking, and the confirmation is the
# project prefix typed in full rather than "y" — this deletes a database,
# and "y" is too easy to hit by reflex.
#
# Two things deliberately survive, because destroying them would cost more
# than leaving them:
#
#   * the Terraform state bucket and lock table (terraform/bootstrap/) —
#     they hold the state that makes this destroy possible, and cost cents
#   * /<prefix>/app/shared-secret in SSM — the JWT signing key, which is
#     free, and keeping it means the next deploy issues tokens the same way
#     this one did. Pass --purge-secrets to remove it too.
#
#   scripts/teardown.sh
#   scripts/teardown.sh --yes --purge-secrets
#
# Environment overrides (all optional):
#   AWS_REGION      default us-east-1
#   PROJECT_PREFIX  default marketly-dev

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_PREFIX="${PROJECT_PREFIX:-marketly-dev}"

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi
readonly RED GREEN YELLOW BOLD DIM RESET

step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
info() { printf '    %s\n' "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/teardown.sh [options]

  --yes, -y         Skip the confirmation prompt. Required when not on a terminal.
  --purge-secrets   Also delete the shared JWT signing key from SSM.
  -h, --help        Show this message.

Destroys everything in terraform/. The remote state bucket and lock table in
terraform/bootstrap/ are not touched.
EOF
}

assume_yes=false
purge_secrets=false

while [ $# -gt 0 ]; do
  case "$1" in
    -y | --yes)      assume_yes=true ;;
    --purge-secrets) purge_secrets=true ;;
    -h | --help)     usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v terraform >/dev/null 2>&1 || die "terraform is not installed — run scripts/setup.sh"
command -v aws >/dev/null 2>&1 || die "the AWS CLI is not installed — run scripts/setup.sh"

aws sts get-caller-identity >/dev/null 2>&1 ||
  die "no AWS credentials resolve. Run 'aws configure' or export AWS_PROFILE."

# github_repo has no default, so terraform would stop and prompt for it —
# and a destroy that hangs on a prompt is a destroy that silently did not
# happen, which is exactly the failure this script exists to prevent.
[ -f "$REPO_ROOT/terraform/terraform.tfvars" ] ||
  die "terraform/terraform.tfvars is missing; terraform cannot resolve github_repo without it"

# --- plan ----------------------------------------------------------------

step "Planning the destroy"

terraform -chdir="$REPO_ROOT/terraform" init -input=false >/dev/null
info "terraform initialised"

plan_output="$(mktemp)"
trap 'rm -f "$plan_output"' EXIT

if ! terraform -chdir="$REPO_ROOT/terraform" plan -destroy -no-color \
      -input=false -lock-timeout=5m > "$plan_output" 2>&1; then
  cat "$plan_output" >&2
  die "the destroy plan failed; nothing has been changed"
fi

# Every line the plan marks for destruction, so the confirmation below is
# made against the real list rather than an assumption about it.
doomed="$(sed -n 's/^  # \(.*\) will be destroyed$/\1/p' "$plan_output" || true)"
summary="$(sed -n 's/^\(Plan: .*\)$/\1/p' "$plan_output" || true)"
summary="${summary%%$'\n'*}"

if [ -z "$doomed" ]; then
  step "Nothing to destroy"
  info "the plan reports no resources; the stack is already torn down"
  note "state bucket and lock table in terraform/bootstrap/ are unaffected either way"
  exit 0
fi

destroy_count="$(printf '%s\n' "$doomed" | wc -l | tr -d ' ')"

printf '\n'
printf '%s\n' "$doomed" | sed 's/^/    /'
printf '\n%s%s%s\n' "$BOLD" "${summary:-Plan: $destroy_count to destroy.}" "$RESET"

# --- confirm -------------------------------------------------------------

warn "this deletes the RDS instance, and skip_final_snapshot is set — there will be no snapshot"
warn "ECR repositories are force_delete, so every image built so far goes with them"

if [ "$assume_yes" = false ]; then
  if [ ! -t 0 ]; then
    die "not running on a terminal and --yes was not passed; refusing to destroy $destroy_count resources"
  fi

  printf '\nType %s%s%s to destroy these %s resources: ' "$BOLD" "$PROJECT_PREFIX" "$RESET" "$destroy_count"
  read -r reply
  [ "$reply" = "$PROJECT_PREFIX" ] || die "cancelled — nothing was destroyed"
fi

# --- destroy -------------------------------------------------------------

step "Destroying"

# -lock-timeout matters more here than anywhere else: a destroy that dies
# halfway through leaves the stack in a state neither running nor gone.
terraform -chdir="$REPO_ROOT/terraform" destroy -auto-approve -input=false -lock-timeout=5m
ok "$destroy_count resources destroyed"

# --- what is left --------------------------------------------------------

step "What remains"

shared_secret_param="/$PROJECT_PREFIX/app/shared-secret"

if [ "$purge_secrets" = true ]; then
  if aws ssm delete-parameter --region "$AWS_REGION" --name "$shared_secret_param" >/dev/null 2>&1; then
    ok "deleted $shared_secret_param"
    note "the next deploy generates a new signing key, invalidating every token issued before it"
  else
    info "$shared_secret_param did not exist"
  fi
else
  if aws ssm get-parameter --region "$AWS_REGION" --name "$shared_secret_param" >/dev/null 2>&1; then
    info "kept $shared_secret_param — free, and the next deploy reuses it"
    note "pass --purge-secrets to delete it"
  fi
fi

info "kept the Terraform state bucket and lock table (terraform/bootstrap/)"
note "they cost cents and hold the state that makes the next destroy possible"
note "to remove them for good: terraform -chdir=terraform/bootstrap destroy"

printf '\n%sTorn down.%s Nothing in this stack is billing by the hour any more.\n' "$GREEN" "$RESET"
