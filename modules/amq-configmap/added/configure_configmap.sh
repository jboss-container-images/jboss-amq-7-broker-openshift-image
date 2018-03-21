#!/bin/sh
set -e

CONFIGMAP=$AMQ_HOME/etc/configmap
CONFIG_DIR="/home/jboss/broker/etc"

if mount | grep $CONFIGMAP > /dev/null; then
  echo "ConfigMap volume mounted, copying over configuration files ..."
  cp  $CONFIGMAP/* $CONFIG_DIR
  sed -i "s/\${BROKER_IP}/$BROKER_IP/g" $CONFIG_DIR/broker.xml
else
  echo "ConfigMap volume not mounted.."
fi
