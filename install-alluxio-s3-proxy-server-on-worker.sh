#!/bin/bash
#
# SCRIPT:    install-alluxio-s3-proxy-server-on-worker.sh
#
# DESCR:     This script installs the Nginx proxy service to allow Alluxio S3 clients
#            to reference the Alluxio S3 API without the /api/v1/s3 part of the
#            endpoint specification.
#
# USAGE:     Step 1. Configure DNS or another type of load-balancing
#
#            Have your networking team set up round-robin DNS load-balancing for all of
#            your Alluxio worker nodes, so that external client-side S3 clients can
#            reference one hostname for all Alluxio workers, like this:
#
#                 # Use DNS load balancing to round-robin the Alluxio workers
#                 address=/alluxio-prod-worker.mycompany.com/10.0.2.1
#                 address=/alluxio-prod-worker.mycompany.com/10.0.2.2
#                 address=/alluxio-prod-worker.mycompany.com/10.0.2.3
#
#            Step 2. Install and Configure Nginx for Alluxio integration
#
#            On each Alluxio worker node, run this script to install and configure Nginx to front end
#            the Alluxio S3 API daemon and to accept S3 calls without the Alluxio /api/v1/s3 part of
#            the endpoint specification.
#
#            As the root user, run the script like this:
#
#                bash install-alluxio-s3-proxy-server-on-worker.sh
#
#            As a user with sudo privileges, run the script like this:
#
#                sudo bash install-alluxio-s3-proxy-server-on-worker.sh
#
#            then, start the Nginx server on each Alluxio worker node, as the same 
#            user that you start the Alluxio daemons as. Use the command:
#          
#                 $ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh
#
#            then, test the Nginx server with a curl command like this:
#
#                curl -i --output ./part_00000.snappy.parquet \
#                               -H \"Authorization: AWS4-HMAC-SHA256 Credential=<my_alluxio_user>/\" \
#                               -X GET http://<alluxio-prod-worker>:39998/my_bucket/my_dataset/part_00000.snappy.parquet"
#


### FUNCTIONS ###

function print_usage {
    echo ""
    echo " USAGE: install-alluxio-s3-proxy-server-on-worker.sh "
    echo ""
} # end of function

function find_alluxio_cli {

  # Find the Alluxio CLI command location
  if [ $(which alluxio &> /dev/null) ]; then
    ALLUXIO_CLI=$(which alluxio)
    echo "  Found alluxio cli in path"
  elif [ -f /opt/alluxio/bin/alluxio ]; then
    ALLUXIO_CLI=/opt/alluxio/bin/alluxio
    echo "  Found Alluxio CLI command in /opt/alluxio/bin"
  elif [ "$ALLUXIO_HOME" != "" ] && [ -f $ALLUXIO_HOME/bin/alluxio ]; then
    ALLUXIO_CLI=$ALLUXIO_HOME/bin/alluxio
    echo "  Found Alluxio CLI command in \$ALLUXIO_HOME/bin"
  else
    echo "  Error: Unable to find Alluxio CLI command in path, \$ALLUXIO_HONE/bin or in /opt/alluxio/bin. Exiting."
    exit -1
  fi
} # end of function

function install_nginx {

  # If nginx is already installed do nothing
  which nginx &> /dev/null
  if [ $? == 0 ]; then
    echo "  Nginx already installed, skipping install."
    return
  fi

  echo "  Installing Nginx package"
  # Attempt to install nginx
  $(which yum &> /dev/null)
  if [ $? == 0 ]; then
    # Try to install nginx with yum
    result=$(yum list nginx)
    if [[ ! "$result" == *"nginx.x86_64"* ]]; then
      echo "  Error: Unable to install Nginx package with yum, \"package nginx.x86_64\" not available. Exiting."
      exit -1
    fi
    echo "  Installing Nginx package with command: yum -y install nginx"
    yum -y install nginx &> /dev/null
  elif [ $(which apt &> /dev/null) ] && [ $? == 0 ]; then
      # Try to install nginx with apt-get
      result=$(apt list | grep ^nginx)
      if [ "$result" == "" ]; then
        echo "  Error: Unable to install Nginx package with apt, \"package nginx\" not found. Exiting."
        exit -1
      fi
      echo "  Installing Nginx package with command: apt-get -y install nginx"
      apt-get -y install nginx &> /dev/null
  elif [ $(uname -s) == "Darwin" ]; then
      echo
      echo "  Error: Unable to install Nginx as root user. Please run the following command as your own user:"
      echo
      echo "       brew install nginx "
      echo
      echo "  Then re-run this script."
      echo
      exit -1
  else
      echo "  Error: Unable to find a package manager to install package nginx (tried yum, apt and brew). Exiting."
      exit -1
  fi

  # final test to make sure nginx was installed
  which nginx &> /dev/null
  if [ $? != 0 ]; then
    echo "  Error: Nginx package could not be installed. Exiting."
    exit -1
  fi
} # end of function

