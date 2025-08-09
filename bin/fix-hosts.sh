#!/bin/bash

# Fix the malformed hosts file entry
echo "Fixing hosts file entry..."
echo "Current problematic line:"
grep ".test" /etc/hosts

echo ""
echo "To fix this manually, run:"
echo "sudo nano /etc/hosts"

echo ""
echo "Find the line: ## Local - End ##127.0.0.1\t.test"
echo "Replace with:"
echo "## Local - End ##"
echo "127.0.0.1\t.test"

echo ""
echo "Or run this command:"
echo 'sudo sh -c "sed -i.bak '\''s/## Local - End ##127.0.0.1\.test/## Local - End ##\\n127.0.0.1\.test/'\'' /etc/hosts"'