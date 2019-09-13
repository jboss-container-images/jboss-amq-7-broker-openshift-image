#!/bin/sh

source /usr/local/dynamic-resources/dynamic_resources.sh

if [ "${SCRIPT_DEBUG}" = "true" ] ; then
  set -x
  echo "Script debugging is enabled, allowing bash commands and their arguments to be printed as they are executed"
fi


export BROKER_IP=`hostname -f`
CONFIG_TEMPLATES=/config_templates
#Set the memory options via adjust_java_options from dynamic_resources
#see https://developers.redhat.com/blog/2017/04/04/openjdk-and-containers/
JAVA_OPTS="$(adjust_java_options ${JAVA_OPTS})"

#GC Option conflicts with the one already configured.
echo "Removing provided -XX:+UseParallelOldGC in favour of artemis.profile provided option"
JAVA_OPTS=$(echo $JAVA_OPTS | sed -e "s/-XX:+UseParallelOldGC/ /")
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

function configureLogging() {
  instanceDir=$1
  if [ "$AMQ_DATA_DIR_LOGGING" = "true" ]; then
    echo "Configuring logging directory to be ${AMQ_DATA_DIR}/log"
    sed -i 's@${artemis.instance}@'"$AMQ_DATA_DIR"'@' ${instanceDir}/etc/logging.properties
  fi
}

function configureNetworking() {
  if [ "$AMQ_CLUSTERED" = "true" ]; then
    echo "Broker will be clustered"
    AMQ_ARGS="$AMQ_ARGS --clustered --cluster-user $AMQ_CLUSTER_USER --cluster-password $AMQ_CLUSTER_PASSWORD --host $BROKER_IP"
    ACCEPTOR_IP=$BROKER_IP
  else
    AMQ_ARGS="$AMQ_ARGS --host 0.0.0.0"
    ACCEPTOR_IP="0.0.0.0"
  fi
}

function configureRedistributionDelay() {
  instanceDir=$1
  echo "Setting redistribution-delay to zero."
  sed -i "s/<address-setting match=\"#\">/&\n            <redistribution-delay>0<\/redistribution-delay>/g" ${instanceDir}/etc/broker.xml
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

    AMQ_ARGS="$AMQ_ARGS --ssl-key $keyStorePath"
    AMQ_ARGS="$AMQ_ARGS --ssl-key-password $keyStorePassword"

    AMQ_ARGS="$AMQ_ARGS --ssl-trust $trustStorePath"
    AMQ_ARGS="$AMQ_ARGS --ssl-trust-password $trustStorePassword"
  elif sslPartial ; then
    log_warning "Partial ssl configuration, the ssl context WILL NOT be configured."
  fi
}

function updateAcceptorsForSSL() {
  instanceDir=$1	

  if sslEnabled ; then
    
    echo "keystore filepath: $keyStorePath"

    IFS=',' read -a protocols <<< $(find_env "AMQ_TRANSPORTS" "openwire,amqp,stomp,mqtt,hornetq")
    connectionsAllowed=$(find_env "AMQ_MAX_CONNECTIONS" "1000")

    sslProvider=$(find_env "AMQ_SSL_PROVIDER" "")

    if [ -z "${sslProvider}" ] ; then
       SSL_OPS="sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword}"
    else
       SSL_OPS="sslEnabled=true;keyStorePath=${keyStorePath};keyStorePassword=${keyStorePassword};sslProvider=${sslProvider}"
    fi

    if [ "${#protocols[@]}" -ne "0" ]; then
      acceptors=""
      for protocol in ${protocols[@]}; do
        case "${protocol}" in
        "openwire")
        acceptors="${acceptors}            <acceptor name=\"artemis-ssl\">tcp://${ACCEPTOR_IP}:61617?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=CORE,AMQP,STOMP,HORNETQ,MQTT,OPENWIRE;useEpoll=true;amqpCredits=1000;amqpLowCredits=300;connectionsAllowed=${connectionsAllowed};${SSL_OPS}</acceptor>\n"
        ;;
      "mqtt")
      acceptors="${acceptors}            <acceptor name=\"mqtt-ssl\">tcp://${ACCEPTOR_IP}:8883?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=MQTT;useEpoll=true;connectionsAllowed=${connectionsAllowed};${SSL_OPS}</acceptor>\n"
      ;;
    "amqp")
    acceptors="${acceptors}            <acceptor name=\"amqp-ssl\">tcp://${ACCEPTOR_IP}:5671?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=AMQP;useEpoll=true;amqpCredits=1000;amqpMinCredits=300;connectionsAllowed=${connectionsAllowed};${SSL_OPS}</acceptor>\n"
    ;;
  "stomp")
  acceptors="${acceptors}            <acceptor name=\"stomp-ssl\">tcp://${ACCEPTOR_IP}:61612?tcpSendBufferSize=1048576;tcpReceiveBufferSize=1048576;protocols=STOMP;useEpoll=true;connectionsAllowed=${connectionsAllowed};${SSL_OPS}</acceptor>\n"
  ;;
