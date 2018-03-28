#!/bin/sh
set -e

CONFIGMAP=$AMQ_HOME/etc/configmap
INSTANCE_DIR=$1

if mount | grep $CONFIGMAP > /dev/null; then
  echo "ConfigMap volume mounted, copying over configuration files ..."
  cp  $CONFIGMAP/* $INSTANCE_DIR/etc/
else
  echo "ConfigMap volume not mounted.."
fi
