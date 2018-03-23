#!/bin/sh

source /usr/local/dynamic-resources/dynamic_resources.sh

if [ "${SCRIPT_DEBUG}" = "true" ] ; then
    set -x
    echo "Script debugging is enabled, allowing bash commands and their arguments to be printed as they are executed"
fi

export BROKER_IP=`hostname -I | cut -f 1 -d ' '`
CONFIG_TEMPLATES=/config_templates
#Set the memory options
JAVA_OPTS="$(adjust_java_options ${JAVA_OPTS})"

#GC Option conflicts with the one already configured.
JAVA_OPTS=$(echo $JAVA_OPTS | sed -e "s/-XX:+UseParallelOldGC/ /")

function configure() {
    instanceDir=$1

    export CONTAINER_ID=$HOSTNAME
    if [ ! -d ${instanceDir} -o "$AMQ_RESET_CONFIG" = "true" ]; then
        AMQ_ARGS="--role $AMQ_ROLE --name $AMQ_NAME --allow-anonymous --http-host $BROKER_IP --host $BROKER_IP "
        if [ -n "${AMQ_USER}" -a -n "${AMQ_PASSWORD}" ] ; then
            AMQ_ARGS="--user $AMQ_USER --password $AMQ_PASSWORD $AMQ_ARGS "
        fi
        if [ -n "$AMQ_QUEUES" ]; then
            AMQ_ARGS="$AMQ_ARGS --queues $(removeWhiteSpace $AMQ_QUEUES)"
        fi
        if [ -n "$AMQ_ADDRESSES" ]; then
            AMQ_ARGS="$AMQ_ARGS --addresses $(removeWhiteSpace $AMQ_ADDRESSES)"
        fi
        if [ -n "$AMQ_TRANSPORTS" ]; then
            if [[ $(removeWhiteSpace ${AMQ_TRANSPORTS}) != *"hornetq"* ]]; then
                AMQ_ARGS="$AMQ_ARGS --no-hornetq-acceptor"
            fi
            if [[ $(removeWhiteSpace ${AMQ_TRANSPORTS}) != *"amqp"* ]]; then
                 AMQ_ARGS="$AMQ_ARGS --no-amqp-acceptor"
            fi
            if [[ $(removeWhiteSpace ${AMQ_TRANSPORTS}) != *"mqtt"* ]]; then
                 AMQ_ARGS="$AMQ_ARGS --no-mqtt-acceptor"
            fi
            if [[ $(removeWhiteSpace ${AMQ_TRANSPORTS}) != *"stomp"* ]]; then
                 AMQ_ARGS="$AMQ_ARGS --no-stomp-acceptor"
            fi
        fi
        if [ -n "$GLOBAL_MAX_SIZE" ]; then
            AMQ_ARGS="$AMQ_ARGS --global-max-size $(removeWhiteSpace $GLOBAL_MAX_SIZE)"
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
        if [ "$AMQ_RESET_CONFIG" = "true" ]; then
            AMQ_ARGS="$AMQ_ARGS --force"
        fi
        if [ "$AMQ_EXTRA_ARGS" ]; then
            AMQ_ARGS="$AMQ_ARGS $AMQ_EXTRA_ARGS"
        fi

        echo "Creating Broker with args $AMQ_ARGS"

        $AMQ_HOME/bin/artemis create ${instanceDir} $AMQ_ARGS --java-options "$JAVA_OPTS"
        $AMQ_HOME/bin/configure_jolokia_access.sh ${instanceDir}/etc/jolokia-access.xml
        $AMQ_HOME/bin/configure_configmap.sh
        $AMQ_HOME/bin/configure_s2i_files.sh ${instanceDir}
    fi
}

function removeWhiteSpace() {
    echo $*|tr -s ''| tr -d [[:space:]]
}

function runServer() {
    instanceDir="${HOME}/${AMQ_NAME}"
    
    configure $instanceDir
    echo "Running Broker"
    exec ${instanceDir}/bin/artemis run
}

runServer
