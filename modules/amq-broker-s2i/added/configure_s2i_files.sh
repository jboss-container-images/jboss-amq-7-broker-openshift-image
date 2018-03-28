#!/bin/sh
set -e

INSTANCE_DIR=$1
echo "Copying Config files from S2I build"
cp -v $AMQ_HOME/conf/* ${INSTANCE_DIR}/etc/