esac
      done
    fi
    safeAcceptors=$(echo "${acceptors}" | sed 's/\//\\\//g')
    sed -i "/<\/acceptors>/ s/.*/${safeAcceptors}\n&/" ${instanceDir}/etc/broker.xml    
  fi
}

function updateAcceptorsForPrefixing() {
  instanceDir=$1	

  if [ -n "$AMQ_MULTICAST_PREFIX" ]; then
    echo "Setting multicastPrefix to ${AMQ_MULTICAST_PREFIX}"
    sed -i "s/:61616?/&multicastPrefix=${AMQ_MULTICAST_PREFIX};/g" ${instanceDir}/etc/broker.xml
    sed -i "s/:61617?/&multicastPrefix=${AMQ_MULTICAST_PREFIX};/g" ${instanceDir}/etc/broker.xml
  fi

  if [ -n "$AMQ_ANYCAST_PREFIX" ]; then
    echo "Setting anycastPrefix to ${AMQ_ANYCAST_PREFIX}"
    sed -i "s/:61616?/&anycastPrefix=${AMQ_ANYCAST_PREFIX};/g" ${instanceDir}/etc/broker.xml
    sed -i "s/:61617?/&anycastPrefix=${AMQ_ANYCAST_PREFIX};/g" ${instanceDir}/etc/broker.xml
  fi
}

function appendAcceptorsFromEnv() {
  instanceDir=$1

  if [ -n "$AMQ_ACCEPTORS" ]; then
      echo "Using acceptors from environment and removing existing entries"
      sed -i "/acceptor name=/d" ${instanceDir}/etc/broker.xml
      acceptorsFromEnv=$(find_env "AMQ_ACCEPTORS" "")
      # As AMQ_ACCEPTORS was introduced from the operator, the operator makes a safe string for here
      safeAcceptorsFromEnv=$(echo "${acceptorsFromEnv}")
      sed -i "/<\/acceptors>/ s/.*/${safeAcceptorsFromEnv}\n&/g" ${instanceDir}/etc/broker.xml
      sed -i "s/ACCEPTOR_IP/${ACCEPTOR_IP}/g" ${instanceDir}/etc/broker.xml
  fi
}

function appendConnectorsFromEnv() {
  instanceDir=$1

  if [ -n "$AMQ_CONNECTORS" ]; then
      echo "Appending connectors from environment"
      connectorsFromEnv=$(find_env "AMQ_CONNECTORS" "")
      # As AMQ_CONNECTORS was introduced from the operator, the operator makes a safe string for here
      safeConnectorsFromEnv=$(echo "${connectorsFromEnv}")
      endConnectorsCount=`grep -c '</connectors>' ${instanceDir}/etc/broker.xml`
      if [ ${endConnectorsCount} -ne 0 ]; then
          sed -i "/<\/connectors>/ s/.*/\t\t${safeConnectorsFromEnv}\n&/" ${instanceDir}/etc/broker.xml
      else
          sed -i "/<\/acceptors>/ s/.*/&\n\t<connectors>\n\t\t${safeConnectorsFromEnv}\n\t<\/connectors>\n/" ${instanceDir}/etc/broker.xml
      fi
  fi
}

