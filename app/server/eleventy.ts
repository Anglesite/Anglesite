/**
 * @file Eleventy server management
 */
import { spawn, ChildProcess } from 'child_process';

let liveServerProcess: ChildProcess | null = null;
let liveServerReady = false;
let currentLiveServerUrl = 'https://localhost:8080';
let currentWebsiteName = 'anglesite';

/**
 * Generate test domain URL for a website
 */
export function generateTestDomain(websiteName: string): string {
  return `https://${websiteName}.test:8080`;
}

/**
 * Get hostname from test domain URL
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
 * Set the current live-server URL
 */
export function setLiveServerUrl(url: string) {
  currentLiveServerUrl = url;
  liveServerReady = true;
}

/**
 * Get current live server URL
 */
export function getCurrentLiveServerUrl(): string {
  return currentLiveServerUrl;
}

/**
 * Check if live server is ready
 */
export function isLiveServerReady(): boolean {
  return liveServerReady;
}

/**
 * Get current website name
 */
export function getCurrentWebsiteName(): string {
  return currentWebsiteName;
}

/**
 * Set current website name
 */
export function setCurrentWebsiteName(name: string) {
  currentWebsiteName = name;
}

/**
 * Start Eleventy server for a specific directory
 */
export function startEleventyServer(
  inputDir: string = 'docs',
  port: number = 8081,
  onReady?: (url: string) => void,
  onError?: (error: string) => void
): void {
  // Stop existing server first
  if (liveServerProcess) {
    stopEleventyServer();
  }

  console.log(`Starting Eleventy server for: ${inputDir}`);

  liveServerProcess = spawn(
    'npx',
    ['eleventy', '--config=app/eleventy/.eleventy.js', `--input="${inputDir}"`, '--serve', `--port=${port}`, '--quiet'],
    {
      cwd: process.cwd(),
      shell: true,
    }
  );

  if (liveServerProcess.stdout) {
    liveServerProcess.stdout.on('data', (data: Buffer) => {
      const output = data.toString();
      console.log(`eleventy: ${output}`);

      // Eleventy outputs something like "[11ty] Server at http://localhost:8081/"
      const urlMatch = output.match(/Server at (https?:\/\/[^\s/]+)/);
      if (urlMatch) {
        const httpUrl = urlMatch[1];
        console.log(`Eleventy HTTP server URL detected: ${httpUrl}`);

        liveServerReady = true;
        if (onReady) {
          onReady(httpUrl);
        }
      }
    });
  }

  if (liveServerProcess.stderr) {
    liveServerProcess.stderr.on('data', (data: Buffer) => {
      const output = data.toString();

      // Check if this is the server ready message in stderr
      const urlMatch = output.match(/Server at (https?:\/\/[^\s/]+)/);
      if (urlMatch) {
        const httpUrl = urlMatch[1];
        console.log(`Eleventy HTTP server URL detected in stderr: ${httpUrl}`);

        liveServerReady = true;
        if (onReady) {
          onReady(httpUrl);
        }
        return; // Don't treat this as an error
      }

      // Only log and handle actual errors
      if (output.toLowerCase().includes('error')) {
        console.error(`eleventy error: ${output}`);
        if (onError) {
          onError(output);
        }
      } else {
        // Log other stderr output as informational
        console.log(`eleventy stderr: ${output.trim()}`);
      }
    });
  }

  liveServerProcess.on('close', (code) => {
    console.log(`eleventy process exited with code ${code}`);
    liveServerReady = false;
  });

  // Fallback timeout
  setTimeout(() => {
    if (!liveServerReady) {
      console.log(`Eleventy server URL (fallback): http://localhost:${port}`);
      liveServerReady = true;
      if (onReady) {
        onReady(`http://localhost:${port}`);
      }
    }
  }, 2000);
}

/**
 * Stop the current Eleventy server
 */
export function stopEleventyServer(): void {
  if (liveServerProcess) {
    console.log('Stopping Eleventy server');
    try {
      liveServerProcess.kill('SIGTERM');
    } catch (error) {
      console.warn('Error stopping Eleventy server:', error);
    }
    liveServerProcess = null;
    liveServerReady = false;
  }
}

/**
 * Switch to serving a different website
 */
export async function switchToWebsite(websitePath: string): Promise<number> {
  console.log('Switching to website at:', websitePath);

  stopEleventyServer();

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
 * Start the default Eleventy server for Anglesite docs with HTTPS proxy support
 * Handles the complete setup flow including DNS resolution and HTTPS proxy
 * @param httpsMode - User's HTTPS preference ("https" or "http")
 * @param mainWindow - Main window for auto-loading preview
 */
export async function startDefaultEleventyServer(
  httpsMode: string,
  mainWindow: Electron.BrowserWindow | null,
  addLocalDnsResolution: (hostname: string) => Promise<void>,
  createHttpsProxy: (httpsPort: number, httpPort: number, hostname: string) => Promise<boolean>,
  autoLoadPreview: (window: Electron.BrowserWindow) => void
): Promise<void> {
  const defaultWebsiteName = 'anglesite';

  startEleventyServer(
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
 * Cleanup live server on app exit
 */
export function cleanupEleventyServer(): void {
  stopEleventyServer();
}
