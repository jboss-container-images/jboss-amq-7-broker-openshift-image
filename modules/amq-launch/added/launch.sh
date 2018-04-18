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

function sslPartial() {
    [ -n "$AMQ_KEYSTORE_TRUSTSTORE_DIR" -o -n "$AMQ_KEYSTORE" -o -n "$AMQ_TRUSTSTORE" -o -n "$AMQ_KEYSTORE_PASSWORD" -o -n "$AMQ_TRUSTSTORE_PASSWORD" ]
}

function sslEnabled() {
    [ -n "$AMQ_KEYSTORE_TRUSTSTORE_DIR" -a -n "$AMQ_KEYSTORE" -a -n "$AMQ_TRUSTSTORE" -a -n "$AMQ_KEYSTORE_PASSWORD" -a -n "$AMQ_TRUSTSTORE_PASSWORD" ]
}

# Finds the environment variable  and returns its value if found.
# Otherwise returns the default value if provided.
#
# Arguments:
# $1 env variable name to check
# $2 default value if environemnt variable was not set
function find_env() {
  var=${!1}
  echo "${var:-$2}"
}

function configureSSL() {
    sslDir=$(find_env "AMQ_KEYSTORE_TRUSTSTORE_DIR" "")
    keyStoreFile=$(find_env "AMQ_KEYSTORE" "")
    trustStoreFile=$(find_env "AMQ_TRUSTSTORE" "")
  
    if sslEnabled ; then
        keyStorePassword=$(find_env "AMQ_KEYSTORE_PASSWORD" "")
        trustStorePassword=$(find_env "AMQ_TRUSTSTORE_PASSWORD" "")

        keyStorePath="$sslDir/$keyStoreFile"
        trustStorePath="$sslDir/$trustStoreFile"

        AMQ_ARGS="$AMQ_ARGS --ssl-key=$keyStorePath"
        AMQ_ARGS="$AMQ_ARGS --ssl-key-password=$keyStorePassword"

        AMQ_ARGS="$AMQ_ARGS --ssl-trust=$trustStorePath"
        AMQ_ARGS="$AMQ_ARGS --ssl-trust-password=$trustStorePassword"
    elif sslPartial ; then
        log_warning "Partial ssl configuration, the ssl context WILL NOT be configured."
    fi
}

function updateAcceptors() {

    instanceDir=$1	
    echo "keystorepassword $keyStorePassword"
    echo "keystore filepath: $keyStorePath"
	
    IFS=',' read -a protocols <<< $(find_env "AMQ_PROTOCOL" "openwire,amqp,stomp,mqtt,hornetq")
    connectionsAllowed=$(find_env "AMQ_MAX_CONNECTIONS" "1000")

    if [ "${#protocols[@]}" -ne "0" ]; then
    acceptors=""
    for protocol in ${protocols[@]}; do
      case "${protocol}" in
        "openwire")
acceptors="${acceptors}            <acceptor name=\"artemis\">tcp://${BROKER_IP}:61616?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=CORE,AMQP,STOMP,HORNETQ,MQTT,OPENWIRE;useEpoll=true;amqpCredits=1000;amqpLowCredits=300;connectionsAllowed=${connectionsAllowed}</acceptor>\n"
          if sslEnabled ; then
    acceptors="${acceptors}            <acceptor name=\"artemis\">tcp://${BROKER_IP}:61617?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=CORE,AMQP,STOMP,HORNETQ,MQTT,OPENWIRE;useEpoll=true;amqpCredits=1000;amqpLowCredits=300;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
          fi
          ;;
        "mqtt")
acceptors="${acceptors}            <acceptor name=\"mqtt\">tcp://${BROKER_IP}:1883?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=MQTT;useEpoll=true;connectionsAllowed=${connectionsAllowed}</acceptor>\n"
          if sslEnabled ; then
acceptors="${acceptors}            <acceptor name=\"mqtt\">tcp://${BROKER_IP}:8883?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=MQTT;useEpoll=true;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
          fi
          ;;
        "amqp")
acceptors="${acceptors}            <acceptor name=\"amqp\">tcp://${BROKER_IP}:5672?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=AMQP;useEpoll=true;amqpCredits=1000;amqpMinCredits=300;connectionsAllowed=${connectionsAllowed}</acceptor>\n"      
          if sslEnabled ; then
    acceptors="${acceptors}            <acceptor name=\"amqp\">tcp://${BROKER_IP}:5671?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=AMQP;useEpoll=true;amqpCredits=1000;amqpMinCredits=300;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
          fi
          ;;
        "stomp")
acceptors="${acceptors}            <acceptor name=\"stomp\">tcp://${BROKER_IP}:61613?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=STOMP;useEpoll=true;connectionsAllowed=${connectionsAllowed}</acceptor>\n"
          if sslEnabled ; then
    acceptors="${acceptors}            <acceptor name=\"stomp\">tcp://${BROKER_IP}:61612?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=STOMP;useEpoll=true;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
          fi
          ;;
        "hornetq")
acceptors="${acceptors}            <acceptor name=\"hornetq\">tcp://${BROKER_IP}:5445?protocols=HORNETQ,STOMP;useEpoll=true;connectionsAllowed=${connectionsAllowed}</acceptor>\n"
          ;;
      esac
    done
    sed -i -ne "/<acceptors>/ {p; i $acceptors" -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml
    sed -i "s/\${BROKER_IP}/${BROKER_IP}/g" ${instanceDir}/etc/broker.xml
fi
}

function configure() {
    instanceDir=$1
    
    export CONTAINER_ID=$HOSTNAME
    if [ ! -d ${instanceDir} -o "$AMQ_RESET_CONFIG" = "true" -o ! -f ${instanceDir}/bin/artemis ]; then
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
        
        configureSSL
        echo "Creating Broker with args $AMQ_ARGS"

        $AMQ_HOME/bin/artemis create ${instanceDir} $AMQ_ARGS --java-options "$JAVA_OPTS"
        $AMQ_HOME/bin/configure_jolokia_access.sh ${instanceDir}/etc/jolokia-access.xml
        updateAcceptors ${instanceDir}
        $AMQ_HOME/bin/configure_s2i_files.sh ${instanceDir}
	$AMQ_HOME/bin/configure_custom_config.sh ${instanceDir}
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
