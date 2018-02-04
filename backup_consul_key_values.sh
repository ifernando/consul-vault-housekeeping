#!/bin/bash

#This script will encrypt the consul backup and upload it to an AWS S3 bucket 

TIMESTAMP=`date '+%m%d%Y_%H%M%S'`
export ARCHIVE_DIR_NAME=consul_backups
export BACKUPS_DIR=/root/${ARCHIVE_DIR_NAME}
export BACKUPS_TMP_DIR=/root/${ARCHIVE_DIR_NAME}/${TIMESTAMP}
export EXECUTABLES_DIR="/usr/local/bin"
export KUBERNETES_SECRETS_DIR="/etc/kubernetes/secrets"
export VAULT_KEYS_FILE="/root/vault_keys.txt"

if [ -z ${BACKUPS_RETAIN_DAYS} ]; then
  export BACKUPS_RETAIN_DAYS=14
fi

if [ -z ${BACKUPS_PASSWORD} ]; then
  export BACKUPS_PASSWORD="ph03n1x"
fi

usage() {
  echo "$0 [backup|restore] [restore_file.snap]"
  echo "Wrapper for consul backup/restore."
  echo ""
  exit 1
}

backup() {

  BACKUP_FILE=${BACKUPS_TMP_DIR}/consul_backup_${TIMESTAMP}.snap
  BACKUP_ARCHIVE=${BACKUPS_DIR}/consul_backup_${TIMESTAMP}.tgz
  BACKUP_LATEST=${BACKUPS_DIR}/consul_latest.tgz

  /usr/local/bin/aws s3 cp --recursive s3://${BACKUP_BUCKET}/${ENVIRONMENT}/${ARCHIVE_DIR_NAME}/ ${BACKUPS_DIR}/
  if [ $? -eq 0 ]; then
    SYNCED=1
  fi

  find ${BACKUPS_DIR}/ -type f -name "consul_backup_*.*" | head -n -$(($BACKUPS_RETAIN_DAYS*48)) | xargs rm -f

  # Ensure no versions of this file are lost:
  CKSUM=`cksum ${VAULT_KEYS_FILE} | awk '{print $1}'`
  cp ${VAULT_KEYS_FILE} ${VAULT_KEYS_FILE}_$CKSUM

  curl -k ${CONSUL_HTTP_ADDR}/v1/snapshot?token=${CONSUL_MASTER_TOKEN} > ${BACKUP_FILE}

  if [ $? -eq 0 ]; then
    echo "$ACTION backing up to ${BACKUP_ARCHIVE}"
  else
    echo "$ACTION returned an error."
    exit 1
  fi

  cd ${BACKUPS_TMP_DIR}
  cp ${VAULT_KEYS_FILE}_$CKSUM .
  cp ${VAULT_KEYS_FILE} .
  tar -czf ${BACKUP_ARCHIVE} $(echo ${BACKUP_FILE} | awk -F/ '{print $NF}') $(echo ${VAULT_KEYS_FILE} | awk -F/ '{print $NF}') $(echo ${VAULT_KEYS_FILE}_$CKSUM | awk -F/ '{print $NF}') && cp ${BACKUP_ARCHIVE} ${BACKUP_LATEST}
  cd ${BACKUPS_DIR} && rm -rf ${BACKUPS_TMP_DIR}
  gpg --batch --yes -c --passphrase ${BACKUPS_PASSWORD} ${BACKUP_ARCHIVE} && rm -f ${BACKUP_ARCHIVE}

  # Also make this latest stack backup
  gpg --batch --yes -c --passphrase ${BACKUPS_PASSWORD} ${BACKUP_LATEST} && rm -f ${BACKUP_LATEST}

  chown root:root ${BACKUPS_DIR}/*
  chmod 640 ${BACKUPS_DIR}/*

  [[ $SYNCED -eq 1 ]] && /usr/local/bin/aws s3 sync --delete ${BACKUPS_DIR}/ s3://${BACKUP_BUCKET}/${ENVIRONMENT}/${ARCHIVE_DIR_NAME}/

  if [ $? -eq 0 ]; then
    echo "$ACTION S3 sync complete for ${BACKUP_ARCHIVE}"
  else
    echo "$ACTION returned an error."
    rm -rf ${BACKUPS_TMP_DIR}
    exit 1
  fi

  rm -rf ${BACKUPS_TMP_DIR}
}

restore-config() {
    export
    [ -f ${VAULT_KEYS_FILE} ] && cp ${VAULT_KEYS_FILE} /root/vault_keys_pre_restore_${TIMESTAMP}.txt

    /usr/local/bin/aws s3 cp s3://${BACKUP_BUCKET}/${ENVIRONMENT}/${ARCHIVE_DIR_NAME}/consul_latest.tgz.gpg ${BACKUP_FILE}

    if [ ! -f ${BACKUP_FILE} ]; then
      echo "Backup file ${BACKUP_FILE} not found."
      exit 1
    fi

    BACKUP_ARCHIVE="${BACKUPS_TMP_DIR}/$(echo ${BACKUP_FILE} | awk -F/ '{print $NF}' | awk -F".gpg$" '{print $1}')"

    if [ `ls ${BACKUP_FILE} | awk -F. '{print $NF}'` == 'gpg' ]; then
      gpg --batch --yes -d -o ${BACKUP_ARCHIVE} --passphrase ${BACKUPS_PASSWORD} ${BACKUP_FILE}
    else
      cp ${BACKUP_FILE} ${BACKUP_ARCHIVE}
    fi

    cd ${BACKUPS_TMP_DIR}
    tar -xzf ${BACKUP_ARCHIVE}

    cp ./vault_keys.txt ${VAULT_KEYS_FILE}

    cd ~/ && rm -rf ${BACKUPS_TMP_DIR}
}

restore() {
  [ -f ${VAULT_KEYS_FILE} ] && cp ${VAULT_KEYS_FILE} /root/vault_keys_pre_restore_${TIMESTAMP}.txt

  /usr/local/bin/aws s3 sync s3://${BACKUP_BUCKET}/${ENVIRONMENT}/${ARCHIVE_DIR_NAME}/ ${BACKUPS_DIR}/

  if [ -z ${BACKUP_FILE} ]; then
    BACKUP_FILE=`find ${BACKUPS_DIR} -name "consul_backup_*.snap" -size +3c | sort -d | tail -1`
  fi

  if [ "x${BACKUP_FILE}x" == "xx" ]; then
    echo "No valid backups found in ${BACKUPS_DIR}"
    exit 1
  fi

  if [ ! -f ${BACKUP_FILE} ]; then
    echo "Backup file ${BACKUP_FILE} not found."
    exit 1
  fi

  BACKUP_ARCHIVE="${BACKUPS_TMP_DIR}/$(echo ${BACKUP_FILE} | awk -F/ '{print $NF}' | awk -F".gpg$" '{print $1}')"

  if [ `ls ${BACKUP_FILE} | awk -F. '{print $NF}'` == 'gpg' ]; then
    gpg --batch --yes -d -o ${BACKUP_ARCHIVE} --passphrase ${BACKUPS_PASSWORD} ${BACKUP_FILE}
  else
    cp ${BACKUP_FILE} ${BACKUP_ARCHIVE}
  fi

  cd ${BACKUPS_TMP_DIR}
  tar -xzf ${BACKUP_ARCHIVE}

  BACKUP_FILE=$(ls -tr ./consul_backup_*.snap | tail -1)

  if [ "x${BACKUP_FILE}x" == "xx" ] || [ ! -f ./vault_keys.txt ]; then
     echo "Invalid archive."
     exit 1
  fi

  consul snapshot inspect ${BACKUP_FILE} > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Backup file ${BACKUP_FILE} not valid."
    exit 1
  fi

  while true; do
    read -p "WARNING: Restore ${BACKUP_FILE} (y/n)?`echo $'\n> '`" yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) exit;;
      * ) echo "Please answer yes or no.";;
    esac
  done

  curl -k ${CONSUL_HTTP_ADDR}/v1/snapshot?token=${CONSUL_MASTER_TOKEN} --upload-file ${BACKUP_FILE}

  if [ $? -eq 0 ]; then
    echo "$ACTION Restore complete. Restarting dependent components."
  else
    echo "$ACTION returned an error."
    exit 1
  fi

  cp ./vault_keys.txt ${VAULT_KEYS_FILE}

  cd && rm -rf ${BACKUPS_TMP_DIR}

  curl -k -X DELETE "${CONSUL_HTTP_ADDR}/v1/kv/vault/core/lock?recurse=true&token=${CONSUL_MASTER_TOKEN}" > /dev/null 2>&1
  curl -k -X DELETE "${CONSUL_HTTP_ADDR}/v1/kv/vault/core/leader?recurse=true&token=${CONSUL_MASTER_TOKEN}" > /dev/null 2>&1
  echo ""

  # Stash unseal keys in kubernetes secret
  UNSEAL_KEYS=""
  for i in 1 2 3; do
    UNSEAL_KEY=`grep "Key ${i}" /root/vault_keys.txt | head -1 | awk '{print $NF}'`
    UNSEAL_KEYS=${UNSEAL_KEYS}${UNSEAL_KEY}":"
  done
  ${KUBERNETES_SECRETS_DIR}/create_secret.sh "vault-unseal-keys" "${UNSEAL_KEYS}" kube-system
  ${EXECUTABLES_DIR}/vault_unseal.sh

  return
}

# Main

[ -f /etc/profile.d/hostinfo.sh ] && . /etc/profile.d/hostinfo.sh
[ -f /etc/network-environment ] && . /etc/network-environment

# checks
! id -u > /dev/null 2>&1 && echo "Must be run as root" && exit 1

gpg -h > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Error: gpg is not installed."
  exit 1
fi

while [[ ! `curl -kLs -w "%{http_code}" ${CONSUL_HTTP_ADDR}/ui/ -o /dev/null 2>&1` -eq 200 ]]; do
  sleep 30
 echo "Waiting for ${CONSUL_HTTP_ADDR}..."
done
echo "OK"

/usr/local/bin/aws s3 ls s3://${BACKUP_BUCKET} >/dev/null 2>&1 || echo "WARNING: S3 Bucket not accessible"

[ -d ${BACKUPS_DIR} ] || mkdir ${BACKUPS_DIR}
[ -d ${BACKUPS_TMP_DIR} ] || mkdir ${BACKUPS_TMP_DIR}

chmod 750 ${BACKUPS_DIR}
chmod 750 ${BACKUPS_TMP_DIR}

# vars

if [ -z ${REGION} ]; then
  export S3REGION="us-east-1"
else
  export S3REGION=${REGION}
fi

if [ ! -z ${BACKUP_BUCKET} ] &&  [ -z ${ENVIRONMENT} ]; then
  export CONSUL_BACKUP_DISABLE="true"
fi

if [ -z ${CONSUL_MASTER_TOKEN} ]; then
  echo "Consul master access token not found"
  usage
fi

if [[ ${CONSUL_BACKUP_DISABLE} == "true" ]]; then
  echo "CONSUL_BACKUP_DISABLE is true"
  usage
fi


if [ $# -lt 1 ]; then
  export ACTION="backup"
else
  export ACTION=$1
fi

# Latest or named file
if [ ! -z $2 ]; then
  BACKUP_FILE=${BACKUPS_DIR}/${2}
else
  BACKUP_FILE=${BACKUPS_DIR}/consul_latest.tgz.gpg
fi

case ${ACTION} in
  backup)
    backup
    ;;
  restore)
    restore ${BACKUP_FILE}
    ;;
  restore-config)
    restore-config ${BACKUP_FILE}
    ;;
  *)
    usage
    ;;
esac

# End

