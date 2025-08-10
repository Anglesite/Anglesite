/**
 * @file DNS and hosts file management for Anglesite development domains
 *
 * This module handles:
 * - Adding .test domains to /etc/hosts for local DNS resolution
 * - Managing the Anglesite section in the hosts file
 * - Cleaning up orphaned domain entries
 * - Cross-platform hosts file modifications using hostile library
 */
import { dialog } from 'electron';
import { exec } from 'child_process';
import { promisify } from 'util';
import { listWebsites } from '../utils/website-manager';
import * as hostile from 'hostile';

// eslint-disable-next-line @typescript-eslint/no-require-imports
const sudoPrompt = require('sudo-prompt');
// eslint-disable-next-line @typescript-eslint/no-require-imports
const isElevated = require('native-is-elevated');

const execAsync = promisify(exec);

/**
 * Add local DNS resolution for a hostname to point to 127.0.0.1
 * Manages the Anglesite section in /etc/hosts automatically
 * @param hostname - The hostname to add (e.g., "mysite.test")
 */
export async function addLocalDnsResolution(hostname: string): Promise<void> {
  // Check if auto-configuration is enabled
  const autoConfigEnabled = true; // TODO: Get from settings

  if (autoConfigEnabled) {
    // Check if Anglesite section exists
    const anglesiteSectionExists = await checkAnglesiteSection();

    if (!anglesiteSectionExists) {
      // Set up the wildcard section for the first time
      const success = await setupAnglesiteWildcardSection();
      if (success) {
        dialog.showMessageBox({
          type: 'info',
          title: 'DNS Configuration Complete',
          message: 'Development domains configured successfully!',
          detail: `Your site is now available at:

• https://${hostname}:8080
• https://localhost:8080

All future websites will automatically work at:
• https://[website-name].test:8080`,
          buttons: ['OK'],
        });
        return;
      } else {
        dialog.showMessageBox({
          type: 'warning',
          title: 'Setup Failed',
          message: 'Could not enable automatic domain configuration',
          detail: `To access your site at https://${hostname}:8080, please add this line to /etc/hosts:\n\n127.0.0.1\t${hostname}`,
          buttons: ['OK'],
        });
      }
    } else {
      // Anglesite section exists - add domain silently
      console.log(`Adding ${hostname} to existing Anglesite section...`);
      const success = await addToAnglesiteSection(hostname);
      if (success) {
        console.log(`✅ DNS resolution for ${hostname} configured automatically`);
      } else {
        console.error(`❌ Failed to add ${hostname} to hosts file`);
      }
    }
    return;
  }

  try {
    // This section is handled by the auto-configuration above
    // No need to check for wildcard entries with hostile

    // Inform user about DNS setup
    console.log(`\n========================================`);
    console.log(`📌 Development Server Access:`);
    console.log(`========================================`);
    console.log(`✅ Available at: https://localhost:8080`);
    console.log(`✨ Custom domain: https://${hostname}:8080`);
    console.log(`\n⚠️  Safari Note: Wildcard certificate should improve compatibility`);
    console.log(`
To enable the custom .test domain:`);
    console.log(`1. Enable auto-configuration in Settings`);
    console.log(`2. Or manually add: 127.0.0.1\t*.test to /etc/hosts`);
    console.log(`========================================\n`);
  } catch (error) {
    console.warn('Could not check DNS resolution:', error);
    console.log(`\nAccess your site at: https://localhost:8080`);
    console.log(`Or set up custom domain in Settings`);
  }
}

/**
 * Check if anglesite.test domain exists in hosts file
 */
async function checkAnglesiteSection(): Promise<boolean> {
  try {
    return await hostEntryExists('anglesite.test');
  } catch (error) {
    console.error('Error checking hosts file:', error);
    return false;
  }
}

/**
 * Check if Touch ID is available and configured for sudo on macOS
 */
async function isTouchIdAvailable(): Promise<boolean> {
  if (process.platform !== 'darwin') {
    return false;
  }

  try {
    // Check if pam_tid.so is configured in sudo PAM configuration
    const { stdout } = await execAsync('grep -c "pam_tid.so" /etc/pam.d/sudo 2>/dev/null || echo "0"');
    const touchIdConfigured = parseInt(stdout.trim()) > 0;

    // Also check if Touch ID hardware is available
    const { stdout: biometryCheck } = await execAsync('bioutil -r 2>/dev/null | grep -c "Touch ID" || echo "0"');
    const touchIdHardware = parseInt(biometryCheck.trim()) > 0;

    return touchIdConfigured && touchIdHardware;
  } catch (error) {
    console.debug('Could not check Touch ID availability:', error);
    return false;
  }
}

