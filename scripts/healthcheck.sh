#!/usr/bin/env bash
#
# The first thing to run when something is broken. Four layers, checked from
# the inside out, so the output says which one failed rather than only that
# "the site is down":
#
#   1. nodes        — are the k3s workers Ready at all
#   2. deployments  — are the replicas that should exist actually running
#   3. /health      — does each backend answer for itself, reached directly
#                     through a port-forward
#   4. the ALB      — does a request survive the whole path: load balancer,
#                     NodePort, Traefik, Service, pod
#
# Layer 3 has to use a port-forward. The Ingress deliberately routes only
# /api/auth, /api/products, /api/categories, /api/orders and /, so /health is
# not reachable from outside the cluster and never has been.
#
#   scripts/healthcheck.sh
#
# Environment overrides (all optional):
#   NAMESPACE       default marketly
#   AWS_REGION      default us-east-1
#   PROJECT_PREFIX  default marketly-dev
#   APP_ORIGIN      skip the ALB lookup and use this address instead

set -euo pipefail

NAMESPACE="${NAMESPACE:-marketly}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_PREFIX="${PROJECT_PREFIX:-marketly-dev}"

readonly COMPONENTS=(auth-service catalog-service orders-service frontend)
# Backend services only. The frontend serves static files and has no /health.
readonly BACKENDS=(auth-service:5001 catalog-service:5002 orders-service:5003)

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi
readonly RED GREEN YELLOW BOLD DIM RESET

failed=0
skipped=0
checked=0

step()  { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
ok()    { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; checked=$((checked + 1)); }
bad()   { printf '    %s✗%s %s\n' "$RED" "$RESET" "$1"; checked=$((checked + 1)); failed=$((failed + 1)); }
skip()  { printf '    %s-%s %s\n' "$YELLOW" "$RESET" "$1"; skipped=$((skipped + 1)); }
note()  { printf '      %s%s%s\n' "$DIM" "$1" "$RESET"; }

usage() {
  cat <<'EOF'
Usage: scripts/healthcheck.sh [options]

  --wait <seconds>   Give the load balancer up to this long to start
                     answering before judging it. Default 0 — report now.
  -h, --help         Show this message.

Reports node, deployment, /health and load-balancer status for the Marketly
stack. Exits non-zero if any check fails.

Cluster checks need a kubectl that reaches the k3s API, which means running
this on the control-plane instance over SSM. The load-balancer check works
from anywhere.
EOF
}

# Straight after a deploy the pods are running but the ALB has not yet
# re-run its health checks against the NodePort, so the last layer fails for
# a minute or two through no fault of the deploy. --wait covers that window.
# It defaults to 0 so that running this to debug a broken stack answers
# immediately instead of hanging.
wait_seconds=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wait)
      [ $# -ge 2 ] || { printf -- '--wait needs a value\n' >&2; exit 2; }
      wait_seconds="$2"
      shift
      ;;
    --wait=*) wait_seconds="${1#--wait=}" ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$wait_seconds" in
  '' | *[!0-9]*) printf -- '--wait must be a whole number of seconds\n' >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { printf 'curl is not installed\n' >&2; exit 1; }

cluster_reachable=false
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  cluster_reachable=true
fi

# --- 1. nodes ------------------------------------------------------------

step "Nodes"

if [ "$cluster_reachable" = false ]; then
  skip "kubectl cannot reach a cluster from here"
  note "the k3s API is private by design. Reach it with:"
  note "  aws ssm start-session --target \$(terraform -chdir=terraform output -raw k3s_server_instance_id)"