function appendJournalType() {
  instanceDir=$1

  if [ -n "$AMQ_JOURNAL_TYPE" ]; then
      echo "Setting journal type to ${AMQ_JOURNAL_TYPE}"
      if [[ $(removeWhiteSpace ${AMQ_JOURNAL_TYPE}) != *"nio"* ]]; then
        AMQ_ARGS="$AMQ_ARGS --aio"
      fi
      if [[ $(removeWhiteSpace ${AMQ_JOURNAL_TYPE}) != *"aio"* ]]; then
        AMQ_ARGS="$AMQ_ARGS --nio"
      fi
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

  #generate jgroups-ping.xml
  echo "Generating jgroups-ping.xml, current dir is: $PWD, AMQHOME: $AMQ_HOME"

  if [ -z "${PING_SVC_NAME+x}" ]; then
    echo "PING_SERVICE is not set"
    PING_SVC_NAME=ping
  fi

  if [ -z "${APPLICATION_NAME+x}" ]; then
    echo "APPLICATION_NAME is not set"
    sed -i -e "s/\${APPLICATION_NAME}-\${PING_SVC_NAME}/${PING_SVC_NAME}/" $AMQ_HOME/conf/jgroups-ping.xml
  else
    echo "APPLICATION_NAME is set"
    sed -i -e "s/\${APPLICATION_NAME}-\${PING_SVC_NAME}/${APPLICATION_NAME}-${PING_SVC_NAME}/" $AMQ_HOME/conf/jgroups-ping.xml
  fi
  
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
  clusterconnections="${clusterconnections}          <retry-interval>1000</retry-interval>"
  clusterconnections="${clusterconnections}          <retry-interval-multiplier>2</retry-interval-multiplier>"
  clusterconnections="${clusterconnections}          <max-retry-interval>32000</max-retry-interval>"
  clusterconnections="${clusterconnections}          <initial-connect-attempts>20</initial-connect-attempts>"
  clusterconnections="${clusterconnections}          <reconnect-attempts>10</reconnect-attempts>"
  clusterconnections="${clusterconnections}          <use-duplicate-detection>true</use-duplicate-detection>"
  clusterconnections="${clusterconnections}          <message-load-balancing>ON_DEMAND</message-load-balancing>"
  clusterconnections="${clusterconnections}          <max-hops>1</max-hops>"
  clusterconnections="${clusterconnections}          <discovery-group-ref discovery-group-name=\"my-discovery-group\"/>"
  clusterconnections="${clusterconnections}       </cluster-connection>	"
  sed -i -ne "/<cluster-connections>/ {p; i $clusterconnections" -e ":a; n; /<\/cluster-connections>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml							
}

function configureJAVA_ARGSMemory() {
  instanceDir=$1
  echo "Removing hardcoded -Xms -Xmx from artemis.profile in favour of JAVA_OPTS in log above"
  sed -i "s/\-Xms[0-9]*[mMgG] \-Xmx[0-9]*[mMgG] \-Dhawtio/\ -Dhawtio/g" ${instanceDir}/etc/artemis.profile
}

