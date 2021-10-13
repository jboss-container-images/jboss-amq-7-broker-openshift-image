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
PLATFORM=`uname -m`
echo "Platform is ${PLATFORM}"
if [ "${PLATFORM}" = "s390x" ] ; then
  #GC Option found to be a problem on s390x               
  echo "Removing -XX:+UseG1GC as per recommendation to use default GC"        
  JAVA_OPTS=$(echo $JAVA_OPTS | sed -e "s/-XX:+UseG1GC/ /")
  #JDK11 related warnings removal
  echo "Adding -Dcom.sun.xml.bind.v2.bytecode.ClassTailor.noOptimize=true as per ENTMQBR-1932"
  JAVA_OPTS="-Dcom.sun.xml.bind.v2.bytecode.ClassTailor.noOptimize=true ${JAVA_OPTS}"
fi
JAVA_OPTS="-Djava.net.preferIPv4Stack=true ${JAVA_OPTS}"

if [ "$AMQ_ENABLE_JOLOKIA_AGENT" = "true" ]; then
  echo "Enable jolokia jvm agent"
  export AB_JOLOKIA_USER=$AMQ_JOLOKIA_AGENT_USER
  export AB_JOLOKIA_PASSWORD_RANDOM=false
  export AB_JOLOKIA_PASSWORD=$AMQ_JOLOKIA_AGENT_PASSWORD
  export AB_JOLOKIA_OPTS="realm=activemq,caCert=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt,clientPrincipal.1=cn=system:master-proxy,clientPrincipal.2=cn=hawtio-online.hawtio.svc,clientPrincipal.3=cn=fuse-console.fuse.svc"
  JOLOKIA_OPTS="$(/opt/jolokia/jolokia-opts)"
  JAVA_OPTS="${JAVA_OPTS} ${JOLOKIA_OPTS}"
fi


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
  sed -i "s/^\([[:blank:]]*\)<\\/core>/\1\1<metrics> <plugin class-name=\"org.apache.activemq.artemis.core.server.metrics.plugins.ArtemisPrometheusMetricsPlugin\"\\/> <\\/metrics>\\n\1<\\/core>/" $instanceDir/etc/broker.xml
}

function selectDelim {
  content="$1"
  DELIM=""
  if [[ ${content} != *"+"* ]]; then
    DELIM="+"
  elif [[ ${content} != *","* ]]; then
    DELIM=","
  elif [[ ${content} != *"_"* ]]; then
    DELIM="_"
  fi
}

function performReplaceAll {
  _sourceBrokerFile="$1"
  _targetBrokerFile="$2"

  _sourceBrokerXml=`cat ${_sourceBrokerFile}`
  _targetBrokerXml=`cat ${_targetBrokerFile}`

  if [[ ${_sourceBrokerXml} =~ "<address-settings>"(.*)"</address-settings>" ]]; then
      echo Match found
      sourceAddressSettingsBlock=${BASH_REMATCH[1]}
      totalLines="";
      while IFS= read -r line; do
        totalLines=${totalLines}"\\n"$line
      done <<< "${sourceAddressSettingsBlock}"
      #replace broker2.xml with the result
      sed -i ':a;N;$!ba; s|<address-settings>.*<\/address-settings>|<address-settings>'"${totalLines}"'<\/address-settings>|' ${_targetBrokerFile}
  fi
}