/**
 * Check if Touch ID hardware is available but not configured for sudo
 */
async function canEnableTouchId(): Promise<boolean> {
  if (process.platform !== 'darwin') {
    return false;
  }

  try {
    // Check if Touch ID hardware is available
    const { stdout: biometryCheck } = await execAsync('bioutil -r 2>/dev/null | grep -c "Touch ID" || echo "0"');
    const touchIdHardware = parseInt(biometryCheck.trim()) > 0;

    // Check if pam_tid.so is NOT configured in sudo PAM configuration
    const { stdout } = await execAsync('grep -c "pam_tid.so" /etc/pam.d/sudo 2>/dev/null || echo "0"');
    const touchIdConfigured = parseInt(stdout.trim()) > 0;

    return touchIdHardware && !touchIdConfigured;
  } catch (error) {
    console.debug('Could not check Touch ID configuration possibility:', error);
    return false;
  }
}

/**
 * Show Touch ID setup information to user if available but not configured
 */
export async function checkAndSuggestTouchIdSetup(): Promise<void> {
  if (process.platform !== 'darwin') {
    return;
  }

  const touchIdAvailable = await isTouchIdAvailable();
  const canEnable = await canEnableTouchId();

  if (touchIdAvailable) {
    console.log('🔐 Touch ID is configured for sudo commands - biometric authentication available');
  } else if (canEnable) {
    console.log('💡 Touch ID detected but not configured for sudo.');
    console.log('   To enable Touch ID for administrator access:');
    console.log('   1. Open Terminal');
    console.log('   2. Run: sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local');
    console.log('   3. Edit: sudo nano /etc/pam.d/sudo_local');
    console.log('   4. Uncomment: auth sufficient pam_tid.so');
    console.log('   5. Save and restart Terminal');
    console.log('   This will enable Touch ID for all sudo operations.');
  }
}

/**
 * Execute a command with elevated privileges using sudo-prompt with Touch ID support
 */
async function executeWithElevatedPrivileges(
  command: string,
  args: string[]
): Promise<{ success: boolean; output?: string }> {
  try {
    // Check if we already have elevated privileges
    const alreadyElevated = await isElevated();
    const fullCommand = `${command} ${args.join(' ')}`;

    if (alreadyElevated) {
      // We already have elevated privileges, run directly

      const { stdout } = await execAsync(fullCommand);
      return { success: true, output: stdout };
    } else {
      // Check if Touch ID is available
      const touchIdAvailable = await isTouchIdAvailable();

      // Need to request elevated privileges
      const options = {
        name: 'Anglesite DNS',
        icns: process.platform === 'darwin' ? undefined : undefined, // Can be set to app icon path
      };

      // Log authentication method for debugging
      if (touchIdAvailable) {
        console.log('🔐 Requesting administrator access (Touch ID available)');
      } else {
        console.log('🔑 Requesting administrator access (password required)');
      }

      return new Promise((resolve) => {
        sudoPrompt.exec(fullCommand, options, (error: Error | null, stdout: string) => {
          if (error) {
            // Check for specific Touch ID cancellation or failure
            if (error.message.includes('User cancelled') || (error as Error & { code?: number }).code === -128) {
              console.log('Authentication cancelled by user');
            } else if (touchIdAvailable) {
              console.log('Touch ID authentication failed, may have fallen back to password');
            }
            console.error('Failed to execute with elevated privileges:', error.message);
            resolve({ success: false });
          } else {
            if (touchIdAvailable) {
              console.log('✅ Authentication successful (Touch ID or password)');
            } else {
              console.log('✅ Authentication successful (password)');
            }
            resolve({ success: true, output: stdout });
          }
        });
      });
    }
  } catch (error: unknown) {
    console.error(
      'Failed to execute with elevated privileges:',
      error instanceof Error ? error.message : String(error)
    );
    return { success: false };
  }
}

/**
 * Add a host entry using hostile with native system authentication
 */
async function addHostEntry(hostname: string, ipAddress: string = '127.0.0.1'): Promise<boolean> {
  try {
    const result = await executeWithElevatedPrivileges('npx', ['hostile', 'set', ipAddress, hostname]);

    if (result.success) {
      console.log(`✅ Added ${hostname} to hosts file`);
      return true;
    } else {
      console.error(`Failed to add ${hostname} to hosts file`);
      return false;
    }
  } catch (error) {
    console.error(`Failed to add ${hostname} to hosts file:`, error);
    return false;
  }
}

