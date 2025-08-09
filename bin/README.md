# Legacy Scripts

These shell scripts are **legacy utilities** from early development and are no longer needed in current Anglesite versions.

## What these were for:

- `setup-dns.sh` - Manually added .test domains to /etc/hosts
- `setup-mkcert.sh` - Manually set up mkcert certificates
- `fix-hosts.sh` - Fixed malformed hosts file entries
- `fix-hosts-entry.sh` - Another hosts file repair utility

## Current behavior:

All of this functionality is now **automated** in the TypeScript application:

- **Hosts management**: `app/dns/hosts-manager.ts` handles all DNS setup/cleanup
- **Certificate generation**: `app/certificates.ts` creates trusted certificates automatically
- **First launch flow**: Guides users through HTTPS/HTTP choice
- **Cleanup on launch**: Removes orphaned hosts entries automatically

## Should I delete these?

These are kept for reference only. You can safely delete this entire `bin/` directory if you want to clean up the repository.
