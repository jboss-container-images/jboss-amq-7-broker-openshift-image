#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added

cp $ADDED_DIR/launch.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/launch.sh
cp $ADDED_DIR/artemis-profile.xml $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/artemis-profile.xml

cp $ADDED_DIR/jolokia-access.xml $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/jolokia-access.xml