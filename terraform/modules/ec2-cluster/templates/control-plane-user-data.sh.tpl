#!/bin/bash
# Bootstraps the k3s control plane and publishes the join token so agents
# can find their way in without any shared secret being baked into an AMI,
# a launch template, or this repository.
set -euxo pipefail

exec > >(tee /var/log/k3s-bootstrap.log) 2>&1

dnf install -y iptables-services

# AL2023 normally ships the CLI, but the bootstrap depends on it, so install
# it rather than assume.
if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli-2 || dnf install -y aws-cli
fi

PRIVATE_IP="$(ec2-metadata --local-ipv4 2>/dev/null | awk '{print $2}' || \
  curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/local-ipv4)"

# k3s applies anything dropped in this directory on startup. Traefik ships
# with k3s as a LoadBalancer service, but there is no cloud controller here
# to satisfy that, and the ALB target group needs one fixed port that exists
# on every node. Pinning Traefik to a NodePort gives it exactly that.
mkdir -p /var/lib/rancher/k3s/server/manifests
cat > /var/lib/rancher/k3s/server/manifests/traefik-nodeport.yaml <<'MANIFEST'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      type: NodePort
    ports:
      web:
        nodePort: ${ingress_nodeport}
      websecure:
        expose:
          default: false
MANIFEST

# --tls-san adds the private address to the API server certificate, so
# kubectl from the self-hosted runner and agents joining over that address
# do not fail certificate verification.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --tls-san $PRIVATE_IP \
  --node-ip $PRIVATE_IP \
  --write-kubeconfig-mode 0644" sh -

# The installer returns before the API is serving; agents that read the
# token too early would get a value that is not yet valid.
for _ in $(seq 1 60); do
  if k3s kubectl get nodes >/dev/null 2>&1; then break; fi
  sleep 5
done

# Publish the join token as a SecureString. It never appears in the launch
# template, in user data, or in Terraform state — agents fetch it at boot
# using their instance role, which is scoped to read this one parameter.
TOKEN="$(cat /var/lib/rancher/k3s/server/node-token)"
aws ssm put-parameter \
  --name "${token_parameter_name}" \
  --value "$TOKEN" \
  --type SecureString \
  --overwrite \
  --region "${aws_region}"

echo "k3s server ready at $PRIVATE_IP, join token published"
