#!/bin/bash
# Author: Ozgur SALGINCI
# Load configuration file
if [ -f "elastic_config.env" ]; then
  source elastic_config.env
else
  echo "Configuration file elastic_config.env not found!"
  exit 1
fi

# Check for sufficient arguments
if [ $# -ne 3 ]; then
  echo "Usage: $0 <cluster-name> <role: master|data> <node-name>"
  echo "Example: $0 my-cluster master master-1"
  exit 1
fi

CLUSTER_NAME=$1
ROLE=$2
NODE_NAME=$3

# Select YAML based on role
if [ "$ROLE" == "master" ]; then
  YAML_FILE="master_node.yaml"
elif [ "$ROLE" == "data" ]; then
  YAML_FILE="datanode.yaml"
else
  echo "Invalid role: $ROLE. Use 'master' or 'data'."
  exit 1
fi

# Validate configuration variables
if [ -z "$ELASTIC_VERSION" ] || [ -z "$INSTALL_DIR" ] || [ -z "$CONFIG_DIR" ] || [ -z "$DATA_DIR" ] || [ -z "${SEED_HOSTS[*]}" ]; then
  echo "One or more required environment variables are missing. Please check elastic_config.env."
  exit 1
fi

# Set persistent ulimit for elasticsearch user
echo "Setting ulimit for 'elasticsearch' user to 65535..."

# Check if the limit is already set in /etc/security/limits.conf
if ! grep -q "elasticsearch  -  nofile  65535" /etc/security/limits.conf; then
  echo "Adding ulimit for elasticsearch user to /etc/security/limits.conf..."
  echo "elasticsearch  -  nofile  65535" | sudo tee -a /etc/security/limits.conf > /dev/null
else
  echo "ulimit for elasticsearch user is already set in /etc/security/limits.conf."
fi

# Ensure PAM limits are applied (if needed on your system)
if ! grep -q "session required pam_limits.so" /etc/pam.d/common-session; then
  echo "Ensuring pam_limits.so is configured for session limits..."
  echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session > /dev/null
else
  echo "pam_limits.so is already configured."
fi

# Set vm.max_map_count permanently
echo "Setting vm.max_map_count to 262144..."

# Check if vm.max_map_count is already set in /etc/sysctl.conf
if ! grep -q "vm.max_map_count=262144" /etc/sysctl.conf; then
  echo "Adding vm.max_map_count=262144 to /etc/sysctl.conf..."
  echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf > /dev/null
else
  echo "vm.max_map_count is already set in /etc/sysctl.conf."
fi

# Reload sysctl configuration to apply the change
sudo sysctl -p

# Install and configure Elasticsearch
if [ ! -d "$INSTALL_DIR" ]; then
  echo "Downloading and installing Elasticsearch $ELASTIC_VERSION..."
  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ELASTIC_VERSION-linux-x86_64.tar.gz
  if [ $? -ne 0 ]; then
    echo "Failed to download Elasticsearch. Exiting."
    exit 1
  fi
  tar -xzf elasticsearch-$ELASTIC_VERSION-linux-x86_64.tar.gz
  sudo mv elasticsearch-$ELASTIC_VERSION "$INSTALL_DIR"
  rm elasticsearch-$ELASTIC_VERSION-linux-x86_64.tar.gz
else
  echo "Elasticsearch is already installed at $INSTALL_DIR."
fi

# Create a dedicated user and group for Elasticsearch if not exists
echo "Creating 'elasticsearch' user and group..."
if ! id -u elasticsearch &>/dev/null; then
  sudo groupadd elasticsearch
  sudo useradd -g elasticsearch -s /bin/bash -M -r elasticsearch
else
  echo "'elasticsearch' user and group already exist."
fi

# Ensure the required directories exist
echo "Ensuring required directories exist..."
sudo mkdir -p "$DATA_DIR" "$CONFIG_DIR" "/var/log/elasticsearch"

# Set permissions for Elasticsearch directories
echo "Setting file permissions..."
sudo chown -R elasticsearch:elasticsearch "$INSTALL_DIR"
sudo chown -R elasticsearch:elasticsearch "$DATA_DIR"
sudo chown -R elasticsearch:elasticsearch "$CONFIG_DIR"
sudo chown -R elasticsearch:elasticsearch /var/log/elasticsearch
sudo chmod -R 755 /var/log/elasticsearch

# Check if UFW is installed, and install it if necessary
echo "Checking if ufw is installed..."
if ! command -v ufw &> /dev/null; then
  echo "UFW is not installed. Installing ufw..."
  sudo apt-get update -y
  sudo apt-get install -y ufw
  sudo ufw enable
else
  echo "UFW is already installed."
fi

# Update the package index and install prerequisites
echo "Installing additional dependencies..."
sudo apt-get install -y wget curl apt-transport-https openjdk-17-jdk

# Create the final YAML content for Elasticsearch
echo "Creating final YAML configuration for $ROLE node..."

# Start with the template (either master or data YAML file)
if [ "$ROLE" == "master" ]; then
  FINAL_YAML=$(cat <<EOF
node.name: $NODE_NAME
node.roles: ["master"]
http.port: 9200
network.host: 0.0.0.0
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.client_authentication: required
xpack.security.transport.ssl.keystore.path: elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: elastic-certificates.p12
xpack.security.http.ssl.enabled: false
path.data: /data
path.logs: /var/log/elasticsearch
cluster.name: $CLUSTER_NAME
cluster.initial_master_nodes:
  - "$NODE_NAME"
discovery.seed_hosts:

EOF
)

   # Add seed hosts with proper indentation under discovery.seed_hosts
  for SEED in "${SEED_HOSTS[@]}"; do
    FINAL_YAML+=$(printf '\n  - "%s%b"\n' "$SEED")
  done

elif [ "$ROLE" == "data" ]; then
  FINAL_YAML=$(cat <<EOF
node.name: $NODE_NAME
node.roles: ["data"]
network.host: 0.0.0.0
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.client_authentication: required
xpack.security.transport.ssl.keystore.path: elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: elastic-certificates.p12
xpack.security.http.ssl.enabled: false
path.data: /data
path.logs: /var/log/elasticsearch
cluster.name: $CLUSTER_NAME
discovery.seed_hosts:

EOF
)

  # Add seed hosts with proper indentation under discovery.seed_hosts
  for SEED in "${SEED_HOSTS[@]}"; do
    FINAL_YAML+=$(printf '\n  - "%s%b"\n' "$SEED")
  done

fi

# Now that Elasticsearch is installed, copy the final YAML content to CORE_CONFIG_DIR
echo "$FINAL_YAML" | sudo tee "$CORE_CONFIG_DIR" > /dev/null

# Verify the YAML file has been updated
if [ -f "$CORE_CONFIG_DIR" ]; then
  echo "YAML configuration file has been successfully updated in $CORE_CONFIG_DIR."
else
  echo "Failed to update the YAML configuration file."
  exit 1
fi

# Configure firewall to allow Elasticsearch ports (9200 and 9300)
echo "Configuring firewall to allow incoming traffic on ports 9200 and 9300..."
sudo ufw allow 9200:9300/tcp
sudo ufw allow 8000
sudo ufw reload
## NEWCODE BLOCK START
if [ "$ROLE" == "master" ]; then
  # Navigate to the Elasticsearch install folder
  cd /opt/elasticsearch
  
  # Generate the CA certificate
  ./bin/elasticsearch-certutil ca

  # Generate the Elasticsearch certificate using the CA
  ./bin/elasticsearch-certutil cert --ca elastic-stack-ca.p12
  
  # Copy the elastic-certificates.p12 file to the config folder
  cp elastic-certificates.p12 config/

  # Start a Python HTTP server to serve the file for temporary use
  echo "Starting Python HTTP server on port 8000..."
  
  # Check if Python3 is installed, and install it if not
  if ! command -v python3 &> /dev/null; then
    echo "Python3 not found, installing it..."
    sudo apt-get update -y
    sudo apt-get install -y python3
  fi
  
  python3 -m http.server 8000 &
  
  # Inform the user how to download the file
  echo "You can now download the certificate from http://<your-server-ip>:8000/elastic-certificates.p12"
  
  # Wait for the user to press Ctrl+C to stop the server
  wait
  
  # Once the server is stopped, the script will continue
  echo "Python HTTP server has been stopped. Continuing with the script..."

  # Add permissions for the elasticsearch user to the certificate file
  echo "Setting permissions for elasticsearch user on elastic-certificates.p12..."
  sudo chown elasticsearch:elasticsearch /opt/elasticsearch/config/elastic-certificates.p12
  sudo chmod 644 /opt/elasticsearch/config/elastic-certificates.p12

fi


if [ "$ROLE" == "data" ]; then
  # Navigate to the /opt/elasticsearch/config folder
  cd /opt/elasticsearch/config
  
  # Get the first seed host from SEED_HOSTS and construct the URL
  SEED_HOST_IP="${SEED_HOSTS[0]}"
  URL="http://$SEED_HOST_IP:8000/elastic-certificates.p12"
  
  # Check if wget is installed, and install it if not
  if ! command -v wget &> /dev/null; then
    echo "wget not found, installing it..."
    sudo apt-get update -y
    sudo apt-get install -y wget
  fi

  # Try to download the elastic-certificates.p12 file with retries
  echo "Attempting to download elastic-certificates.p12 from $URL..."
  RETRIES=0
  MAX_RETRIES=50

  until wget "$URL" -O elastic-certificates.p12; do
    if [ $RETRIES -ge $MAX_RETRIES ]; then
      echo "Failed to download elastic-certificates.p12 after $MAX_RETRIES attempts. Exiting."
      exit 1
    fi
    echo "Download failed, retrying... ($((RETRIES+1))/$MAX_RETRIES)"
    ((RETRIES++))
    sleep 5
  done

  # Once the file is downloaded, set permissions for elasticsearch user
  echo "Setting permissions for elasticsearch user on elastic-certificates.p12..."
  sudo chown elasticsearch:elasticsearch elastic-certificates.p12
  sudo chmod 644 elastic-certificates.p12

fi


## NEWCODE BLOCK END

# Create a systemd service file for Elasticsearch
echo "Creating systemd service..."
sudo bash -c 'cat > /etc/systemd/system/elasticsearch.service << EOF
[Unit]
Description=Elasticsearch
Documentation=https://elastic.co
After=network.target

[Service]
User=elasticsearch
Group=elasticsearch
ExecStart=/opt/elasticsearch/bin/elasticsearch
Restart=always

[Install]
WantedBy=multi-user.target
EOF'

# Enable and start the service
echo "Starting Elasticsearch service..."
sudo systemctl daemon-reload
sudo systemctl enable elasticsearch
sudo systemctl start elasticsearch

# Verify the service
echo "Verifying Elasticsearch status..."
sudo systemctl status elasticsearch --no-pager

# Final check to ensure Elasticsearch is running
if curl -X GET "http://localhost:9200" &>/dev/null; then
  echo "Elasticsearch is running and accessible."
else
  echo "Elasticsearch service failed to start or is not accessible. Check logs for details."
fi

echo "Elasticsearch installation and configuration complete for role: $ROLE, node name: $NODE_NAME."
