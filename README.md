# alluxio-nginx-s3-proxy
Use Nginx to expose the Alluxio S3 API to client apps like Teradata NOS and Vertica

## Background

Alluxio is a powerful tool for bringing data closer to your compute workloads. With a unifield namespace, many application APIs, many data source APIs, local caching and policy based data management capabilities, Alluxio can:

- help reduce costs by reducing data copies and cloud storage egress costs
- increase performance by caching data close to the user workloads
- provide a heterogeneous data environment where users do not have to know where the data is stored

See: https://docs.alluxio.io/os/user/stable/en/Overview.html

One method that users and applications use to submit read/write requests to Alluxio is to use the Alluxio S3 API. The Alluxio S3 API exposes an S3 "endpoint" and that endpoint includes an API version specification like this:

     http://alluxio-worker:39999/api/v1/s3/my_bucket/my_dataset

That S3 endpoint is used by S3 clients when they connect to the Alluxio S3 API. For example, the AWS S3 command line interface (CLI) can connect to Alluxio using the --endpoint option like this:

     aws s3 ls s3://my_bucket/my_dataset/ --endpoint http://alluxio-worker:39999/api/v1/s3

Some query engines, including Teradata NOS and Vertica, do not allow users to specify the S3 endpoint as a property, and they do not expect to see an API version in the S3 URI (i.e. /api/v1/s3/). 

Alluxio has an open JIRA requesting a change to the Alluxio endpoint specification, but until that change is implemented Alluxio customers can use an Nginx proxy server that translates the S3 URI that is generated by Teradata and Vertica into an S3 URI that works with the Alluxio S3 API. The BASH script included in this Git repo can be used to install, configure and deploy the Nginx server on Alluxio worker nodes. Nginx will convert a URI like this:

     http://<alluxio-worker>:39998/my_bucket/my_dataset
     
to a URI like this:

     http://<alluxio-worker>:39999/api/v1/s3/my_bucket/my_dataset

Note that port number 39998 is being monitored by the Nginx server and port 39999 is being monitored by the Alluxio S3 API.

## Deploy Nginx as an Alluxio S3 proxy

### Step 1. Install and configure Nginx on Alluxio workers

Run the install-alluxio-s3-proxy-server-on-worker.sh BASH script on each Alluxio worker node where the current Alluxio S3 API server is running.

a. On each Alluxio worker node, download and run the BASH script as the root user or as a user with SUDO privileges: 

     wget https://raw.githubusercontent.com/gregpalmr/alluxio-nginx-s3-proxy/main/install-alluxio-s3-proxy-server-on-worker.sh
     
     sudo bash install-alluxio-s3-proxy-server-on-worker.sh
     
b. View the Nginx configuration file that was saved in the Alluxio conf directory:

     cat $ALLUXIO_HOME/conf/alluxio-s3-proxy.conf

c. Start the Nginx server as the user that runs the Alluxio processes:

     sudo su - my_alluxio_user

     $ALLUXIO_HOME/bin/alluxio-start-s3-proxy.sh
     

d. Test the Nginx proxy server

Use a curl command to issue an HTTP request that invokes the Nginx proxy so it can forward the request to the real Alluxio S3 API service. Something like this:

     curl -i --output ./part_00000.snappy.parquet \
         -H \"Authorization: AWS4-HMAC-SHA256 Credential=<my_alluxio_user>/\" \
         -X GET http://<alluxio-worker>:39998/my_bucket/my_dataset/part_00000.snappy.parquet

e. Optionally, stop the Nginx server:

     sudo su - my_alluxio_user

     $ALLUXIO_HOME/bin/alluxio-stop-s3-proxy.sh
     
### Step 2. Configure round-robin load balancing in the DNS server

Have your networking team configure your organization's domain name service (DNS) to provide simple round-robin load balancing across all of your Alluxio worker node servers. Most Linux based DNS servers would be configured like this:

      # Use DNS load balancing to round-robin the Alluxio workers
     address=/alluxio-prod-worker.mycompany.com/10.0.2.1
     address=/alluxio-prod-worker.mycompany.com/10.0.2.2
     address=/alluxio-prod-worker.mycompany.com/10.0.2.3

If you have dedicated load balancers (i.e. F5), then you can configure them to provide this load balancing service. With load balancing enabled, client side applications like Spark, Trino, Presto will only reference the single hostname and will be provided with rotating ip addresses for Alluxio workers.

## Access Alluxio with Teradata NOS

Teradata NOS provides the capability to create foreign database table definitions that provide access to S3 compatible storage environments such as Alluxio.

### Step 1. Configure Teradata NOS

Before creating the external tables, modify the Teradata NOS configuration to allow "path style" bucket addressing. On the Teradata master node, run the "dbscontrol" program:  

     dbscontrol
     
          display nos
	  
          # Enable path style bucket addressing (AllowToForceS3pathstyle = True)
          MODIFY NOS 134 = T

          # Disable HTTPS (Disable HTTPS = True)
          MODIFY NOS 101 = T
	  
	  # Save the changes
	  WRITE

### Step 2. Create a user with privilages to access external NOS tables.

a. Create a Teradata user

If not already created, create a user to own the foreign tables and grant the appropriate privileges. Connect to the DBC database as the administrator user and run these commands:

     -- Create user
     CREATE USER nos_user FROM dbc AS PERMANENT=30e8 PASSWORD="changeme123";
     
     -- Grant CREATE TABLE
     GRANT CREATE TABLE on nos_user to nos_user;
     
     -- Grant READ_NOS
     GRANT EXECUTE FUNCTION on TD_SYSFNLIB.READ_NOS to nos_user;
     
     -- Grant WRITE_NOS
     GRANT EXECUTE FUNCTION on TD_SYSFNLIB.WRITE_NOS to nos_user;
     
     -- Grant CREATE AUTORIZATION
     GRANT CREATE AUTHORIZATION on nos_user to nos_user;

b. Create an authorization object

Connect to the nos_user database as the new user and create an S3 AUTHORIZATION object to be used to store the AWS ACCESS_KEY_ID and SECRET_KEY:

     CREATE AUTHORIZATION nos_user.Alluxio_S3_PROD
     USER 'alluxio'
     PASSWORD 'NA';

     SHOW AUTHORIZATION nos_user.Alluxio_S3_PROD;
     
c. Create a database table that points to the Alluxio S3 bucket

Connect to the nos_user database as the new user and create an foreign table that references an Alluxio S3 bucket. Note that the <alluxio-prod-worker> is the DNS load balanced hostname and port 39998 is the Nginx port number on the Alluxio worker nodes.

     CREATE FOREIGN TABLE my_alluxio_data
     , EXTERNAL SECURITY  Alluxio_S3_PROD
     USING (LOCATION('/s3/<alluxio-prod-worker>:39998/my_bucket/my_dataset/') );

d. Query the foreign table
	
     SELECT Col1, Col2, Col3 FROM my_alluxio_data;
	
## Access Alluxio with Vertica

TBD

---
TODO List:

- Enable Nginx to accept and pass on Alluxio SSL certificates for TLS (Alluxio Enterprise Edition only)

---
Please direct questions or comments to greg.palmer@alluxio.com
