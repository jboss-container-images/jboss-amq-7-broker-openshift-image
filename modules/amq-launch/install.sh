#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)
ADDED_DIR=${SCRIPT_DIR}/added
SOURCES_DIR="/tmp/artifacts"

# Add OpenShift PING implementation
VERSION="1.2.6.Final-redhat-1"

DEST=$AMQ_HOME

mkdir -p ${DEST}
mkdir -p ${DEST}/conf/

cp -p ${SOURCES_DIR}/openshift-ping-common-$VERSION.jar \
  ${SOURCES_DIR}/openshift-ping-dns-$VERSION.jar \
  ${SOURCES_DIR}/netty-tcnative-2.0.40.Final-redhat-00001-linux-x86_64-fedora.jar \
  ${DEST}/lib

cp -p $ADDED_DIR/jgroups-ping.xml \
  ${DEST}/conf/ 

cp $ADDED_DIR/launch.sh ${ADDED_DIR}/readinessProbe.sh ${ADDED_DIR}/drain.sh $AMQ_HOME/bin
chmod 0755 $AMQ_HOME/bin/launch.sh
chmod 0755 $AMQ_HOME/bin/readinessProbe.sh
chmod 0755 $AMQ_HOME/bin/drain.sh
