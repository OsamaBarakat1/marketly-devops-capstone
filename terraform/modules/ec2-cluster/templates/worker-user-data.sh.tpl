#!/bin/bash
# Joins this instance to the cluster as a k3s agent.
#
# Auto Scaling can launch a replacement worker at any time, including while
# the control plane is still coming up after a full apply, so this waits for
# the join token rather than failing outright.
set -euxo pipefail

exec > >(tee /var/log/k3s-bootstrap.log) 2>&1

if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli-2 || dnf install -y aws-cli
fi

PRIVATE_IP="$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/local-ipv4)"

# The parameter does not exist until the control plane finishes installing,
# so poll instead of assuming ordering that Auto Scaling never guarantees.
TOKEN=""
for _ in $(seq 1 60); do
  if TOKEN="$(aws ssm get-parameter \
      --name "${token_parameter_name}" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text \
      --region "${aws_region}" 2>/dev/null)"; then
    [ -n "$TOKEN" ] && break
  fi
  echo "join token not published yet, retrying"
  sleep 10
done

if [ -z "$TOKEN" ]; then
  echo "gave up waiting for the join token" >&2
  exit 1
fi

curl -sfL https://get.k3s.io | K3S_URL="${server_url}" K3S_TOKEN="$TOKEN" \
  INSTALL_K3S_EXEC="agent --node-ip $PRIVATE_IP" sh -

echo "k3s agent joined ${server_url}"
