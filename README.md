# kafka-connect-deployer
Deploy Kafka Connect cluster

Steps: 
- Clone this repo
- Update the cred.lab with the username and keyfile location and connect.lab with the IP addresses of the instances for your Kafka Connect Cluster. 
- Run the following commands as needed: 

To build the package 
 `./connect_deployer.sh --build ` 
 
To deploy the package onto the connect lab instances
 `./connect_deployer.sh --deploy ` 
 
To start kafka-connect cluster
 `./connect_deployer.sh --start ` 
 
To stop kafka-connect cluster
 `./connect_deployer.sh --stop `
 
To restart kafka-connect cluster
 `./connect_deployer.sh --restart ` 
 
To clean/ uninstall kafka-connect cluster
 `./connect_deployer.sh --clean `  

To check the status of the kafka-connect cluster
 `./connect_deployer.sh --check `
 
