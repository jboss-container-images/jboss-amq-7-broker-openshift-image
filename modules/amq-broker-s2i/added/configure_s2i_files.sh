#!/bin/sh
set -e

INSTANCE_DIR=$1
echo "Copying Config files from S2I build"
cp -v $AMQ_HOME/conf/* ${INSTANCE_DIR}/etc/

if [ -f $AMQ_HOME/conf/broker.xml ]; then
	echo "replacing Broker IP"
	sed -i "s/\${BROKER_IP}/${BROKER_IP}/g" ${INSTANCE_DIR}/etc/broker.xml
fi