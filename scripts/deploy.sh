#!/usr/bin/env bash
#
# Provisions the AWS stack, renders the Kubernetes manifests with the values
# only AWS knows, applies them, and waits for the rollout to finish.
#
# This is the *only* implementation of the render-and-apply logic.
# .github/workflows/deploy.yml calls this script rather than repeating it,
# so a manifest that gains a new variable is updated in one place, and every
# CI deploy exercises exactly the code path a developer runs by hand.
#
# Nothing secret is passed in. The database password is read from Secrets
# Manager and the JWT signing key from SSM, both at the moment they are
# needed, both by the ambient credentials of whoever is running this.
#
#   scripts/deploy.sh                       # terraform apply, then deploy HEAD
#   scripts/deploy.sh --skip-terraform      # deploy only, no infrastructure changes
#   scripts/deploy.sh --skip-k8s            # infrastructure only
#   scripts/deploy.sh --tag 1e56d47 --yes   # redeploy an earlier image, unattended
#
# Environment overrides (all optional):
#   AWS_REGION      default us-east-1
#   PROJECT_PREFIX  default marketly-dev — how AWS resources are named
#   IMAGE_PREFIX    default $PROJECT_PREFIX — how ECR repositories are named
#   NAMESPACE       default marketly

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly COMPONENTS=(auth-service catalog-service orders-service frontend)

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_PREFIX="${PROJECT_PREFIX:-marketly-dev}"
IMAGE_PREFIX="${IMAGE_PREFIX:-$PROJECT_PREFIX}"
NAMESPACE="${NAMESPACE:-marketly}"

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
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options]

  --skip-terraform   Do not run terraform; deploy against existing infrastructure.
  --skip-k8s         Stop after terraform apply.
  --tag <sha>        Image tag to deploy. Default: the current commit.
  --yes, -y          Do not prompt for confirmation.
  -h, --help         Show this message.

Images are tagged by commit SHA, so the tag passed here must be a commit CI
has already built and pushed. ECR repositories are immutable: there is no
":latest" to fall back on.
EOF
}

# --- arguments -----------------------------------------------------------

run_terraform=true
run_k8s=true
assume_yes=false
image_tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-terraform) run_terraform=false ;;
    --skip-k8s)       run_k8s=false ;;
    --tag)
      [ $# -ge 2 ] || die "--tag needs a value"
      image_tag="$2"
      shift
      ;;
    --tag=*)   image_tag="${1#--tag=}" ;;
    -y | --yes) assume_yes=true ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$run_terraform" = false ] && [ "$run_k8s" = false ]; then
  die "--skip-terraform and --skip-k8s together leave nothing to do"
fi

for tool in aws kubectl envsubst python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed — run scripts/setup.sh"
done

# --- the commit to deploy ------------------------------------------------

# git is only needed to work out which commit to deploy. Given --tag, this
# script runs fine somewhere that has no git and no checkout history.
if [ -z "$image_tag" ]; then
  command -v git >/dev/null 2>&1 ||
    die "git is not installed, so the commit to deploy cannot be determined — pass --tag <sha>"
  image_tag="$(git -C "$REPO_ROOT" rev-parse HEAD)"

  # An image is built from a commit, so uncommitted work is not in any
  # image. Deploying HEAD here would quietly ship the last commit instead of
  # what is on disk, which is a confusing way to find that out.
  if ! git -C "$REPO_ROOT" diff --quiet HEAD -- 2>/dev/null; then
    warn "the working tree has uncommitted changes; deploying ${image_tag:0:7}, which does not include them"
  fi
fi
readonly IMAGE_TAG="$image_tag"

# --- terraform -----------------------------------------------------------

if [ "$run_terraform" = true ]; then
  step "Provisioning infrastructure with Terraform"

  command -v terraform >/dev/null 2>&1 || die "terraform is not installed — run scripts/setup.sh"

  # github_repo has no default, so without a tfvars file terraform stops and
  # prompts — which hangs a --yes run instead of failing it.
  [ -f "$REPO_ROOT/terraform/terraform.tfvars" ] ||
    die "terraform/terraform.tfvars is missing. cp terraform/terraform.tfvars.example terraform/terraform.tfvars and set github_repo."

  terraform -chdir="$REPO_ROOT/terraform" init -input=false
  if [ "$assume_yes" = true ]; then
    terraform -chdir="$REPO_ROOT/terraform" apply -input=false -lock-timeout=5m -auto-approve
  else
    # Terraform's own plan-and-confirm is a better prompt than anything this
    # script could print: it shows exactly what will change.
    terraform -chdir="$REPO_ROOT/terraform" apply -input=false -lock-timeout=5m
  fi
  ok "infrastructure applied"
fi

if [ "$run_k8s" = false ]; then
  step "Done"
  note "--skip-k8s was passed; nothing was deployed to the cluster"
  exit 0
fi

# --- can we reach the cluster? ------------------------------------------

