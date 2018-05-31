#!/bin/sh

export BROKER_IP=`hostname -I | cut -f 1 -d ' '`

instanceDir="${HOME}/${AMQ_NAME}"

ENDPOINT_NAME="${AMQ_NAME}-amq-tcp"

endpointsUrl="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/api/v1/namespaces/${POD_NAMESPACE}/"
endpointsAuth="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

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

source /opt/amq/bin/launch.sh

SCALE_TO_BROKER_IP=$ip

# Add connector to the pod to scale down to
connector="<connector name=\"scaledownconnector\">tcp:\/\/${SCALE_TO_BROKER_IP}:61616<\/connector>"
sed -i "/<\/connectors>/ s/.*/${connector}\n&/" ${instanceDir}/etc/broker.xml

# Remove the acceptors
#sed -i -ne "/<acceptors>/ {p;   " -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml
acceptor="<acceptor name=\"artemis\">tcp:\/\/${BROKER_IP}:61616?protocols=CORE<\/acceptor>"
sed -i -ne "/<acceptors>/ {p; i $acceptor" -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml

#start the broker and issue the scaledown command to drain the messages.
${instanceDir}/bin/artemis-service start
sleep 15
curl http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_IP}:8161/console/jolokia/exec/org.apache.activemq.artemis:broker=%22broker%22/scaleDown/scaledownconnector

tail -n 100 -f broker/log/artemis.log &

ps -C java

while [ $? -eq 0 ]
do
  sleep 15;
  ps -C java;
done