function performMergeReplace {
  _sourceBrokerFile="$1"
  _targetBrokerFile="$2"

  _sourceBrokerXml=`cat ${_sourceBrokerFile}`
  _targetBrokerXml=`cat ${_targetBrokerFile}`

  if [[ ${_sourceBrokerXml} =~ "<address-settings>"(.*)"</address-settings>" ]]; then
      sourceAddressSettingsBlock=${BASH_REMATCH[1]}
      #split into array of <address-setting>s
      while IFS= read -r line; do
        totalLines=${totalLines}"\\n"$line
      done <<< "${sourceAddressSettingsBlock}"
      #now add a delimiter
      selectDelim "${totalLines}"
      ttl=`echo "${totalLines}" | sed -e 's/<\/address-setting>/<\/address-setting>'${DELIM}'/g'`
      IFS="${DELIM}" read -r -a sourceAddressSettingsArray <<< "${ttl}"

      #now target
      if [[ ${_targetBrokerXml} =~ "<address-settings>"(.*)"</address-settings>" ]]; then
          targetAddressSettingsBlock=${BASH_REMATCH[1]}
          #split into array of <address-setting>s
          while IFS= read -r line; do
            totalTargetLines=${totalTargetLines}"\\n"$line
          done <<< "${targetAddressSettingsBlock}"
          #now add a delimiter
          selectDelim "${totalTargetLines}"
          ttl=`echo "${totalTargetLines}" | sed -e 's/<\/address-setting>/<\/address-setting>'${DELIM}'/g'`
          #convert to array
          IFS="${DELIM}" read -r -a targetAddressSettingsArray <<< "${ttl}"
          for targetElement in "${targetAddressSettingsArray[@]}"
          do
            isDupKey=false
            if [[ ${targetElement} =~ "match=".*(\".*\") ]]; then
              targetKey="${BASH_REMATCH[1]}"
              for sourceElement in "${sourceAddressSettingsArray[@]}"
              do
                if [[ ${sourceElement} =~ "match=".*(\".*\") ]]; then
                  matchKey="${BASH_REMATCH[1]}"
                  if [[ "${matchKey}" == "${targetKey}" ]]; then
                    isDupKey=true
                    break
                  fi
                fi
              done
              if [[ "${isDupKey}" == false ]]; then
                sourceAddressSettingsArray+=("${targetElement}")
              fi
            fi
          done
      fi

      for mergeElement in "${sourceAddressSettingsArray[@]}"
      do
        toMerge="${toMerge}$mergeElement"
      done
      #make sure last element followed by at least a newline and some indentation
      toMerge="${toMerge}"'\n    '
      sed -i ':a;N;$!ba; s|<address-settings>.*<\/address-settings>|<address-settings>'"${toMerge}"'<\/address-settings>|' ${_targetBrokerFile}
  fi
}

function performMergeAll {
  _sourceBrokerFile="$1"
  _targetBrokerFile="$2"

  _sourceBrokerXml=`cat ${_sourceBrokerFile}`
  _targetBrokerXml=`cat ${_targetBrokerFile}`

  if [[ ${_sourceBrokerXml} =~ "<address-settings>"(.*)"</address-settings>" ]]; then
      sourceAddressSettingsBlock=${BASH_REMATCH[1]}
      while IFS= read -r line; do
        totalLines=${totalLines}"\\n"$line
      done <<< "${sourceAddressSettingsBlock}"
      #now add a delimiter
      selectDelim "${totalLines}"
      ttl=`echo "${totalLines}" | sed -e 's/<\/address-setting>/<\/address-setting>'${DELIM}'/g'`
      IFS="${DELIM}" read -r -a sourceAddressSettingsArray <<< "${ttl}"

      #now target
      if [[ ${_targetBrokerXml} =~ "<address-settings>"(.*)"</address-settings>" ]]; then
          targetAddressSettingsBlock=${BASH_REMATCH[1]}
          #split into array of <address-setting>s
          while IFS= read -r line; do
            totalTargetLines=${totalTargetLines}"\\n"$line
          done <<< "${targetAddressSettingsBlock}"
          #now add a delimiter
          selectDelim "${totalTargetLines}"
          ttl=`echo "${totalTargetLines}" | sed -e 's/<\/address-setting>/<\/address-setting>'${DELIM}'/g'`
          #convert to array
          IFS="${DELIM}" read -r -a targetAddressSettingsArray <<< "${ttl}"
          #using a separate array for merge
          mergeArray=()
          #first find unique address-setting elems in target
          for targetElement in "${targetAddressSettingsArray[@]}"
          do
            if [[ ${targetElement} =~ "match=".*(\".*\") ]]; then
              targetKey="${BASH_REMATCH[1]}"
              isTargetUnique=true
              for sourceElement in "${sourceAddressSettingsArray[@]}"
              do
                if [[ ${sourceElement} =~ "match=".*(\".*\") ]]; then
                  matchKey="${BASH_REMATCH[1]}"
                  if [[ "${matchKey}" == "${targetKey}" ]]; then
                    isTargetUnique=false
                    break
                  fi
                fi
              done
              if [[ "${isTargetUnique}" == true ]]; then
                mergeArray+=("${targetElement}")
              fi
            fi
          done
          #second find unique address-setting elems in source
          for sourceElement in "${sourceAddressSettingsArray[@]}"
          do
            if [[ ${sourceElement} =~ "match=".*(\".*\") ]]; then
              sourceKey="${BASH_REMATCH[1]}"
              isSourceUnique=true
              for targetElement in "${targetAddressSettingsArray[@]}"
              do
                if [[ $targetElement =~ "match=".*(\".*\") ]]; then
                  matchKey="${BASH_REMATCH[1]}"
                  if [[ "${matchKey}" == "${sourceKey}" ]]; then
                    isSourceUnique=false
                    #merge!
                    if [[ ${sourceElement} =~ "<address-setting".*"\">"(.*)"</address-setting>" ]]; then
                      sourceSingleSetting="${BASH_REMATCH[1]}"
                      sourceSingleSettingWithDelimiter=`echo "${sourceSingleSetting}" | sed -r -e 's/(<\/[^>]+>)/\1'${DELIM}'/g'`
                      IFS="${DELIM}" read -r -a sourceAddressSettingPropArray <<< "${sourceSingleSettingWithDelimiter}"
                      #alternative to <<< way. IFS=',' sourceAddressSettingPropArray=($sourceSingleSettingWithDelimiter)
                    fi
                    if [[ ${targetElement} =~ "<address-setting".*"\">"(.*)"</address-setting>" ]]; then
                      targetSingleSetting="${BASH_REMATCH[1]}"
                      targetSingleSettingWithDelimiter=`echo "${targetSingleSetting}" | sed -r -e 's/(<\/[^>]+>)/\1'${DELIM}'/g'`
                      IFS="${DELIM}" read -r -a targetAddressSettingPropArray <<< "${targetSingleSettingWithDelimiter}"

                      #alternative to <<< way. IFS=',' targetAddressSettingPropArray=($targetSingleSettingWithDelimiter)
                      for targetAddressSettingProperty in "${targetAddressSettingPropArray[@]}"
                      do
                        #get key
                        if [[ "${targetAddressSettingProperty}" =~ ("</".+">") ]]; then
                          targetPropKey="${BASH_REMATCH[1]}"
                          isDupProp=false
                          for sourceAddressSettingProperty in "${sourceAddressSettingPropArray[@]}"
                          do
                            if [[ "${sourceAddressSettingProperty}" =~ ("</".+">") ]]; then
                              sourcePropKey="${BASH_REMATCH[1]}"
                              if [[ "${targetPropKey}" == "${sourcePropKey}" ]]; then
                                isDupProp=true
                                break
                              fi
                            fi
                          done
                        fi
                        if [[ "${isDupProp}" == false ]]; then
                          sourceAddressSettingPropArray+=("${targetAddressSettingProperty}")
                        fi
                      done
                    fi
                    #now sourceAddressSettingPropArray is merged
                    #make a new sourceElement and added to mergeArray
                    toPropMerge=""
                    for propMergeElement in "${sourceAddressSettingPropArray[@]}"
                    do
                      toPropMerge="${toPropMerge}$propMergeElement"
                    done
                    #make sure last element followed by at least a newline and some indentation
                    toPropMerge="${toPropMerge}"'\n    '
                    newSourceElement=`echo "${sourceElement}" | sed -r -e 's|(<address-setting.*\">)(.*)</address-setting>|\1'"${toPropMerge}"'</address-setting>|g'`
                    mergeArray+=("${newSourceElement}")
                  fi
                fi
              done
              if [[ "${isSourceUnique}" == true ]]; then
                mergeArray+=("${sourceElement}")
              fi
            fi
          done
      fi

      for melem in "${mergeArray[@]}"
      do
        toMergeAll="${toMergeAll}${melem}"
      done
      toMergeAll="${toMergeAll//[$'\n']/\\n}"

      sed -i ':a;N;$!ba; s|<address-settings>.*<\/address-settings>|<address-settings>'"${toMergeAll}"'\n    <\/address-settings>|' ${_targetBrokerFile}
  fi
}

function updateAddressSettings() {
  sourceBrokerFile="$1"
  targetBrokerFile="$2"

  echo "Updating address settings from operator with apply rule ${APPLY_RULE}"

  if [[ ${APPLY_RULE} == "replace_all" ]]; then
    echo "Doing replace all..."
    performReplaceAll "${sourceBrokerFile}" "${targetBrokerFile}"
  elif [[ ${APPLY_RULE} == "merge_replace" ]]; then
    echo "Doing merge_replace..."
    performMergeReplace "${sourceBrokerFile}" "${targetBrokerFile}"
  elif [[ ${APPLY_RULE} == "merge_all" ]]; then
    echo "Doing merge_all..."
    performMergeAll "${sourceBrokerFile}" "${targetBrokerFile}"
  else
    echo "ERROR: Invalid APPLY_RULE: ${APPLY_RULE}."
  fi
  echo Done.
}

function disableManagementRBAC() {
  instanceDir=$1
  # For hawtio-online, RBAC is checked at the hawtio nginx reverse proxy
  # and must not be checked at broker.
  # See: https://github.com/hawtio/hawtio-online#rbac
  sed -i "s/<\/whitelist>/<entry domain=\"org.apache.activemq.artemis\"\/><\/whitelist>/" ${instanceDir}/etc/management.xml
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


    echo "Creating Broker with args $PRINT_ARGS at ${instanceDir}"
    $AMQ_HOME/bin/artemis create ${instanceDir} $AMQ_ARGS --java-options "$JAVA_OPTS"

    echo "Checking yacfg file under dir: $TUNE_PATH"

    if [[ -f "${TUNE_PATH}/broker.xml" ]]; then
        echo "yacfg broker.xml exists."
        updateAddressSettings "${TUNE_PATH}/broker.xml" "${instanceDir}/etc/broker.xml"
    fi

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

    if [ "$AMQ_ENABLE_MANAGEMENT_RBAC" = "false" ]; then
      disableManagementRBAC ${instanceDir}
    fi

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

  echo "Running server env: home: ${HOME} AMQ_HOME ${AMQ_HOME} CONFIG_BROKER ${CONFIG_BROKER} RUN_BROKER ${RUN_BROKER}"
  instanceDir="${HOME}/${AMQ_NAME}"

  if [ -z ${CONFIG_BROKER+x} ]; then
    echo "NO CONFIG_BROKER defined"
    CONFIG_BROKER=true
  fi
  if [ -z ${RUN_BROKER+x} ]; then
    echo "NO RUN_BROKER defined"
    RUN_BROKER=true
  fi

  if [ "${CONFIG_BROKER}" = "true" ]; then
    echo "Configuring Broker at ${CONFIG_INSTANCE_DIR}"
    echo "config Using instanceDir: $instanceDir"
    configure $instanceDir

    if [ -z "${CONFIG_INSTANCE_DIR+x}" ]; then
      echo "No CONFIG_INSTANCE_DIR defined"
    else
      echo "user defined CONFIG_INSTANCE_DIR, copying"
      cp -r $instanceDir "${CONFIG_INSTANCE_DIR}"
      ls ${CONFIG_INSTANCE_DIR}
    fi
  fi

  if [ "${RUN_BROKER}" == "true" ]; then
    if [ "${CONFIG_BROKER}" != "true" ]; then
      if [ -z "${CONFIG_INSTANCE_DIR+x}" ]; then
        echo "No custom configuration supplied"
      else
        echo "Using custom configuration. Copy from ${CONFIG_INSTANCE_DIR} to ${instanceDir}"
        rm -rf ${instanceDir}
        ls ${CONFIG_INSTANCE_DIR}/*
        cp -r ${CONFIG_INSTANCE_DIR}/* ${HOME}
      fi
    fi
    if [ "$1" != "nostart" ]; then
      echo "Running Broker in ${instanceDir}"
      exec ${instanceDir}/bin/artemis run
    fi
  fi
}

runServer $1
