#!/bin/sh

export BROKER_IP=`hostname -f`

instanceDir="${HOME}/${AMQ_NAME}"

ENDPOINT_NAME="${AMQ_NAME}-amq-headless"
if [ "$HEADLESS_SVC_NAME" ]; then
  ENDPOINT_NAME=$HEADLESS_SVC_NAME
fi

endpointsUrl="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/api/v1/namespaces/${POD_NAMESPACE}/"
endpointsAuth="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

function waitForJolokia() {
  while : ;
  do
    sleep 5
    curl -s -o /dev/null -G -k http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_IP}:8161/console/jolokia
    if [ $? -eq 0 ]; then
      break
    fi
  done
}


endpointsCode=$(curl -s -o /dev/null -w "%{http_code}" -G -k -H "${endpointsAuth}" ${endpointsUrl})
if [ $endpointsCode -ne 200 ]; then
  echo "Can't find endpoints with ips status <${endpointsCode}>" 
  exit 1
fi

ENDPOINTS=$(curl -s -X GET -G -k -H "${endpointsAuth}" ${endpointsUrl}"endpoints/${ENDPOINT_NAME}")
echo $ENDPOINTS
count=0
while [ 1 ]; do
  ip=$(echo $ENDPOINTS | python -c "import sys, json; print json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['ip']")
  if [ $? -ne 0 ]; then
    echo "Can't find ip to scale down to tried ${count} ips"
    exit
  fi

  echo "got ip ${ip} broker ip is ${BROKER_IP}"
  if [ "$ip" != "$BROKER_IP" ]; then
    break
  fi

  count=$(( count + 1 ))
done

source /opt/amq/bin/launch.sh nostart

SCALE_TO_BROKER_IP=$ip

# Add connector to the pod to scale down to
connector="<connector name=\"scaledownconnector\">tcp:\/\/${SCALE_TO_BROKER_IP}:61616<\/connector>"
sed -i "/<\/connectors>/ s/.*/${connector}\n&/" ${instanceDir}/etc/broker.xml

# Ensure we set the ha-policy to cleanup the sf queue. We will put it after the </connectors>
hapolicy="<ha-policy><live-only><scale-down><connectors><connector-ref>scaledownconnector<\/connector-ref><\/connectors><cleanup-sf-queue>true<\/cleanup-sf-queue><\/scale-down><\/live-only><\/ha-policy>"
sed -i "/<\/acceptors>/ s/.*/&\n${hapolicy}\n/" ${instanceDir}/etc/broker.xml

# Remove the acceptors
#sed -i -ne "/<acceptors>/ {p;   " -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml
acceptor="<acceptor name=\"artemis\">tcp:\/\/${BROKER_IP}:61616?protocols=CORE<\/acceptor>"
sed -i -ne "/<acceptors>/ {p; i $acceptor" -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml

#start the broker and issue the scaledown command to drain the messages.
${instanceDir}/bin/artemis-service start

if [ "$AMQ_DATA_DIR_LOGGING" = "true" ]; then
  tail -n 100 -f ${AMQ_DATA_DIR}/log/artemis.log &
else
  tail -n 100 -f ${AMQ_NAME}/log/artemis.log &
fi

waitForJolokia
curl -s -o /dev/null -G -k http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_IP}:8161/console/jolokia/exec/org.apache.activemq.artemis:broker=%22${AMQ_NAME}%22/scaleDown/scaledownconnector
