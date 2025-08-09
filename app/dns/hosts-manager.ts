/**
 * @file DNS and hosts file management for Anglesite development domains
 *
 * This module handles:
 * - Adding .test domains to /etc/hosts for local DNS resolution
 * - Managing the Anglesite section in the hosts file
 * - Cleaning up orphaned domain entries
 * - Cross-platform hosts file modifications with proper permissions
 */
import * as fs from "fs";
import { exec } from "child_process";
import { dialog } from "electron";
import { listWebsites } from "../utils/website-manager";

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
          type: "info",
          title: "DNS Configuration Complete",
          message: "Development domains configured successfully!",
          detail: `Your site is now available at:

• https://${hostname}:8080
• https://localhost:8080

All future websites will automatically work at:
• https://[website-name].test:8080`,
          buttons: ["OK"],
        });
        return;
      } else {
        dialog.showMessageBox({
          type: "warning",
          title: "Setup Failed",
          message: "Could not enable automatic domain configuration",
          detail: `To access your site at https://${hostname}:8080, please add this line to /etc/hosts:\n\n127.0.0.1\t${hostname}`,
          buttons: ["OK"],
        });
      }
    } else {
      // Anglesite section exists - add domain silently
      console.log(`Adding ${hostname} to existing Anglesite section...`);
      const success = await addToAnglesiteSection(hostname);
      if (success) {
        console.log(
          `✅ DNS resolution for ${hostname} configured automatically`
        );
      } else {
        console.error(`❌ Failed to add ${hostname} to hosts file`);
      }
    }
    return;
  }

  const hostsPath =
    process.platform === "win32"
      ? "C:\\Windows\\System32\\drivers\\etc\\hosts"
      : "/etc/hosts";

  try {
    // Check if wildcard entry already exists
    if (fs.existsSync(hostsPath)) {
      const hostsContent = fs.readFileSync(hostsPath, "utf-8");
      if (hostsContent.includes("*.test")) {
        console.log(`Wildcard DNS resolution for *.test already exists`);
        return;
      }
    }

    // Inform user about DNS setup
    console.log(`\n========================================`);
    console.log(`📌 Development Server Access:`);
    console.log(`========================================`);
    console.log(`✅ Available at: https://localhost:8080`);
    console.log(`✨ Custom domain: https://${hostname}:8080`);
    console.log(
      `\n⚠️  Safari Note: Wildcard certificate should improve compatibility`
    );
    console.log(`
To enable the custom .test domain:`);
    console.log(`1. Enable auto-configuration in Settings`);
    console.log(`2. Or manually add: 127.0.0.1\t*.test to /etc/hosts`);
    console.log(`========================================\n`);
  } catch (error) {
    console.warn("Could not check DNS resolution:", error);
    console.log(`\nAccess your site at: https://localhost:8080`);
    console.log(`Or set up custom domain in Settings`);
  }
}

/**
 * Check if Anglesite section exists in hosts file
 */
async function checkAnglesiteSection(): Promise<boolean> {
  const hostsPath =
    process.platform === "win32"
      ? "C:\\Windows\\System32\\drivers\\etc\\hosts"
      : "/etc/hosts";

  try {
    if (fs.existsSync(hostsPath)) {
      const hostsContent = fs.readFileSync(hostsPath, "utf-8");
      return (
        hostsContent.includes("# Anglesite - Start") &&
        hostsContent.includes("# Anglesite - End")
      );
    }
  } catch (error) {
    console.error("Error checking hosts file:", error);
  }
  return false;
}

/**
 * Execute host modification command with GUI sudo prompt
 */
async function executeHostModification(
  command: string,
  tempFile: string
): Promise<boolean> {
  return new Promise((resolve) => {
    // For macOS, use osascript to show GUI password prompt
    if (process.platform === "darwin") {
      const script = `
        do shell script "${command.replace(
          /"/g,
          '\\"'
        )}" with administrator privileges
      `;

      exec(`osascript -e '${script}'`, (error, stdout, stderr) => {
        // Clean up temp file
        try {
          fs.unlinkSync(tempFile);
        } catch (cleanupError) {
          console.warn("Failed to clean up temp file:", cleanupError);
        }

        if (error) {
          console.error("Host modification failed:", error);
          console.error("stderr:", stderr);
          resolve(false);
        } else {
          console.log("Host modification successful");
          if (stdout) console.log("stdout:", stdout);
          resolve(true);
        }
      });
    } else {
      // Fallback for other platforms
      exec(command, (error, stdout, stderr) => {
        // Clean up temp file
        try {
          fs.unlinkSync(tempFile);
        } catch (cleanupError) {
          console.warn("Failed to clean up temp file:", cleanupError);
        }

        if (error) {
          console.error("Host modification failed:", error);
          console.error("stderr:", stderr);
          resolve(false);
        } else {
          console.log("Host modification successful");
          if (stdout) console.log("stdout:", stdout);
          resolve(true);
        }
      });
    }
  });
}

/**
 * Set up Anglesite wildcard section in hosts file
 */
async function setupAnglesiteWildcardSection(): Promise<boolean> {
  const hostsPath =
    process.platform === "win32"
      ? "C:\\Windows\\System32\\drivers\\etc\\hosts"
      : "/etc/hosts";

  const tempFile =
    process.platform === "win32"
      ? `${process.env.TEMP}\\anglesite-hosts.tmp`
      : `/tmp/anglesite-hosts.tmp`;
  const anglesiteSection = `
# Anglesite - Start (Auto-managed development domains)
127.0.0.1 anglesite.test
# Anglesite - End
`;

  try {
    // Read current hosts file
    const currentContent = fs.existsSync(hostsPath)
      ? fs.readFileSync(hostsPath, "utf-8")
      : "";
    const newContent = currentContent + anglesiteSection;

    // Write to temp file
    fs.writeFileSync(tempFile, newContent);

    // Execute with appropriate command based on platform
    const command =
      process.platform === "win32"
        ? `copy "${tempFile}" "${hostsPath}"`
        : `sudo cp "${tempFile}" "${hostsPath}"`;

    return executeHostModification(command, tempFile);
  } catch (error) {
    console.error("Failed to setup Anglesite section:", error);
    return false;
  }
}