# Checked before any AWS lookups, so an unreachable cluster fails in two
# seconds with instructions rather than after a minute of API calls.
if ! kubectl cluster-info >/dev/null 2>&1; then
  instance_id="$(terraform -chdir="$REPO_ROOT/terraform" output -raw k3s_server_instance_id 2>/dev/null || true)"
  if [ -z "$instance_id" ]; then
    instance_id="$(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "Name=tag:Name,Values=$PROJECT_PREFIX-k3s-server" "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
  fi
  [ "$instance_id" = "None" ] && instance_id=""

  printf '\n%serror:%s kubectl cannot reach a cluster.\n\n' "$RED" "$RESET" >&2
  cat >&2 <<EOF
The k3s API server has no public address and there is no SSH key, by design.
Run this script on the control-plane instance, reached over SSM:

    aws ssm start-session --target ${instance_id:-<control-plane-instance-id>} --region $AWS_REGION

then, on the instance:

    sudo su -
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    cd /path/to/this/repo && scripts/deploy.sh --skip-terraform --tag $IMAGE_TAG --yes

The Terraform half of this script does run from a laptop; only the cluster
half needs to be inside the VPC.
EOF
  exit 1
fi

# --- discover what AWS generated ----------------------------------------

step "Discovering infrastructure"

# Read from AWS rather than from a config file, so a rebuilt environment
# needs no manual reconfiguration. Every one of these values is generated by
# AWS and unknowable when the manifests are written.

account="$(aws sts get-caller-identity --query Account --output text)" ||
  die "no AWS credentials resolve. Run 'aws configure' or export AWS_PROFILE."
ECR_REGISTRY="${ECR_REGISTRY:-$account.dkr.ecr.$AWS_REGION.amazonaws.com}"
info "registry $ECR_REGISTRY"

rds="$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$PROJECT_PREFIX-postgres" \
  --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port,DBName,MasterUsername,MasterUserSecret.SecretArn]' \
  --output text 2>/dev/null)" ||
  die "no RDS instance named $PROJECT_PREFIX-postgres in $AWS_REGION. Run without --skip-terraform first."

db_host="$(printf '%s' "$rds" | cut -f1)"
db_port="$(printf '%s' "$rds" | cut -f2)"
db_name="$(printf '%s' "$rds" | cut -f3)"
db_user="$(printf '%s' "$rds" | cut -f4)"
db_secret_arn="$(printf '%s' "$rds" | cut -f5)"
info "database $db_host:$db_port/$db_name"

alb="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --names "$PROJECT_PREFIX-alb" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)" ||
  die "no load balancer named $PROJECT_PREFIX-alb in $AWS_REGION. Run without --skip-terraform first."

APP_ORIGIN="http://$alb"
info "application $APP_ORIGIN"

# --- confirmation --------------------------------------------------------

if [ "$assume_yes" = false ]; then
  printf '\n'
  printf 'About to deploy %s%s%s to namespace %s%s%s on %s.\n' \
    "$BOLD" "${IMAGE_TAG:0:12}" "$RESET" "$BOLD" "$NAMESPACE" "$RESET" \
    "$(kubectl config current-context 2>/dev/null || echo 'the current cluster')"
  read -r -p 'Continue? [y/N] ' reply
  case "$reply" in
    y | Y | yes | YES) ;;
    *) die "cancelled" ;;
  esac
fi

# --- secrets -------------------------------------------------------------

step "Reading credentials"

# Reads an application secret from SSM, generating and storing it the first
# time it is needed. Nothing here is ever typed by a person, committed to
# this repository, or written into Terraform state.
#
# The value is returned in SSM_SECRET_VALUE rather than on stdout, so that
# the progress lines below cannot end up captured as part of a secret.
ssm_secret() {
  local name="$1" description="$2" bytes="$3" param
  param="/$PROJECT_PREFIX/app/$name"

  if SSM_SECRET_VALUE="$(aws ssm get-parameter --region "$AWS_REGION" \
        --name "$param" --with-decryption \
        --query Parameter.Value --output text 2>/dev/null)"; then
    ok "$description read from $param"
    return
  fi

  info "generating the $description for the first time"
  command -v openssl >/dev/null 2>&1 ||
    die "openssl is needed to generate the $description on the first deploy"
  SSM_SECRET_VALUE="$(openssl rand -base64 "$bytes" | tr -d '\n')"
  aws ssm put-parameter --region "$AWS_REGION" \
    --name "$param" --type SecureString --value "$SSM_SECRET_VALUE" \
    --description "$description for the Marketly services" >/dev/null
  ok "$description generated and stored at $param"
}

# The signing key shared by auth, catalog and orders. All three read the same
# value from this one rendering pass, so they cannot drift.
ssm_secret shared-secret "JWT signing key" 48
SHARED_SECRET="$SSM_SECRET_VALUE"

# The initial admin password. Left unset, auth-service seeds its admin user
# with the default published in its source — on an application the load
# balancer exposes to the internet.
ssm_secret admin-seed-password "initial admin password" 24
ADMIN_SEED_PASSWORD="$SSM_SECRET_VALUE"
unset SSM_SECRET_VALUE

