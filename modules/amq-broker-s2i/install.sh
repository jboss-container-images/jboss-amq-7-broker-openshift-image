#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added

mkdir -p $AMQ_HOME/conf
chown -R jboss:root $AMQ_HOME/conf
chmod -R g+rw $AMQ_HOME/conf

cp $ADDED_DIR/configure_s2i_files.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/configure_s2i_files.sh
