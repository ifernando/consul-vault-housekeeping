#!/bin/bash

[ -f /etc/profile.d/hostinfo.sh ] && . /etc/profile.d/hostinfo.sh

export VAULT_HOST=<FQDN-OF-VAULT-HOST>
export VAULT_ADDR=https://<FQDN-OF-VAULT-HOST>:8243
export VAULT_SERVICE_PORT=8243
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=`grep 'Initial Root Token:' /root/vault_keys.txt | awk '{print $NF}'`

export CONSUL_MASTER_TOKEN=<master-token-for-CONSUL>
export CONSUL_SERVICE_PORT=8543
export CONSUL_HOST=<FQDN-OF-CONSUL-HOST>
export CONSUL_HTTP_ADDR=https://<FQDN-OF-CONSUL-HOST>:8543
export CONSUL_HTTP_SSL=true
export CONSUL_HTTP_SSL_VERIFY=false
export CONSUL_HTTP_TOKEN=<consul-HTTP-Token>



[ -f /etc/network-environment ] && . /etc/network-environment

TAG_NAME="ConsulCluster"
TAG_VALUE="myproject-consulvault"

VAULT_KEYS_FILE=/root/vault_keys.txt

export VAULT_TOKEN=`grep 'Initial Root Token:' ${VAULT_KEYS_FILE} | awk '{print $NF}'`

unseal_vault() {
  echo "unseal_vault"
  for i in 1 2 3; do
    vault unseal `grep "Key ${i}" ${VAULT_KEYS_FILE} | head -1 | awk '{print $NF}'`
    sleep 2
  done
}

instance_ips=`aws ec2 describe-instances --region=$REGION --filters "Name=tag:$TAG_NAME,Values=$TAG_VALUE" "Name=tag:Environment,Values=${ENVIRONMENT}" \
  "Name=instance-state-name,Values=running" \
  |  jq -r ".Reservations[] | .Instances[] | .PrivateIpAddress"`

for ip in $instance_ips; do
  VAULT_ADDR="https://${ip}:${VAULT_SERVICE_PORT}"
  status=`vault status | grep "^Sealed" | awk -F: '{print $NF}' | tr -d '[:space:]'`
  if [[ $status != "false" ]]; then
    unseal_vault
  fi
done

