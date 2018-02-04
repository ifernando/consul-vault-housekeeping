#!/bin/bash

usage(){
  echo -e "\n$0: [check,renew,regen] [namespace]\n"
  echo -e "Runs commands against vault to manage tokens for user namespaces or namespace. Default scope is all namespaces.\n"
  exit 1

}
#[ -f /etc/profile.d/hostinfo.sh ] && . /etc/profile.d/hostinfo.sh
#[ -f /etc/network-environment ] && . /etc/network-environment

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


# As root
VAULT_PODS=`kubectl get pods --namespace=kube-system | grep ^vault | wc -l`

if [ -z $VAULT_ADDR ] && [[ $VAULT_PODS -ge 1 ]]; then
  export VAULT_SERVICE_IP=`kubectl get svc vault --namespace=kube-system -o jsonpath={.spec.clusterIP}`
  export VAULT_ADDR="https://$VAULT_SERVICE_IP:8243"
elif [ -z $VAULT_ADDR ] && [[ $VAULT_PODS -le 1 ]]; then
  export VAULT_ADDR="https://<FQDN-OF-VAULT-HOST>:8243"
fi
if [ -z $VAULT_TOKEN ]; then
  export VAULT_TOKEN=`grep 'Initial Root Token:' /root/vault_keys.txt | awk '{print $NF}'`
fi
export VAULT_SKIP_VERIFY=true

# Check
check(){
  echo vault-$1-read
  if kubectl get --no-headers secret vault-$1-read --namespace=$1 1> /dev/null; then
    TOKEN=`kubectl get --no-headers secret vault-$1-read --namespace=$1 -o yaml | grep -e ".\s*vault-$1-read:" | awk '{print $NF}' | base64 -d`
    if vault token-lookup $TOKEN > /dev/null 2>&1; then
      #echo $TOKEN
      TTL=`vault token-lookup $TOKEN | grep "^ttl" | awk '{print $NF}'`
      echo "TTL: $TTL seconds"
    else
      echo "Bad token"
    fi
  else
    echo "No secret"
  fi
  echo vault-$1-write
  if kubectl get --no-headers secret vault-$1-write --namespace=$1 1> /dev/null; then
    TOKEN=`kubectl get --no-headers secret vault-$1-write --namespace=$1 -o yaml | grep -e ".\s*vault-$1-write:" | awk '{print $NF}' | base64 -d`
    if vault token-lookup $TOKEN > /dev/null 2>&1; then
      #echo $TOKEN
      TTL=`vault token-lookup $TOKEN | grep "^ttl" | awk '{print $NF}'`
      echo "TTL: $TTL seconds"
    else
      echo "Bad token"
    fi
  else
    echo "No secret"
  fi
}

# Re-gen
regen(){
  /usr/local/bin/add_vault_tokens.sh $1
}

# Renew
renew(){
  READ_EXPIRED=0
  WRITE_EXPIRED=0
  echo vault-$1-read
  kubectl get --no-headers secret vault-$1-read --namespace=$1 > /dev/null 2>&1
  [ $? -eq 0 ] && TOKEN=`kubectl get --no-headers secret vault-$1-read --namespace=$1 -o yaml | grep -e ".\s*vault-$1-read:" | awk '{print $NF}' | base64 -d`
  #echo $TOKEN
  if vault token-lookup $TOKEN > /dev/null 2>&1; then
    vault token-renew $TOKEN > /dev/null 2>&1
    echo "renewed"
  else
    READ_EXPIRED=1
    echo "expired"
  fi

  echo vault-$1-write
  kubectl get --no-headers secret vault-$1-write --namespace=$1 > /dev/null 2>&1
  [ $? -eq 0 ] && TOKEN=`kubectl get --no-headers secret vault-$1-write --namespace=$1 -o yaml | grep -e ".\s*vault-$1-write:" | awk '{print $NF}' | base64 -d`
  #echo $TOKEN
  if vault token-lookup $TOKEN > /dev/null 2>&1; then
    vault token-renew $TOKEN > /dev/null 2>&1
    echo "renewed"
  else
    WRITE_EXPIRED=1
    echo "expired"
  fi

  [[ ( $READ_EXPIRED -eq 1 ) && ( $WRITE_EXPIRED -eq 1) ]] && /usr/local/bin/add_vault_tokens.sh $1

}

# Action
action() {
  if [ ! "x$2x" == "xx" ]; then
    if [[ `kubectl get ns | grep $2` ]]; then
      $1 $2
    else
      echo "Namespace not found: $2"
      exit 1
    fi
  else
    for ns in `kubectl get ns --no-headers | grep -v "^default" | grep -v "^kube-system" | grep -v "^test-runner" | grep -v "test-namespace" | awk '{print $1}'`; do
      $1 $ns
    done
  fi
}

# Main
! id -u > /dev/null 2>&1 && echo "Must be run as root" && exit 1
#echo "main: $1 $2"
case $1 in
  apply|check|renew|regen)
       ACTION=$1
       action $ACTION $2
       ;;
  *)
       usage
       ;;
esac

exit 0

