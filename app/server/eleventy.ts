/**
 * @file Eleventy server management.
 */
import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
// @ts-expect-error - Eleventy may not have perfect TypeScript types
import Eleventy from '@11ty/eleventy';
// @ts-expect-error - Eleventy dev server may not have perfect TypeScript types
import EleventyDevServer from '@11ty/eleventy-dev-server';

let liveServerProcess: ChildProcess | null = null;
let devServer: any = null;
let eleventy: any = null;
let liveServerReady = false;
let currentLiveServerUrl = 'https://localhost:8080';
let currentWebsiteName = 'anglesite';
let outputDir = '';

/**
 * Generate test domain URL for a website using .test TLD
 *
 * Creates a local development URL using the .test top-level domain which
 * is reserved for testing purposes and won't conflict with real domains.
 * The URL uses HTTPS on port 8080 which is proxied to the Eleventy server.
 * @param websiteName Name of the website (will be used as subdomain).
 * @returns Test domain URL (e.g., "https://my-site.test:8080").
 * @example
 * ```typescript
 * const url = generateTestDomain('my-blog');
 * console.log(url); // "https://my-blog.test:8080"
 * ```
 */
export function generateTestDomain(websiteName: string): string {
  return `https://${websiteName}.test:8080`;
}

/**
 * Get hostname from test domain URL.
 */
export function getHostnameFromTestDomain(testDomainUrl: string): string {
  try {
    const url = new URL(testDomainUrl);
    return url.hostname;
  } catch (error) {
    console.error('Failed to parse test domain URL:', error);
    return 'localhost';
  }
}

/**
 * Set the current live-server URL.
 */
export function setLiveServerUrl(url: string) {
  currentLiveServerUrl = url;
  liveServerReady = true;
}

/**
 * Returns the URL of the currently running Eleventy server.
 */
export function getCurrentLiveServerUrl(): string {
  return currentLiveServerUrl;
}

/**
 * Checks whether the Eleventy server has finished starting up and is ready to serve content.
 */
export function isLiveServerReady(): boolean {
  return liveServerReady;
}

/**
 * Returns the name of the website currently being served by Eleventy.
 */
export function getCurrentWebsiteName(): string {
  return currentWebsiteName;
}

/**
 * Updates the name of the website currently being served.
 */
export function setCurrentWebsiteName(name: string) {
  currentWebsiteName = name;
}

/**
 * Start Eleventy server using the official @11ty/eleventy-dev-server with programmatic API.
 */
export async function startEleventyServer(
  inputDir: string = 'docs',
  port: number = 8081,
  onReady?: (url: string) => void,
  onError?: (error: string) => void
): Promise<void> {
  // Stop existing server first
  await stopEleventyServer();

  console.log(`Starting Eleventy server for: ${inputDir}`);

  try {
    // Set up output directory
    outputDir = path.join(process.cwd(), '_site_temp', path.basename(inputDir));

    // Ensure output directory exists
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    // Configure Eleventy programmatically
    // In packaged apps, config file is relative to __dirname, in dev it's relative to cwd
    const isPackaged = process.env.NODE_ENV === 'production' || !process.env.NODE_ENV;
    const configPath = isPackaged 
      ? path.resolve(__dirname, '..', 'eleventy', '.eleventy.js')  // __dirname is in dist/app/server/, so go up one level
      : path.resolve(process.cwd(), 'app/eleventy/.eleventy.js');
    
    eleventy = new Eleventy(inputDir, outputDir, {
      quietMode: true,
      configPath: configPath,
    });

    // Initial build
    console.log(`Building website from ${inputDir} to ${outputDir}`);
    await eleventy.write();
    console.log('Initial build completed');

    // Create dev server instance
    devServer = new EleventyDevServer('anglesite', outputDir, {
      port: port,
      liveReload: true,
      domDiff: true,
      showVersion: false,
      watch: [inputDir + '/**/*'],
      logger: {
        log: console.log,
        info: console.log,
        error: console.error,
      },
    });

    // Set up file watching for rebuilds
    devServer.watchFiles([inputDir + '/**/*']);

    // Override the default file change handler to trigger Eleventy rebuilds
    if (devServer.watcher) {
      // Remove default listeners and add our own
      devServer.watcher.removeAllListeners('change');
      devServer.watcher.removeAllListeners('add');
      devServer.watcher.removeAllListeners('unlink');

      devServer.watcher.on('change', async (filePath: string) => {
        console.log(`File changed: ${filePath}, rebuilding...`);
        try {
          await eleventy.write();
          console.log('Rebuild completed');
          // Notify dev server of changes for live reload
          devServer.reloadFiles([filePath]);
        } catch (error) {
          console.error('Rebuild failed:', error);
          if (onError) {
            onError(error instanceof Error ? error.message : String(error));
          }
        }
      });

      devServer.watcher.on('add', async (filePath: string) => {
        console.log(`File added: ${filePath}, rebuilding...`);
        try {
          await eleventy.write();
          console.log('Rebuild completed');
          devServer.reloadFiles([filePath]);
        } catch (error) {
          console.error('Rebuild failed:', error);
          if (onError) {
            onError(error instanceof Error ? error.message : String(error));
          }
        }
      });

      devServer.watcher.on('unlink', async (filePath: string) => {
        console.log(`File removed: ${filePath}, rebuilding...`);
        try {
          await eleventy.write();
          console.log('Rebuild completed');
          devServer.reloadFiles([filePath]);
        } catch (error) {
          console.error('Rebuild failed:', error);
          if (onError) {
            onError(error instanceof Error ? error.message : String(error));
          }
        }
      });
    }

    // Start the dev server
    devServer.serve(port);

    // Wait for server to be ready and call onReady
    await devServer.ready();

    const httpUrl = `http://localhost:${port}`;
    console.log(`Eleventy dev server ready at: ${httpUrl}`);

    liveServerReady = true;
    if (onReady) {
      onReady(httpUrl);
    }
  } catch (error) {
    console.error('Failed to start Eleventy dev server:', error);
    if (onError) {
      onError(error instanceof Error ? error.message : String(error));
    }
  }
}

