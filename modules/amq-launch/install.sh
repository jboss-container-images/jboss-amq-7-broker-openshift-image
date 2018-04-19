#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added

cp $ADDED_DIR/launch.sh ${ADDED_DIR}/readinessProbe.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/launch.sh
chmod 0755 $AMQ_HOME/bin/readinessProbe.sh