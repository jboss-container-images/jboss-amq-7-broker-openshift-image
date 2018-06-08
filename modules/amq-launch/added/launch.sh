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

JAVA_OPTS="-Djava.net.preferIPv4Stack=true ${JAVA_OPTS}"

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

function configureUserAuthentication() {
  if [ -n "${AMQ_USER}" -a -n "${AMQ_PASSWORD}" ] ; then
    AMQ_ARGS="$AMQ_ARGS --user $AMQ_USER --password $AMQ_PASSWORD "
  else
    echo "Required variable missing: both AMQ_USER and AMQ_PASSWORD are required."
    exit 1
  fi
if [ "$AMQ_REQUIRE_LOGIN" = "true" ]; then
    AMQ_ARGS="$AMQ_ARGS --require-login"
  else
    AMQ_ARGS="$AMQ_ARGS --allow-anonymous"
  fi
}

function configureNetworking() {
  if [ "$AMQ_CLUSTERED" = "true" ]; then
    echo "Broker will be clustered"
    AMQ_ARGS="$AMQ_ARGS --clustered --cluster-user=$AMQ_CLUSTER_USER --cluster-password=$AMQ_CLUSTER_PASSWORD --host $BROKER_IP"
    if [ "$AMQ_REPLICATED" = "true" ]; then
      echo "Broker will be clustered $AMQ_REPLICATED"
      AMQ_ARGS="$AMQ_ARGS --replicated"
    fi
    if [ "$AMQ_SLAVE" = "true" ]; then
      AMQ_ARGS="$AMQ_ARGS --slave"
    fi
    ACCEPTOR_IP=$BROKER_IP
  else
    AMQ_ARGS="$AMQ_ARGS --host 0.0.0.0"
    ACCEPTOR_IP="0.0.0.0"
  fi
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
  if sslEnabled ; then
    instanceDir=$1	
    
    echo "keystorepassword $keyStorePassword"
    echo "keystore filepath: $keyStorePath"

    IFS=',' read -a protocols <<< $(find_env "AMQ_TRANSPORTS" "openwire,amqp,stomp,mqtt,hornetq")
    connectionsAllowed=$(find_env "AMQ_MAX_CONNECTIONS" "1000")

    if [ "${#protocols[@]}" -ne "0" ]; then
      acceptors=""
      for protocol in ${protocols[@]}; do
        case "${protocol}" in
        "openwire")
        acceptors="${acceptors}            <acceptor name=\"artemis-ssl\">tcp://${ACCEPTOR_IP}:61617?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=CORE,AMQP,STOMP,HORNETQ,MQTT,OPENWIRE;useEpoll=true;amqpCredits=1000;amqpLowCredits=300;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
        ;;
      "mqtt")
      acceptors="${acceptors}            <acceptor name=\"mqtt-ssl\">tcp://${ACCEPTOR_IP}:8883?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=MQTT;useEpoll=true;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
      ;;
    "amqp")
    acceptors="${acceptors}            <acceptor name=\"amqp-ssl\">tcp://${ACCEPTOR_IP}:5671?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=AMQP;useEpoll=true;amqpCredits=1000;amqpMinCredits=300;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
    ;;
  "stomp")
  acceptors="${acceptors}            <acceptor name=\"stomp-ssl\">tcp://${ACCEPTOR_IP}:61612?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=STOMP;useEpoll=true;connectionsAllowed=${connectionsAllowed};sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}</acceptor>\n"
  ;;
esac
      done
    fi
    safeAcceptors=$(echo "${acceptors}" | sed 's/\//\\\//g')	    	
    sed -i "/<\/acceptors>/ s/.*/${safeAcceptors}\n&/" ${instanceDir}/etc/broker.xml    
  fi
}

