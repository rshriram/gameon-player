#!/bin/bash

# Configure amalgam8 for this container
export A8_SERVICE=players:v1
export A8_ENDPOINT_PORT=9443
export A8_ENDPOINT_TYPE=https

if [ "$SERVERDIRNAME" == "" ]; then
  SERVERDIRNAME=defaultServer
else
  # Share the configuration directory via symlink
  ln -s /opt/ibm/wlp/usr/servers/defaultServer /opt/ibm/wlp/usr/servers/$SERVERDIRNAME

  # move the convenience output dir link to the new output location
  rm /output
  ln -s $WLP_OUTPUT_DIR/$SERVERDIRNAME /output
fi

if [ "$SSL_CERT" != "" ]; then
  echo Found an SSL cert to use.
  cd /opt/ibm/wlp/usr/servers/defaultServer/resources/
  echo -e $SSL_CERT > cert.pem
  openssl pkcs12 -passin pass:keystore -passout pass:keystore -export -out cert.pkcs12 -in cert.pem
  keytool -import -v -trustcacerts -alias default -file cert.pem -storepass truststore -keypass keystore -noprompt -keystore security/truststore.jks
  keytool -genkey -storepass testOnlyKeystore -keypass wefwef -keyalg RSA -alias endeca -keystore security/key.jks -dname CN=rsssl,OU=unknown,O=unknown,L=unknown,ST=unknown,C=CA
  keytool -delete -storepass testOnlyKeystore -alias endeca -keystore security/key.jks
  keytool -v -importkeystore -srcalias 1 -alias 1 -destalias default -noprompt -srcstorepass keystore -deststorepass testOnlyKeystore -srckeypass keystore -destkeypass testOnlyKeystore -srckeystore cert.pkcs12 -srcstoretype PKCS12 -destkeystore security/key.jks -deststoretype JKS
fi

if [ "$ETCDCTL_ENDPOINT" != "" ]; then
  echo Setting up etcd...
  echo "** Testing etcd is accessible"
  etcdctl --debug ls
  RC=$?

  while [ $RC -ne 0 ]; do
      sleep 15

      # recheck condition
      echo "** Re-testing etcd connection"
      etcdctl --debug ls
      RC=$?
  done
  echo "etcdctl returned sucessfully, continuing"

  mkdir -p /opt/ibm/wlp/usr/servers/defaultServer/resources/security
  cd /opt/ibm/wlp/usr/servers/defaultServer/resources/
  etcdctl get /proxy/third-party-ssl-cert > cert.pem
  openssl pkcs12 -passin pass:keystore -passout pass:keystore -export -out cert.pkcs12 -in cert.pem
  keytool -import -v -trustcacerts -alias default -file cert.pem -storepass truststore -keypass keystore -noprompt -keystore security/truststore.jks
  keytool -genkey -storepass testOnlyKeystore -keypass wefwef -keyalg RSA -alias endeca -keystore security/key.jks -dname CN=rsssl,OU=unknown,O=unknown,L=unknown,ST=unknown,C=CA
  keytool -delete -storepass testOnlyKeystore -alias endeca -keystore security/key.jks
  keytool -v -importkeystore -srcalias 1 -alias 1 -destalias default -noprompt -srcstorepass keystore -deststorepass testOnlyKeystore -srckeypass keystore -destkeypass testOnlyKeystore -srckeystore cert.pkcs12 -srcstoretype PKCS12 -destkeystore security/key.jks -deststoretype JKS

  export MAP_KEY=$(etcdctl get /passwords/map-key)
  export COUCHDB_SERVICE_URL=$(etcdctl get /couchdb/url)
  export COUCHDB_USER=$(etcdctl get /couchdb/user)
  export COUCHDB_PASSWORD=$(etcdctl get /passwords/couchdb)
  export LOGSTASH_ENDPOINT=$(etcdctl get /logstash/endpoint)
  export LOGMET_HOST=$(etcdctl get /logmet/host)
  export LOGMET_PORT=$(etcdctl get /logmet/port)
  export LOGMET_TENANT=$(etcdctl get /logmet/tenant)
  export LOGMET_PWD=$(etcdctl get /logmet/pwd)
  export SYSTEM_ID=$(etcdctl get /global/system_id)
  export KAFKA_SERVICE_URL=$(etcdctl get /kafka/url)
  export KAFKA_USER=$(etcdctl get /kafka/user)
  export KAFKA_PASSWORD=$(etcdctl get /passwords/kafka)

  #to run with message hub, we need a jaas jar we can only obtain
  #from github, and have to use an extra config snippet to enable it.
  cd /opt/ibm/wlp/usr/servers/defaultServer
  mkdir -p configDropins/overrides
  mv kafkaDropin.xml configDropins/overrides
  wget https://github.com/ibm-messaging/message-hub-samples/raw/master/java/message-hub-liberty-sample/lib-message-hub/messagehub.login-1.0.0.jar


  # Softlayer needs a logstash endpoint so we set up the server
  # to run in the background and the primary task is running the
  # forwarder. In ICS, Liberty is the primary task so we need to
  # run it in the foreground
  if [ "$LOGSTASH_ENDPOINT" != "" ]; then
    /opt/ibm/wlp/bin/server start $SERVERDIRNAME
    echo Starting the logstash forwarder...
    sed -i s/PLACEHOLDER_LOGHOST/${LOGSTASH_ENDPOINT}/g /opt/forwarder.conf
    cd /opt
    chmod +x ./forwarder
    etcdctl get /logstash/cert > logstash-forwarder.crt
    etcdctl get /logstash/key > logstash-forwarder.key
    sleep 0.5
    ./forwarder --config ./forwarder.conf
  else
    /opt/ibm/wlp/bin/server run $SERVERDIRNAME
  fi
else
  # LOCAL DEVELOPMENT!
  # We do not want to ruin the cloudant admin party, but our code is written to expect
  # that creds are required, so we should make sure the required user/password exist
  export AUTH_HOST="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@couchdb:5984"
  SERVER_PATH=/opt/ibm/wlp/usr/servers/$SERVERDIRNAME

  echo "** Testing connection to ${AUTH_HOST}"
  curl --fail ${AUTH_HOST}/_config/admins/${COUCHDB_USER}
  RC=$?

  # RC=7 means the host isn't there yet. Let's do some re-trying until it
  # does start / is ready
  while [ $RC -eq 7 ]; do
      sleep 15

      # recheck condition
      echo "** Re-testing connection to ${AUTH_HOST}"
      curl --fail ${AUTH_HOST}/_config/admins/${COUCHDB_USER}
      RC=$?
  done

  # RC=22 means the user doesn't exist
  if [ $RC -eq 22 ]; then
    echo "** Creating ${COUCHDB_USER}"
    curl -X PUT ${COUCHDB_SERVICE_URL}/_config/admins/${COUCHDB_USER} -d \"${COUCHDB_PASSWORD}\"
  fi

  echo "** Checking database"
  curl --fail ${AUTH_HOST}/playerdb
  if [ $? -eq 22 ]; then
    curl -X PUT $AUTH_HOST/playerdb
  fi

  echo "** Checking design documents"
  curl --fail ${AUTH_HOST}/playerdb/_design/players
  if [ $? -eq 22 ]; then
    curl -X PUT -H "Content-Type: application/json" --data @/opt/player.json ${AUTH_HOST}/playerdb/_design/players
  fi

  exec a8sidecar --log --proxy --register --supervise /opt/ibm/wlp/bin/server run $SERVERDIRNAME
fi