function injectMetricsPlugin() {
  instanceDir=$1
  echo "Adding artemis metrics plugin"
  sed -i "s/^\([[:blank:]]*\)<\\/core>/\1\1<metrics-plugin class-name=\"org.apache.activemq.artemis.core.server.metrics.plugins.ArtemisPrometheusMetricsPlugin\"\\/>\\n\1<\\/core>/" $instanceDir/etc/broker.xml
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
    if [ -n "$AMQ_ACCEPTORS" ]; then
      AMQ_ARGS="$AMQ_ARGS --no-amqp-acceptor --no-hornetq-acceptor --no-mqtt-acceptor --no-stomp-acceptor"
    else
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
    appendJournalType ${instanceDir}

    # mask sensitive values
    PRINT_ARGS="${AMQ_ARGS/--password $AMQ_PASSWORD/--password XXXXX}"
    PRINT_ARGS="${PRINT_ARGS/--user $AMQ_USER/--user XXXXX}"
    PRINT_ARGS="${PRINT_ARGS/--cluster-user $AMQ_CLUSTER_USER/--cluster-user XXXXX}"
    PRINT_ARGS="${PRINT_ARGS/--cluster-password $AMQ_CLUSTER_PASSWORD/--cluster-password XXXXX}"
    PRINT_ARGS="${PRINT_ARGS/--ssl-key-password $AMQ_KEYSTORE_PASSWORD/--ssl-key-password XXXXX}"
    PRINT_ARGS="${PRINT_ARGS/--ssl-trust-password $AMQ_TRUSTSTORE_PASSWORD/--ssl-trust-password XXXXX}"

    if [ "$AMQ_CONSOLE_ARGS" ]; then
      AMQ_ARGS="$AMQ_ARGS $AMQ_CONSOLE_ARGS"
      keypat='(.*)(--ssl-key-password).([[:alnum:]]*)(.*)'
      [[ "$AMQ_CONSOLE_ARGS"  =~ $keypat ]]
      CONSOLE_ARGS_NO_KEYPASS="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} XXXXX ${BASH_REMATCH[4]}"
      trustpat='(.*)(--ssl-trust-password).([[:alnum:]]*)(.*)'
      [[ "$CONSOLE_ARGS_NO_KEYPASS"  =~ $trustpat ]]
      CONSOLE_ARGS_NO_TRUSTPASS="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} XXXXX ${BASH_REMATCH[4]}"
      PRINT_ARGS="${PRINT_ARGS} ${CONSOLE_ARGS_NO_TRUSTPASS}"
    fi


    echo "Creating Broker with args $PRINT_ARGS"
    $AMQ_HOME/bin/artemis create ${instanceDir} $AMQ_ARGS --java-options "$JAVA_OPTS"

    if [ "$AMQ_CLUSTERED" = "true" ]; then
      modifyDiscovery
      configureRedistributionDelay ${instanceDir}
    fi
    $AMQ_HOME/bin/configure_jolokia_access.sh ${instanceDir}/etc/jolokia-access.xml
    if [ "$AMQ_KEYSTORE_TRUSTSTORE_DIR" ]; then
      echo "Updating acceptors for SSL"
      updateAcceptorsForSSL ${instanceDir}
    fi
    updateAcceptorsForPrefixing ${instanceDir}
    appendAcceptorsFromEnv ${instanceDir}
    appendConnectorsFromEnv ${instanceDir}
    configureLogging ${instanceDir}
    configureJAVA_ARGSMemory ${instanceDir}

    if [ "$AMQ_ENABLE_METRICS_PLUGIN" = "true" ]; then
      echo "Enable artemis metrics plugin"
      injectMetricsPlugin ${instanceDir}
    fi

    $AMQ_HOME/bin/configure_s2i_files.sh ${instanceDir}
    $AMQ_HOME/bin/configure_custom_config.sh ${instanceDir}
  fi
}

function removeWhiteSpace() {
  echo $*|tr -s ''| tr -d [[:space:]]
}

function runServer() {

  echo "Configuring Broker"
  instanceDir="${HOME}/${AMQ_NAME}"

  configure $instanceDir

  if [ "$1" != "nostart" ]; then
    echo "Running Broker"
    exec ${instanceDir}/bin/artemis run
  fi
}

runServer $1
