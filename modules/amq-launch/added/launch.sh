#!/bin/sh

if [ "${SCRIPT_DEBUG}" = "true" ] ; then
    set -x
    echo "Script debugging is enabled, allowing bash commands and their arguments to be printed as they are executed"
fi

export BROKER_IP=`hostname -I | cut -f 1 -d ' '`


function configure() {

    export CONTAINER_ID=$HOSTNAME
    if [ ! -d "BROKER" -o "$AMQ_RESET_CONFIG" = "true" ]; then
        AMQ_ARGS="--role $AMQ_ROLE --name $AMQ_NAME --allow-anonymous --http-host $BROKER_IP --host $BROKER_IP "
    	if [ -n "${AMQ_USER}" -a -n "${AMQ_PASSWORD}" ] ; then
			AMQ_ARGS="--user $AMQ_USER --password $AMQ_PASSWORD $AMQ_ARGS "
		fi
        if [ "$AMQ_CLUSTERED" = "true" ]; then
            echo "Broker will be clustered"
            AMQ_ARGS="$AMQ_ARGS --clustered --cluster-user=$AMQ_CLUSTER_USER --cluster-password=$AMQ_CLUSTER_PASSWORD"
            if [ "$AMQ_REPLICATED" = "true" ]; then
                AMQ_ARGS="$AMQ_ARGS --replicated"
            fi
            if [ "$AMQ_SLAVE" = "true" ]; then
                AMQ_ARGS="$AMQ_ARGS --slave"
            fi
        fi
        if [ "$AMQ_RESET_CONFIG" ]; then
            AMQ_ARGS="$AMQ_ARGS --force"
        fi
        if [ "$AMQ_EXTRA_ARGS" ]; then
            AMQ_ARGS="$AMQ_ARGS $AMQ_EXTRA_ARGS"
        fi
        PRINT_ARGS="${AMQ_ARGS/$AMQ_PASSWORD/XXXXX}"
        PRINT_ARGS="${PRINT_ARGS/$AMQ_USER/XXXXX}"
        echo "Creating Broker with args $PRINT_ARGS"

        $AMQ_HOME/bin/artemis create broker $AMQ_ARGS
    	$AMQ_HOME/bin/configure_jolokia_access.sh /home/jboss/broker/etc/jolokia-access.xml
    fi

}

function runServer() {
  configure
  echo "Running Broker"
  exec ~/broker/bin/artemis run
}

runServer
