#!/bin/bash

echo "Current malformed entry:"
grep ".test" /etc/hosts

echo ""
echo "Fixing hosts file entry..."

# Create a temporary file with the fix
sudo sh -c '
# Read the current hosts file and fix the malformed line
sed "s/## Local - End ##127.0.0.1\t.test/## Local - End ##\n127.0.0.1\t.test/" /etc/hosts > /tmp/hosts_fixed

# Replace the hosts file with the fixed version
cp /tmp/hosts_fixed /etc/hosts
rm /tmp/hosts_fixed

echo "Hosts file fixed!"
'

echo ""
echo "New entry should be:"
grep -A1 "## Local - End ##" /etc/hosts | tail -2
