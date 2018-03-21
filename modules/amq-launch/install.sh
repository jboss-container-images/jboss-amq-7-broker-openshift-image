#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added

cp $ADDED_DIR/launch.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/launch.sh