else
  # Ready/NotReady per node. A worker that dropped out of the ASG shows up
  # here first, and explains a Deployment stuck at 1/2 replicas below.
  node_total=0
  node_ready=0
  while IFS=$'\t' read -r name status; do
    node_total=$((node_total + 1))
    if [ "$status" = "True" ]; then
      node_ready=$((node_ready + 1))
    else
      printf '    %s%s is not Ready%s\n' "$DIM" "$name" "$RESET"
    fi
  done < <(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')

  if [ "$node_total" -eq 0 ]; then
    bad "the cluster reports no nodes"
  elif [ "$node_ready" -eq "$node_total" ]; then
    ok "$node_ready/$node_total nodes Ready"
  else
    bad "$node_ready/$node_total nodes Ready"
  fi
fi

# --- 2. deployments ------------------------------------------------------

step "Deployments"

if [ "$cluster_reachable" = false ]; then
  skip "needs cluster access"
else
  for component in "${COMPONENTS[@]}"; do
    if ! spec="$(kubectl get "deployment/$component" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}{"\t"}{.spec.replicas}' 2>/dev/null)"; then
      bad "$component — no such Deployment in namespace $NAMESPACE"
      continue
    fi

    ready="${spec%%$'\t'*}"
    desired="${spec##*$'\t'}"
    # readyReplicas is absent, not zero, when nothing is ready yet.
    ready="${ready:-0}"
    desired="${desired:-0}"

    if [ "$ready" -eq "$desired" ] && [ "$desired" -gt 0 ]; then
      ok "$component $ready/$desired ready"
    else
      bad "$component $ready/$desired ready"
      # The reason a pod is not running is almost always in its state, not
      # in the Deployment: ImagePullBackOff, CrashLoopBackOff, Pending.
      kubectl get pods -n "$NAMESPACE" -l "app=$component" \
        -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,REASON:.status.containerStatuses[0].state.waiting.reason,RESTARTS:.status.containerStatuses[0].restartCount' \
        --no-headers 2>/dev/null | while read -r line; do
          printf '      %s%s%s\n' "$DIM" "$line" "$RESET"
        done || true
    fi
  done
fi

# --- 3. /health through a port-forward -----------------------------------

step "Backend /health endpoints"

# Forwards a random free local port to the Service and curls /health on it.
# A random port avoids colliding with anything already listening — including
# a second copy of this script, or the local docker-compose stack.
probe_health() {
  local service="$1" port="$2"
  local log pid local_port body status

  log="$(mktemp)"
  kubectl port-forward -n "$NAMESPACE" "svc/$service" ":$port" >"$log" 2>&1 &
  pid=$!

  # kubectl prints the port it chose once the tunnel is up, so waiting for
  # that line is also how we wait for readiness.
  local_port=""
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    local_port="$(sed -n 's|^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' "$log")"
    local_port="${local_port%%$'\n'*}"
    [ -n "$local_port" ] && break
    sleep 0.25
  done

  if [ -z "$local_port" ]; then
    bad "$service — could not establish a port-forward"
    note "$(head -n2 "$log" | tr '\n' ' ')"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$log"
    return
  fi

  if body="$(curl -sf --max-time 10 "http://127.0.0.1:$local_port/health" 2>/dev/null)"; then
    status="$(printf '%s' "$body" |
      python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","<no status field>"))' 2>/dev/null ||
      printf '<unparseable>')"
    if [ "$status" = "ok" ]; then
      ok "$service :$port /health → ok"
    else
      # A service that answers but reports something other than ok is
      # usually up with its database unreachable.
      bad "$service :$port /health → $status"
      note "${body:0:200}"
    fi
  else
    bad "$service :$port /health did not answer"
    note "the pod is running but not serving — check: kubectl logs deployment/$service -n $NAMESPACE"
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$log"
}

if [ "$cluster_reachable" = false ]; then
  skip "needs cluster access"
elif ! command -v python3 >/dev/null 2>&1; then
  skip "python3 is not installed, so the /health responses cannot be parsed"
else
  for entry in "${BACKENDS[@]}"; do
    probe_health "${entry%%:*}" "${entry##*:}"
  done
fi

# --- 4. through the load balancer ---------------------------------------

step "Through the load balancer"

app_origin="${APP_ORIGIN:-}"
if [ -z "$app_origin" ] && command -v aws >/dev/null 2>&1; then
  alb="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --names "$PROJECT_PREFIX-alb" --query 'LoadBalancers[0].DNSName' \
    --output text 2>/dev/null || true)"
  [ -n "$alb" ] && [ "$alb" != "None" ] && app_origin="http://$alb"
fi

if [ -z "$app_origin" ]; then
  skip "could not resolve the address of $PROJECT_PREFIX-alb"
  note "set APP_ORIGIN=http://<dns-name> to check it anyway"
else
  printf '    %s%s%s\n' "$DIM" "$app_origin" "$RESET"

  if [ "$wait_seconds" -gt 0 ]; then
    deadline=$(( $(date +%s) + wait_seconds ))
    while ! curl -sf --max-time 15 -o /dev/null "$app_origin/api/products"; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '    %sgave up waiting after %ss%s\n' "$DIM" "$wait_seconds" "$RESET"
        break
      fi
      printf '    %swaiting for the load balancer to report targets healthy...%s\n' "$DIM" "$RESET"
      sleep 10
    done
  fi

  # The frontend, which proves Traefik's catch-all rule and the Nginx pod.
  if curl -sf --max-time 15 -o /dev/null "$app_origin/"; then
    ok "GET / — the frontend is served"
  else
    bad "GET / did not answer"
    note "if the pods above are healthy, suspect the ALB target group: the nodes must be healthy on NodePort 30080"
  fi

  # An API path, which proves the whole chain including a Service that is
  # not the catch-all. Catalog is the right one to use: it needs no token.
  if body="$(curl -sf --max-time 15 "$app_origin/api/products" 2>/dev/null)"; then
    total="$(printf '%s' "$body" |
      python3 -c 'import sys,json; print(json.load(sys.stdin).get("total","?"))' 2>/dev/null || printf '?')"
    if [ "$total" = "0" ]; then
      # Reaches the service and the database, but the catalog is empty —
      # seeding did not run, or it ran against a different database.
      bad "GET /api/products returned 0 products"
    else
      ok "GET /api/products — $total products"
    fi
  else
    bad "GET /api/products did not answer"
    note "the frontend may still work while every API call 502s — check the Ingress paths and catalog-service"
  fi
fi

# --- summary -------------------------------------------------------------

printf '\n'
if [ "$failed" -gt 0 ]; then
  printf '%s%d of %d checks failed%s' "$RED" "$failed" "$checked" "$RESET"
  [ "$skipped" -gt 0 ] && printf ', %d skipped' "$skipped"
  printf '.\n'
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  printf '%sNothing could be checked%s — no cluster access and no load-balancer address.\n' "$RED" "$RESET"
  exit 1
fi

printf '%sAll %d checks passed%s' "$GREEN" "$checked" "$RESET"
[ "$skipped" -gt 0 ] && printf ', %d skipped' "$skipped"
printf '.\n'
