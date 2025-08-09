#!/bin/bash

echo "Setting up mkcert for Anglesite development..."
echo ""
echo "This script will:"
echo "1. Install mkcert's local Certificate Authority"
echo "2. Generate trusted certificates for *.anglesite.test"
echo ""

# Install the local CA (requires admin password)
echo "Installing local Certificate Authority (requires admin password)..."
mkcert -install

# Create certificates directory
mkdir -p certs

# Generate wildcard certificate for *.test and other domains
echo ""
echo "Generating certificates for Anglesite domains..."
mkcert -cert-file certs/anglesite-cert.pem -key-file certs/anglesite-key.pem "*.test" "test" "localhost" "127.0.0.1"

echo ""
echo "✅ Setup complete!"
echo ""
echo "Certificates created in ./certs/"
echo "- certs/anglesite-cert.pem (certificate)"
echo "- certs/anglesite-key.pem (private key)"
echo ""
echo "These certificates are trusted by your system and will work in Safari!"