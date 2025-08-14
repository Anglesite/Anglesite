/**
 * @file Per-website Eleventy server management using programmatic API.
 */
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
// @ts-expect-error - Eleventy may not have perfect TypeScript types
import Eleventy from '@11ty/eleventy';
// @ts-expect-error - Eleventy dev server may not have perfect TypeScript types
import EleventyDevServer from '@11ty/eleventy-dev-server';

/**
 * Send log message to website window.
 */
async function sendLogToWindow(websiteName: string, message: string, level: string = 'info') {
  try {
    // Import dynamically to avoid circular dependencies
    const multiWindowManager = await import('../ui/multi-window-manager');

    // Use the exported function instead of accessing the map directly
    if (typeof multiWindowManager.sendLogToWebsite === 'function') {
      multiWindowManager.sendLogToWebsite(websiteName, message, level);
    } else {
      console.log(`sendLogToWebsite function not available for ${websiteName}`);
    }
  } catch (error) {
    // Silently fail if window is not available
    console.log(`Could not send log to window for ${websiteName}: ${error instanceof Error ? error.message : error}`);
  }
}

/**
 * Server instance for a single website using programmatic API.
 */
export interface WebsiteServer {
  eleventy: Eleventy;
  devServer: EleventyDevServer;
  inputDir: string;
  outputDir: string;
  port: number;
  actualUrl?: string;
}

/**
 * Start an Eleventy server for a specific website using programmatic API.
 */