/**
 * Add hostname to existing Anglesite section
 */
async function addToAnglesiteSection(
  hostname: string,
  ipAddress: string = "127.0.0.1"
): Promise<boolean> {
  const hostsPath =
    process.platform === "win32"
      ? "C:\\Windows\\System32\\drivers\\etc\\hosts"
      : "/etc/hosts";

  const tempFile =
    process.platform === "win32"
      ? `${process.env.TEMP}\\anglesite-hosts.tmp`
      : `/tmp/anglesite-hosts.tmp`;

  try {
    const hostsContent = fs.readFileSync(hostsPath, "utf-8");
    const lines = hostsContent.split("\n");

    // Find Anglesite section and add new entry
    let modified = false;
    const newLines = [];

    for (const line of lines) {
      if (line.includes("# Anglesite - Start")) {
        newLines.push(line);
        continue;
      }

      if (line.includes("# Anglesite - End")) {
        // Add new entry before the end marker if not already present
        const entryLine = `${ipAddress} ${hostname}`;
        if (!hostsContent.includes(entryLine)) {
          newLines.push(entryLine);
          modified = true;
          console.log(`Added ${hostname} to Anglesite section`);
        }
        newLines.push(line);
        continue;
      }

      newLines.push(line);
    }

    if (!modified) {
      console.log(`${hostname} already exists in hosts file`);
      return true;
    }

    // Write modified content to temp file
    fs.writeFileSync(tempFile, newLines.join("\n"));

    // Execute with appropriate command
    const command =
      process.platform === "win32"
        ? `copy "${tempFile}" "${hostsPath}"`
        : `sudo cp "${tempFile}" "${hostsPath}"`;

    return executeHostModification(command, tempFile);
  } catch (error) {
    console.error("Failed to add to Anglesite section:", error);
    return false;
  }
}

/**
 * Update hosts file with new entries
 */
export async function updateHostsFile(
  hostname: string,
  ipAddress: string = "127.0.0.1"
): Promise<boolean> {
  return addToAnglesiteSection(hostname, ipAddress);
}

/**
 * Clean up the Anglesite section of /etc/hosts to only include existing website directories
 * Removes orphaned .test domain entries that no longer have corresponding website folders
 * Preserves anglesite.test (main docs) and valid website domains
 * @returns Promise resolving to true if cleanup succeeded or no changes needed, false if failed
 */
export async function cleanupHostsFile(): Promise<boolean> {
  const hostsPath =
    process.platform === "win32"
      ? "C:\\Windows\\System32\\drivers\\etc\\hosts"
      : "/etc/hosts";

  const tempFile =
    process.platform === "win32"
      ? `${process.env.TEMP}\\anglesite-hosts.tmp`
      : `/tmp/anglesite-hosts.tmp`;

  try {
    // Get list of actual website directories
    const existingWebsites = listWebsites();
    console.log("Existing websites:", existingWebsites);

    // Always include anglesite.test for the main docs
    const validDomains = new Set([
      "anglesite.test",
      ...existingWebsites.map((name) => `${name}.test`),
    ]);

    if (!fs.existsSync(hostsPath)) {
      console.log("Hosts file does not exist, nothing to clean up");
      return true;
    }

    const hostsContent = fs.readFileSync(hostsPath, "utf-8");
    const lines = hostsContent.split("\n");

    let inAnglesiteSection = false;
    let modified = false;
    const newLines = [];

    for (const line of lines) {
      if (line.includes("# Anglesite - Start")) {
        inAnglesiteSection = true;
        newLines.push(line);
        continue;
      }

      if (line.includes("# Anglesite - End")) {
        inAnglesiteSection = false;
        newLines.push(line);
        continue;
      }

      if (inAnglesiteSection) {
        // Check if this line contains a .test domain
        const testDomainMatch = line.match(/127\.0\.0\.1\s+(\S+\.test)/);
        if (testDomainMatch) {
          const domain = testDomainMatch[1];
          if (validDomains.has(domain)) {
            // Keep valid domains
            newLines.push(line);
          } else {
            // Remove invalid domains
            console.log(`Removing orphaned domain: ${domain}`);
            modified = true;
          }
        } else if (line.trim() === "") {
          // Keep empty lines for formatting
          newLines.push(line);
        } else if (line.trim().startsWith("#")) {
          // Keep comments
          newLines.push(line);
        } else if (line.trim() !== "") {
          // Non-.test entries in Anglesite section, keep them
          newLines.push(line);
        }
      } else {
        // Outside Anglesite section, keep everything
        newLines.push(line);
      }
    }

    if (!modified) {
      console.log("Hosts file is already clean, no changes needed");
      return true;
    }

    // Write modified content to temp file
    fs.writeFileSync(tempFile, newLines.join("\n"));

    // Execute with appropriate command
    const command =
      process.platform === "win32"
        ? `copy "${tempFile}" "${hostsPath}"`
        : `sudo cp "${tempFile}" "${hostsPath}"`;

    const success = await executeHostModification(command, tempFile);
    if (success) {
      console.log("✅ Hosts file cleaned up successfully");
    } else {
      console.error("❌ Failed to clean up hosts file");
    }
    return success;
  } catch (error) {
    console.error("Failed to clean up hosts file:", error);
    return false;
  }
}
