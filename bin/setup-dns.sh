#!/bin/bash

# Setup script for .test domain DNS resolution
# This adds .test to your local hosts file

HOSTNAME=".test"
HOSTS_FILE="/etc/hosts"
ENTRY="127.0.0.1	$HOSTNAME"

echo "Setting up local DNS resolution for $HOSTNAME..."

# Check if entry already exists
if grep -q "$HOSTNAME" "$HOSTS_FILE" 2>/dev/null; then
    echo "✓ DNS resolution for $HOSTNAME already exists"
else
    echo "Adding DNS entry: $ENTRY"
    echo "This requires sudo access..."
    echo -e "\n$ENTRY" | sudo tee -a "$HOSTS_FILE"
    echo "✓ DNS resolution for $HOSTNAME added successfully"
fi

echo ""
echo "You can now access your Anglesite development server at:"
echo "https://$HOSTNAME:8080"
echo ""
echo "To remove this entry later, run:"
echo "sudo sed -i '' '/$HOSTNAME/d' $HOSTS_FILE"