/**
 * Remove a host entry using hostile with native system authentication
 */
async function removeHostEntry(hostname: string): Promise<boolean> {
  try {
    const result = await executeWithElevatedPrivileges('npx', ['hostile', 'remove', hostname]);

    if (result.success) {
      console.log(`✅ Removed ${hostname} from hosts file`);
      return true;
    } else {
      console.error(`Failed to remove ${hostname} from hosts file`);
      return false;
    }
  } catch (error) {
    console.error(`Failed to remove ${hostname} from hosts file:`, error);
    return false;
  }
}

/**
 * Check if a host entry exists using hostile library
 */
async function hostEntryExists(hostname: string): Promise<boolean> {
  return new Promise((resolve) => {
    hostile.get(false, (err: Error | null, lines: unknown) => {
      if (err) {
        console.error(`Failed to check hosts file for ${hostname}:`, err);
        resolve(false);
        return;
      }

      // hostile.get returns array of [ip, hostname] tuples
      const exists = (lines as Array<[string, string]>).some(([, host]) => {
        return host === hostname;
      });
      resolve(exists);
    });
  });
}

/**
 * Set up initial Anglesite domain using hostile library
 */
async function setupAnglesiteWildcardSection(): Promise<boolean> {
  try {
    // Add the main anglesite.test domain
    const success = await addHostEntry('anglesite.test', '127.0.0.1');
    if (success) {
      console.log('Anglesite domain configured successfully');
    }
    return success;
  } catch (error) {
    console.error('Failed to setup Anglesite domain:', error);
    return false;
  }
}

/**
 * Add hostname to hosts file using hostile library
 */
async function addToAnglesiteSection(hostname: string, ipAddress: string = '127.0.0.1'): Promise<boolean> {
  try {
    // Check if entry already exists
    const exists = await hostEntryExists(hostname);
    if (exists) {
      console.log(`${hostname} already exists in hosts file`);
      return true;
    }

    // Add the host entry
    return await addHostEntry(hostname, ipAddress);
  } catch (error) {
    console.error('Failed to add to hosts file:', error);
    return false;
  }
}

/**
 * Update hosts file with new entries
 */
export async function updateHostsFile(hostname: string, ipAddress: string = '127.0.0.1'): Promise<boolean> {
  return addToAnglesiteSection(hostname, ipAddress);
}

/**
 * Clean up orphaned .test domain entries using hostile library
 * Removes domains that no longer have corresponding website folders
 * @returns Promise resolving to true if cleanup succeeded or no changes needed, false if failed
 */
export async function cleanupHostsFile(): Promise<boolean> {
  try {
    // Get list of actual website directories
    const existingWebsites = listWebsites();
    console.log('Existing websites:', existingWebsites);

    // Always include anglesite.test for the main docs
    const validDomains = new Set(['anglesite.test', ...existingWebsites.map((name) => `${name}.test`)]);

    // Get current hosts file entries
    const hostEntries = await new Promise<Array<[string, string]>>((resolve, reject) => {
      hostile.get(false, (err: Error | null, lines: unknown) => {
        if (err) {
          reject(err);
          return;
        }
        resolve(lines as Array<[string, string]>);
      });
    });

    // Find orphaned .test domains
    const orphanedDomains: string[] = [];
    for (const [ip, line] of hostEntries) {
      const parts = line.split(/\s+/);
      if (parts.length >= 2) {
        const hostname = parts[1];
        if (hostname.endsWith('.test') && ip === '127.0.0.1') {
          if (!validDomains.has(hostname)) {
            orphanedDomains.push(hostname);
          }
        }
      }
    }

    // Remove orphaned domains
    let allSucceeded = true;
    for (const domain of orphanedDomains) {
      console.log(`Removing orphaned domain: ${domain}`);
      const success = await removeHostEntry(domain);
      if (!success) {
        allSucceeded = false;
      }
    }

    if (orphanedDomains.length === 0) {
      console.log('Hosts file is already clean, no changes needed');
    } else {
      console.log(`Cleaned up ${orphanedDomains.length} orphaned domain(s)`);
    }

    return allSucceeded;
  } catch (error) {
    console.error('Failed to clean up hosts file:', error);
    return false;
  }
}