/**
 * Stop the current Eleventy server.
 */
export async function stopEleventyServer(): Promise<void> {
  console.log('Stopping Eleventy server');

  // Stop dev server
  if (devServer) {
    try {
      await devServer.close();
      console.log('Dev server stopped');
    } catch (error) {
      console.warn('Error stopping dev server:', error);
    }
    devServer = null;
  }

  // Stop legacy CLI process if it exists
  if (liveServerProcess) {
    try {
      liveServerProcess.kill('SIGTERM');
    } catch (error) {
      console.warn('Error stopping legacy Eleventy process:', error);
    }
    liveServerProcess = null;
  }

  // Clean up Eleventy instance
  eleventy = null;
  liveServerReady = false;

  // Clean up temporary output directory
  if (outputDir && fs.existsSync(outputDir)) {
    try {
      fs.rmSync(outputDir, { recursive: true, force: true });
      console.log('Cleaned up temporary output directory');
    } catch (error) {
      console.warn('Error cleaning up output directory:', error);
    }
  }
}

/**
 * Switch the Eleventy server to serve a different website.
 *
 * Stops the current Eleventy server process and starts a new one configured
 * for the specified website directory. The server will scan for an available
 * port starting from 8081 and update the internal state with the new URL.
 *
 * This function handles the complete server transition including process cleanup,
 * port detection, and readiness monitoring.
 * @param websitePath Absolute path to the website directory to serve.
 * @returns Promise resolving to the port number the server is running on.
 * @throws Error if the server fails to start or websitePath is invalid.
 * @example
 * ```typescript
 * const port = await switchToWebsite('/path/to/my-website');
 * console.log(`Server running on port ${port}`);
 * ```
 */
export async function switchToWebsite(websitePath: string): Promise<number> {
  console.log('Switching to website at:', websitePath);

  await stopEleventyServer();

  return new Promise((resolve, reject) => {
    startEleventyServer(
      websitePath,
      8081,
      (httpUrl) => {
        console.log(`New website HTTP server ready at: ${httpUrl}`);
        // Extract the actual port from the URL
        const actualPort = parseInt(new URL(httpUrl).port || '8081');
        resolve(actualPort);
      },
      (error) => {
        console.error('Failed to start server for new website:', error);
        reject(new Error(error));
      }
    );
  });
}

/**
 * Start the default Eleventy server for Anglesite docs with HTTPS proxy support.
 * Handles the complete setup flow including DNS resolution and HTTPS proxy.
 * @param httpsMode User's HTTPS preference ("https" or "http").
 * @param mainWindow Main window for auto-loading preview.
 */
export async function startDefaultEleventyServer(
  httpsMode: string,
  mainWindow: Electron.BrowserWindow | null,
  addLocalDnsResolution: (hostname: string) => Promise<void>,
  createHttpsProxy: (httpsPort: number, httpPort: number, hostname: string) => Promise<boolean>,
  autoLoadPreview: (window: Electron.BrowserWindow) => void
): Promise<void> {
  const defaultWebsiteName = 'anglesite';

  await startEleventyServer(
    'docs', // Input directory
    8081, // Port
    async (httpUrl: string) => {
      console.log(`Eleventy HTTP server URL detected: ${httpUrl}`);

      // Generate proper .test domain
      const testDomain = generateTestDomain(defaultWebsiteName);
      const hostname = getHostnameFromTestDomain(testDomain);

      // Set up DNS resolution
      await addLocalDnsResolution(hostname);

      if (httpsMode === 'https') {
        // Start HTTPS proxy server
        console.log('Starting HTTPS proxy server...');
        console.log(`DEBUG: HTTP URL: ${httpUrl}`);
        console.log(`DEBUG: Test domain: ${testDomain}`);
        console.log(`DEBUG: Hostname: ${hostname}`);

        const httpPort = new URL(httpUrl).port || '8081';
        console.log(`DEBUG: Extracted HTTP port: ${httpPort}`);

        const httpsSuccess = await createHttpsProxy(8080, parseInt(httpPort), hostname);

        if (httpsSuccess) {
          // Set the HTTPS URL as the current server URL
          setLiveServerUrl(testDomain);
          setCurrentWebsiteName(defaultWebsiteName);
          console.log('✅ Eleventy server is ready with HTTPS proxy');

          // Auto-load the preview once server is ready
          if (mainWindow) {
            autoLoadPreview(mainWindow);
          }
        } else {
          // HTTPS proxy failed, fall back to HTTP
          setLiveServerUrl(httpUrl);
          setCurrentWebsiteName(defaultWebsiteName);
          console.log('⚠️  HTTPS proxy failed, falling back to HTTP mode');

          if (mainWindow) {
            autoLoadPreview(mainWindow);
          }
        }
      } else {
        // User chose HTTP mode, skip HTTPS proxy
        setLiveServerUrl(httpUrl);
        setCurrentWebsiteName(defaultWebsiteName);
        console.log('✅ Eleventy server is ready (HTTP-only mode by user preference)');

        if (mainWindow) {
          autoLoadPreview(mainWindow);
        }
      }
    },
    (error: string) => {
      console.error('Eleventy server error:', error);
    }
  );
}

/**
 * Cleanup live server on app exit.
 */
export async function cleanupEleventyServer(): Promise<void> {
  await stopEleventyServer();
}