function create_nginx_conf_file {

  echo "  Creating Nginx conf file in: $THIS_ALLUXIO_HOME/conf/alluxio-s3-proxy.conf"

  cat > $THIS_ALLUXIO_HOME/conf/alluxio-s3-proxy.conf <<EOF
#!/usr/bin/env bash
#
# The Alluxio Open Foundation licenses this work under the Apache License, version 2.0
# (the "License"). You may not use this work except in compliance with the License, which is
# available at www.apache.org/licenses/LICENSE-2.0
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied, as more fully set forth in the License.
#
# See the NOTICE file distributed with this work for information regarding copyright ownership.
#
worker_processes auto;
error_log $THIS_ALLUXIO_HOME/logs/s3_proxy.out info;
pid /tmp/alluxio-nginx/nginx.pid;

events {
  worker_connections 768;
}

http {
  log_format upstreamlog '[\$time_local] \$remote_addr | \$remote_user | http_host: \$http_host | \$host to: \$upstream_addr: \$request \$request_uri \$status upstream_response_time \$upstream_response_time msec \$msec request_time \$request_time | Proxy: "\$proxy_host" "\$upstream_addr"';
  access_log            $THIS_ALLUXIO_HOME/logs/s3_proxy.log upstreamlog;
  client_body_temp_path /tmp/alluxio-nginx 1 2;
  proxy_temp_path       /tmp/alluxio-nginx 1 2;
  fastcgi_temp_path     /tmp/alluxio-nginx 1 2;
  scgi_temp_path        /tmp/alluxio-nginx 1 2;
  uwsgi_temp_path       /tmp/alluxio-nginx 1 2;

  server {
    listen 39998;
    server_name  _;
    root         /usr/share/nginx/html;
    client_max_body_size 50m;
    location  / {
      proxy_connect_timeout 300s;
      proxy_send_timeout    300s;
      proxy_read_timeout    300s;

      proxy_pass http://127.0.0.1:39999/api/v1/s3\$uri\$is_args\$args;
      proxy_set_header Host \$host:\$server_port;
    }
  }
}
EOF

} # end of function

function create_nginx_start_script {
  # Create a script in $ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh
  # to start this proxy on the Alluxio worker node

  echo "  Creating Nginx start script in: $THIS_ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh"

  cat > $THIS_ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh <<EOF
#!/usr/bin/env bash
#
# The Alluxio Open Foundation licenses this work under the Apache License, version 2.0
# (the "License"). You may not use this work except in compliance with the License, which is
# available at www.apache.org/licenses/LICENSE-2.0
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied, as more fully set forth in the License.
#
# See the NOTICE file distributed with this work for information regarding copyright ownership.
#

# First stop the old nginx process
nginx -s stop -c $THIS_ALLUXIO_HOME/conf/alluxio-s3-proxy.conf &>/dev/null

# Then, start the new nginx process
echo "  Starting Alluxio Nginx S3 proxy server"
nginx -c $THIS_ALLUXIO_HOME/conf/alluxio-s3-proxy.conf -e $THIS_ALLUXIO_HOME/logs/nginx-error.log

# end of script
EOF

  mkdir -p /tmp/alluxio-nginx
  chmod +x $THIS_ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh

} # end of function

function create_nginx_stop_script {
# Create a script in $ALLUXIO_HOME/bin/alluxio-stop-s3-proxy.sh
# to stop this proxy on the Alluxio worker node

  echo "  Creating nginx stop  script in: $THIS_ALLUXIO_HOME/bin/alluxio-stop-s3-proxy.sh"

cat > $THIS_ALLUXIO_HOME/bin/alluxio-stop-s3-proxy.sh <<EOF
#!/usr/bin/env bash
#
# The Alluxio Open Foundation licenses this work under the Apache License, version 2.0
# (the "License"). You may not use this work except in compliance with the License, which is
# available at www.apache.org/licenses/LICENSE-2.0
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied, as more fully set forth in the License.
#
# See the NOTICE file distributed with this work for information regarding copyright ownership.
#

# Stop the nginx process
echo "  Stopping Alluxio Nginx S3 proxy server"
nginx -s stop -c $THIS_ALLUXIO_HOME/conf/alluxio-s3-proxy.conf

# end of script
EOF

  chmod +x $THIS_ALLUXIO_HOME/bin/alluxio-stop-s3-proxy.sh

} # end of function

### MAIN ###

echo
echo "  $(date "+%Y:%m:%d %H:%M:%S:%M") Installing and configuring Alluxio S3 proxy "
echo

# Check if port 39998 is already in use
(echo >/dev/tcp/localhost/39998) &>/dev/null
if [ "$?" == 0 ]; then
  echo "  Error: Required port 39998 is already in use on this server. Exiting."
  exit -1
fi

# Get alluxio cli location and install nginx if needed
find_alluxio_cli

# Set a local version of ALLUXIO_HOME
THIS_ALLUXIO_HOME=$(dirname $ALLUXIO_CLI)/..

# Install Nginx if not already installed
install_nginx

# Create an nginx configuration script for this Alluxio worker
create_nginx_conf_file

# Create script to start the nginx proxy service
create_nginx_start_script

# Create script to stop the nginx proxy service
create_nginx_stop_script

echo
echo "  $(date "+%Y:%m:%d %H:%M:%S:%M") Script complete"
echo
echo "  Start the Alluxio S3 proxy Nginx server as the same user that you start the Alluxio "
echo "  daemon with. Run the start script:"
echo
echo "     \$ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh"
echo
echo "  Then, test the Nginx proxy with the \"curl\" command like this:"
echo
echo "    curl -i --output ./part_00000.snappy.parquet \\ "
echo "         -H \"Authorization: AWS4-HMAC-SHA256 Credential=<my_alluxio_user>/\" \\ "
echo "         -X GET http://<alluxio-prod-worker>:39998/my_bucket/my_dataset/part_00000.snappy.parquet"
echo
# end of script
