#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added

cp $ADDED_DIR/configure_configmap.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/configure_configmap.sh

mkdir -p $AMQ_HOME/etc/configmap
