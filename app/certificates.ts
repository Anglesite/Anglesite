/**
 * @file Certificate Authority and SSL certificate management for Anglesite
 *
 * This module handles:
 * - Creating and managing a local Certificate Authority (CA)
 * - Generating SSL certificates for .test domains
 * - Installing CA certificates in the system keychain
 * - Checking certificate installation status
 */
import { createCA, createCert } from "mkcert";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { execSync } from "child_process";

/**
 * Certificate cache to avoid regenerating certificates for the same domains
 */
const certificateCache = new Map<string, { cert: string; key: string }>();

/**
 * Get or create Certificate Authority for Anglesite
 * Creates a new CA if one doesn't exist, otherwise loads existing CA from disk
 * @returns Promise resolving to CA certificate and private key
 */
async function getOrCreateCA(): Promise<{ cert: string; key: string }> {
  const appDataPath =
    process.platform === "darwin"
      ? path.join(os.homedir(), "Library", "Application Support", "Anglesite")
      : process.platform === "win32"
      ? path.join(process.env.APPDATA || "", "Anglesite")
      : path.join(os.homedir(), ".config", "anglesite");

  const caPath = path.join(appDataPath, "ca");
  const caCertPath = path.join(caPath, "ca.crt");
  const caKeyPath = path.join(caPath, "ca.key");

  // Check if CA already exists
  if (fs.existsSync(caCertPath) && fs.existsSync(caKeyPath)) {
    return {
      cert: fs.readFileSync(caCertPath, "utf8"),
      key: fs.readFileSync(caKeyPath, "utf8"),
    };
  }

  // Create new CA
  console.log("Creating new Certificate Authority...");
  const ca = await createCA({
    organization: "Anglesite Development",
    countryCode: "US",
    state: "Development",
    locality: "Local",
    validity: 825, // ~2.25 years
  });

  // Save CA to disk
  fs.mkdirSync(caPath, { recursive: true });
  fs.writeFileSync(caCertPath, ca.cert);
  fs.writeFileSync(caKeyPath, ca.key);

  console.log("✅ Certificate Authority created and saved");
  return ca;
}

/**
 * Generate SSL certificate for specific domains using the Anglesite CA
 * Includes caching to avoid regenerating certificates for the same domain set
 * @param domains - Array of domain names to include in the certificate
 * @returns Promise resolving to certificate and private key
 */
export async function generateCertificate(
  domains: string[]
): Promise<{ cert: string; key: string }> {
  // Check cache first
  const cacheKey = domains.sort().join(",");
  if (certificateCache.has(cacheKey)) {
    console.log(`✅ Using cached certificate for ${domains.join(", ")}`);
    return certificateCache.get(cacheKey)!;
  }

  try {
    // Get or create CA
    const ca = await getOrCreateCA();

    // Always include localhost and common variations
    const allDomains = Array.from(
      new Set([...domains, "localhost", "127.0.0.1", "::1"])
    );

    // Create certificate
    console.log(`Generating certificate for: ${allDomains.join(", ")}`);
    const cert = await createCert({
      ca: { key: ca.key, cert: ca.cert },
      domains: allDomains,
      validity: 365,
    });

    // Cache the certificate
    certificateCache.set(cacheKey, cert);

    console.log("✅ Certificate generated successfully");
    return cert;
  } catch (error) {
    console.error("Failed to generate certificate:", error);
    throw new Error(
      `Certificate generation failed: ${
        error instanceof Error ? error.message : String(error)
      }`
    );
  }
}

/**
 * Check if Anglesite CA is installed and trusted in the system keychain
 * Verifies both the existence and trustworthiness of the CA certificate
 * @returns True if CA is properly installed and trusted, false otherwise
 */
export function isCAInstalledInSystem(): boolean {
  try {
    // Check if the CA certificate is in any keychain and is trusted
    execSync(
      'security verify-cert -c "/Users/$(whoami)/Library/Application Support/Anglesite/ca/ca.crt" 2>/dev/null || security find-certificate -c "Anglesite Development"',
      { stdio: "pipe" }
    );
    return true;
  } catch {
    // Certificate not found or not trusted
    return false;
  }
}

/**
 * Install Anglesite CA into user keychain as a trusted root certificate
 * This enables SSL certificates signed by the Anglesite CA to be trusted by browsers
 * Installs in user keychain to avoid requiring administrator privileges
 * @returns Promise resolving to true if installation succeeded, false if failed
 */
export async function installCAInSystem(): Promise<boolean> {
  try {
    const ca = await getOrCreateCA();

    // Write CA cert to temporary file
    const tempCertPath = path.join(os.tmpdir(), "anglesite-ca.crt");
    fs.writeFileSync(tempCertPath, ca.cert);

    // Install certificate in user keychain (no admin privileges required)
    execSync(`security add-trusted-cert -d -r trustRoot "${tempCertPath}"`, {
      stdio: "pipe",
    });

    // Clean up temporary file
    fs.unlinkSync(tempCertPath);

    console.log("✅ Anglesite CA installed in user keychain");
    return true;
  } catch (error) {
    console.error("Failed to install CA in keychain:", error);
    return false;
  }
}

/**
 * Get the file system path to the Anglesite CA certificate
 * Useful for manual installation or external certificate management
 * @returns Absolute path to the ca.crt file
 */
export function getCAPath(): string {
  const appDataPath =
    process.platform === "darwin"
      ? path.join(os.homedir(), "Library", "Application Support", "Anglesite")
      : process.platform === "win32"
      ? path.join(process.env.APPDATA || "", "Anglesite")
      : path.join(os.homedir(), ".config", "anglesite");

  return path.join(appDataPath, "ca", "ca.crt");
}

/**
 * Load or generate SSL certificates for HTTPS server with specific domains
 * Main entry point for getting certificates for the HTTPS proxy server
 * @param domains - Array of domain names, defaults to ["anglesite.test"]
 * @returns Promise resolving to certificate and private key for HTTPS server
 */
export async function loadCertificates(
  domains: string[] = ["anglesite.test"]
): Promise<{
  cert: string;
  key: string;
}> {
  // Generate certificate for specific domains only
  return generateCertificate(domains);
}