# RDS generated this password into Secrets Manager and Terraform never saw
# it, so it is read here, at the moment it is needed.
#
# Read and parsed in two steps rather than one pipeline, so that a denied
# secretsmanager:GetSecretValue reports itself as that, instead of as a
# Python traceback about empty input.
db_secret_json="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$db_secret_arn" --query SecretString --output text 2>/dev/null)" ||
  die "could not read the RDS password from Secrets Manager ($db_secret_arn). Check secretsmanager:GetSecretValue on this identity."

db_password="$(printf '%s' "$db_secret_json" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])' 2>/dev/null)" ||
  die "the Secrets Manager value is not the {\"username\":...,\"password\":...} JSON that RDS writes"
unset db_secret_json

[ -n "$db_password" ] || die "the RDS password in Secrets Manager is empty"

# Percent-encoded: a generated password containing '@' or '/' would
# otherwise be parsed as part of the host or the path.
DATABASE_URL="postgresql://$db_user:$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$db_password")@$db_host:$db_port/$db_name"
unset db_password
ok "database password read from Secrets Manager"

export ECR_REGISTRY IMAGE_PREFIX IMAGE_TAG APP_ORIGIN SHARED_SECRET DATABASE_URL ADMIN_SEED_PASSWORD

# --- render --------------------------------------------------------------

step "Rendering manifests"

# Checked here rather than trusted, because envsubst cannot check it. A
# variable named in the substitution list below is replaced with an empty
# string when it is unset, so a lookup that silently returned nothing would
# render a Secret containing "" — which applies cleanly, starts cleanly, and
# then fails as a blanket 401 or a database connection error hours later.
for required in ECR_REGISTRY IMAGE_PREFIX IMAGE_TAG APP_ORIGIN SHARED_SECRET DATABASE_URL ADMIN_SEED_PASSWORD; do
  [ -n "${!required}" ] || die "$required resolved to an empty value; refusing to render the manifests"
done

# The rendered copy holds the signing key and the database URL in plaintext,
# so it is created private and removed on every exit path, including a
# failed kubectl apply and a Ctrl-C.
umask 077
rendered="$(mktemp -d)"
readonly rendered
cleanup() { rm -rf "$rendered"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Only these seven names are substituted. Left unrestricted, envsubst would
# also eat anything else in the manifests shaped like a shell variable —
# a Traefik annotation or a container command, for instance.
readonly SUBSTITUTED_VARS='${ECR_REGISTRY} ${IMAGE_PREFIX} ${IMAGE_TAG} ${APP_ORIGIN} ${SHARED_SECRET} ${DATABASE_URL} ${ADMIN_SEED_PASSWORD}'

manifest_count=0
while IFS= read -r manifest; do
  mkdir -p "$rendered/$(dirname "$manifest")"
  envsubst "$SUBSTITUTED_VARS" < "$REPO_ROOT/k8s/$manifest" > "$rendered/$manifest"
  manifest_count=$((manifest_count + 1))
done < <(cd "$REPO_ROOT/k8s" && find . -name '*.yaml' | sed 's|^\./||' | sort)

[ "$manifest_count" -gt 0 ] || die "no manifests found under k8s/"

# Catches the drift case: a manifest that gained a new placeholder without
# it being added to SUBSTITUTED_VARS above. Such a name is not substituted
# at all, so it survives as a literal '${NAME}' and would reach the cluster
# as one. Empty values are caught by the loop above instead — envsubst
# replaces a listed-but-unset variable with "", leaving nothing to grep for.
if grep -rq '\${' "$rendered"; then
  printf '\n%serror:%s a placeholder was left unsubstituted:\n' "$RED" "$RESET" >&2
  grep -rn '\${' "$rendered" >&2
  exit 1
fi
ok "$manifest_count manifests rendered"

# --- apply ---------------------------------------------------------------

step "Applying to the cluster"

# The namespace first and on its own: everything else declares itself inside
# it, and a single `kubectl apply -R` gives no ordering guarantee.
kubectl apply -f "$rendered/namespace.yaml"
kubectl apply -R -f "$rendered"

# --- verify --------------------------------------------------------------

step "Waiting for the rollout"

# The gate that decides whether this deploy worked. Without it the script
# would finish the moment the manifests were accepted, which says nothing
# about whether the new pods actually started — an image tag that does not
# exist in ECR is accepted happily and then never runs.
rollout_failed=false
for component in "${COMPONENTS[@]}"; do
  if kubectl rollout status "deployment/$component" -n "$NAMESPACE" --timeout=5m; then
    ok "$component"
  else
    warn "$component did not roll out"
    rollout_failed=true
  fi
done

if [ "$rollout_failed" = true ]; then
  printf '\n%s--- pods ---%s\n' "$DIM" "$RESET" >&2
  kubectl get pods -n "$NAMESPACE" -o wide >&2 || true
  printf '\n%s--- recent events ---%s\n' "$DIM" "$RESET" >&2
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -30 >&2 || true
  die "the rollout did not complete. scripts/healthcheck.sh has more detail."
fi

step "Deployed"
info "commit      ${IMAGE_TAG:0:12}"
info "application $APP_ORIGIN"
note "verify with: scripts/healthcheck.sh"
