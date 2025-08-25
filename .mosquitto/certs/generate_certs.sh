#!/bin/bash

# Create self-signed certificates for local Mosquitto testing
# This script generates CA, server, and client certificates

set -e

CERTS_DIR=$(dirname "$0")
cd "$CERTS_DIR"

# Generate CA private key
openssl genrsa -out ca.key 2048

# Generate CA certificate (valid for 100 years)
openssl req -new -x509 -days 36500 -key ca.key -out ca.crt -subj "/C=NO/ST=Oslo/L=Oslo/O=Test/OU=Test/CN=Test-CA"

# Generate server private key
openssl genrsa -out server.key 2048

# Generate server certificate signing request
openssl req -new -key server.key -out server.csr -subj "/C=NO/ST=Oslo/L=Oslo/O=Test/OU=Test/CN=localhost"

# Create server extensions file for localhost
cat > server.ext << EXTEOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = mosquitto
IP.1 = 127.0.0.1
IP.2 = ::1
EXTEOF

# Generate server certificate signed by CA (valid for 100 years)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 36500 -extfile server.ext

# Generate client private key
openssl genrsa -out client.key 2048

# Generate client certificate signing request
openssl req -new -key client.key -out client.csr -subj "/C=NO/ST=Oslo/L=Oslo/O=Test/OU=Test/CN=test-client"

# Generate client certificate signed by CA (valid for 100 years)
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 36500

# Clean up CSR files
rm server.csr client.csr server.ext

echo "Certificates generated successfully!"
echo "CA certificate: ca.crt"
echo "Server certificate: server.crt"
echo "Server key: server.key"
echo "Client certificate: client.crt"
echo "Client key: client.key"