function modifyDiscovery() {
  discoverygroup=""
  discoverygroup="${discoverygroup}       <discovery-group name=\"my-discovery-group\">"
  discoverygroup="${discoverygroup}          <jgroups-file>jgroups-ping.xml</jgroups-file>"
  discoverygroup="${discoverygroup}          <jgroups-channel>activemq_broadcast_channel</jgroups-channel>"
  discoverygroup="${discoverygroup}          <refresh-timeout>10000</refresh-timeout>"
  discoverygroup="${discoverygroup}       </discovery-group>	"
  sed -i -ne "/<discovery-groups>/ {p; i $discoverygroup" -e ":a; n; /<\/discovery-groups>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml	

  broadcastgroup=""		
  broadcastgroup="${broadcastgroup}       <broadcast-group name=\"my-broadcast-group\">"
  broadcastgroup="${broadcastgroup}          <jgroups-file>jgroups-ping.xml</jgroups-file>"
  broadcastgroup="${broadcastgroup}          <jgroups-channel>activemq_broadcast_channel</jgroups-channel>"
  broadcastgroup="${broadcastgroup}          <connector-ref>artemis</connector-ref>"
  broadcastgroup="${broadcastgroup}       </broadcast-group>	"
  sed -i -ne "/<broadcast-groups>/ {p; i $broadcastgroup" -e ":a; n; /<\/broadcast-groups>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml	

  clusterconnections=""
  clusterconnections="${clusterconnections}       <cluster-connection name=\"my-cluster\">"
  clusterconnections="${clusterconnections}          <connector-ref>artemis</connector-ref>"
  clusterconnections="${clusterconnections}          <retry-interval>500</retry-interval>"
  clusterconnections="${clusterconnections}          <use-duplicate-detection>true</use-duplicate-detection>"
  clusterconnections="${clusterconnections}          <message-load-balancing>STRICT</message-load-balancing>"
  clusterconnections="${clusterconnections}          <max-hops>1</max-hops>"
  clusterconnections="${clusterconnections}          <discovery-group-ref discovery-group-name=\"my-discovery-group\"/>"
  clusterconnections="${clusterconnections}       </cluster-connection>	"
  sed -i -ne "/<cluster-connections>/ {p; i $clusterconnections" -e ":a; n; /<\/cluster-connections>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml							
}


function configure() {
  instanceDir=$1

  export CONTAINER_ID=$HOSTNAME
  if [ ! -d ${instanceDir} -o "$AMQ_RESET_CONFIG" = "true" -o ! -f ${instanceDir}/bin/artemis ]; then
    AMQ_ARGS="--silent --role $AMQ_ROLE --name $AMQ_NAME --http-host $BROKER_IP --java-options=-Djava.net.preferIPv4Stack=true "
    configureUserAuthentication
    if [ -n "$AMQ_DATA_DIR" ]; then
      AMQ_ARGS="$AMQ_ARGS --data ${AMQ_DATA_DIR}"
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
    if [ "$AMQ_RESET_CONFIG" = "true" ]; then
      AMQ_ARGS="$AMQ_ARGS --force"
    fi
    if [ "$AMQ_EXTRA_ARGS" ]; then
      AMQ_ARGS="$AMQ_ARGS $AMQ_EXTRA_ARGS"
    fi
    configureNetworking
    configureSSL

    echo "Creating Broker with args $AMQ_ARGS"
    $AMQ_HOME/bin/artemis create ${instanceDir} $AMQ_ARGS --java-options "$JAVA_OPTS"

    removeArtemisDefaultGcAndMemSettings
    if [ "$AMQ_CLUSTERED" = "true" ]; then
      modifyDiscovery
    fi
    $AMQ_HOME/bin/configure_jolokia_access.sh ${instanceDir}/etc/jolokia-access.xml
    if [ "$AMQ_KEYSTORE_TRUSTSTORE_DIR" ]; then
      echo "Updating acceptors for SSL"
      updateAcceptors ${instanceDir}
    fi

    $AMQ_HOME/bin/configure_s2i_files.sh ${instanceDir}
    $AMQ_HOME/bin/configure_custom_config.sh ${instanceDir}
  fi
}

function removeArtemisDefaultGcAndMemSettings() {
  #Use the memory and gc set calculated from cct_module, removing the ones that conflict
  sed -i "s/-XX:+UseG1GC/ /" broker/etc/artemis.profile
  sed -i "s/-Xms[[:alnum:]]*/ /" broker/etc/artemis.profile
  sed -i "s/-Xmx[[:alnum:]]*/ /" broker/etc/artemis.profile
}

function removeWhiteSpace() {
  echo $*|tr -s ''| tr -d [[:space:]]
}

function runServer() {

  echo "Configuring Broker"
  instanceDir="${HOME}/${AMQ_NAME}"

  configure $instanceDir

  if [ "$1" = "start" ]; then
    echo "Running Broker"
    exec ${instanceDir}/bin/artemis run
  fi
}

runServer $1