export async function startWebsiteServer(inputDir: string, websiteName: string, port: number): Promise<WebsiteServer> {
  console.log(`Starting individual Eleventy server for ${websiteName} on port ${port}`);
  console.log(`Input directory: ${inputDir}`);

  sendLogToWindow(websiteName, `🚀 Starting Eleventy server for ${websiteName}`, 'startup');
  sendLogToWindow(websiteName, `📁 Input directory: ${inputDir}`, 'debug');

  try {
    // Set up output directory for this website - use writable directory outside app bundle
    const isPackaged = process.env.NODE_ENV === 'production' || !process.env.NODE_ENV;
    const baseDir = isPackaged
      ? os.tmpdir() // Use system temp directory for packaged apps
      : process.cwd();
    const outputDir = path.join(baseDir, 'anglesite-temp', '_site_temp', websiteName);

    console.log(`Base directory: ${baseDir}`);
    console.log(`Output directory: ${outputDir}`);
    console.log(`Is packaged: ${isPackaged}`);

    sendLogToWindow(websiteName, `📂 Setting up build directory...`, 'info');
    sendLogToWindow(websiteName, `📍 Output: ${outputDir}`, 'debug');

    // Ensure output directory exists
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
      sendLogToWindow(websiteName, `✅ Created output directory`, 'info');
    }

    // Get config path
    const configPath = isPackaged
      ? path.resolve(__dirname, '..', 'eleventy', '.eleventy.js')
      : path.resolve(process.cwd(), 'app/eleventy/.eleventy.js');

    console.log(`Config path: ${configPath}`);
    console.log(`Config file exists: ${fs.existsSync(configPath)}`);

    sendLogToWindow(websiteName, `⚙️ Loading Eleventy configuration...`, 'info');

    // Create Eleventy instance with programmatic API
    const eleventy = new Eleventy(inputDir, outputDir, {
      quietMode: true,
      configPath: configPath,
    });

    // Initial build
    console.log(`[${websiteName}] Building website from ${inputDir} to ${outputDir}`);
    sendLogToWindow(websiteName, `🔨 Building website files...`, 'info');

    await eleventy.write();

    console.log(`[${websiteName}] Initial build completed`);
    sendLogToWindow(websiteName, `✅ Build completed successfully`, 'info');

    // Track the actual server URL
    let actualServerUrl = '';

    // Create dev server instance
    const devServer = new EleventyDevServer(websiteName, outputDir, {
      port: port,
      liveReload: true,
      domDiff: true,
      showVersion: false,
      watch: [inputDir + '/**/*'],
      logger: {
        log: (msg: string) => {
          console.log(`[${websiteName}] ${msg}`);
          // Capture actual server URL from logs
          const serverUrlMatch = msg.match(/Server at (http:\/\/localhost:\d+)\/?/);
          if (serverUrlMatch) {
            actualServerUrl = serverUrlMatch[1]; // Already clean, no trailing slash needed
            console.log(`[${websiteName}] Captured actual server URL: ${actualServerUrl}`);
          }
          sendLogToWindow(websiteName, msg, 'info');
        },
        info: (msg: string) => {
          console.log(`[${websiteName}] ${msg}`);
          // Also check info messages for server URL
          const serverUrlMatch = msg.match(/Server at (http:\/\/localhost:\d+)\/?/);
          if (serverUrlMatch) {
            actualServerUrl = serverUrlMatch[1];
            console.log(`[${websiteName}] Captured actual server URL from info: ${actualServerUrl}`);
          }
          sendLogToWindow(websiteName, msg, 'info');
        },
        error: (msg: string) => {
          console.error(`[${websiteName}] ${msg}`);
          sendLogToWindow(websiteName, msg, 'error');
        },
      },
    });

    // Set up file watching for rebuilds
    devServer.watchFiles([inputDir + '/**/*']);

    // Override the default file change handler to trigger Eleventy rebuilds
    if (devServer.watcher) {
      devServer.watcher.on('change', async (changedPath: string) => {
        console.log(`[${websiteName}] File changed: ${changedPath}`);
        try {
          await eleventy.write();
          console.log(`[${websiteName}] Rebuild completed`);
        } catch (error) {
          console.error(`[${websiteName}] Rebuild failed:`, error);
        }
      });
    }

    // Start the dev server
    console.log(`[${websiteName}] Starting dev server on port ${port}`);
    sendLogToWindow(websiteName, `🌐 Starting development server on port ${port}...`, 'info');

    await devServer.serve();

    // Wait a moment for the server URL to be captured from logs
    await new Promise((resolve) => setTimeout(resolve, 1000));

    // Use captured URL if available, otherwise fall back to expected port
    const finalServerUrl = actualServerUrl || `http://localhost:${port}`;
    const actualPort = actualServerUrl ? parseInt(actualServerUrl.split(':')[2]) : port;

    console.log(`[${websiteName}] Final server URL: ${finalServerUrl}`);
    sendLogToWindow(websiteName, `🎉 Server ready at ${finalServerUrl}`, 'info');
    sendLogToWindow(websiteName, `👀 Watching for file changes...`, 'info');

    return {
      eleventy,
      devServer,
      inputDir,
      outputDir,
      port: actualPort,
      actualUrl: finalServerUrl,
    };
  } catch (error) {
    console.error(`Failed to start server for ${websiteName}:`, error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    sendLogToWindow(websiteName, `❌ Failed to start server: ${errorMessage}`, 'error');
    throw error;
  }
}

/**
 * Stop a website server.
 */
export async function stopWebsiteServer(server: WebsiteServer): Promise<void> {
  try {
    console.log(`Stopping dev server for port ${server.port}`);

    // Stop the file watcher first to prevent fsevents crashes
    if (server.devServer && server.devServer.watcher) {
      try {
        await server.devServer.watcher.close();
        console.log(`File watcher closed for port ${server.port}`);
      } catch (watcherError) {
        console.error(`Error closing file watcher for port ${server.port}:`, watcherError);
      }
    }

    // Stop the dev server
    if (server.devServer && typeof server.devServer.close === 'function') {
      try {
        await server.devServer.close();
        console.log(`Dev server stopped for port ${server.port}`);
      } catch (closeError) {
        console.error(`Error closing dev server for port ${server.port}:`, closeError);
      }
    }

    // Clean up temporary output directory
    if (fs.existsSync(server.outputDir)) {
      try {
        fs.rmSync(server.outputDir, { recursive: true, force: true });
        console.log(`Cleaned up temporary output directory: ${server.outputDir}`);
      } catch (cleanupError) {
        console.error(`Failed to clean up directory ${server.outputDir}:`, cleanupError);
      }
    }
  } catch (error) {
    console.error(`Error stopping server for port ${server.port}:`, error);
  }
}
