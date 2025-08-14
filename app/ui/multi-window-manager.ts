/**
 * @file Multi-window management for website windows and help window.
 */
import { BrowserWindow, WebContentsView } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import * as net from 'net';
import {
  getCurrentLiveServerUrl,
  isLiveServerReady,
  setLiveServerUrl,
  setCurrentWebsiteName,
} from '../server/eleventy';
import { startWebsiteServer, stopWebsiteServer, WebsiteServer } from '../server/per-website-server';

/**
 * Send log message to a website window.
 */
export function sendLogToWebsite(websiteName: string, message: string, level: string = 'info') {
  const websiteWindow = websiteWindows.get(websiteName);
  if (websiteWindow && !websiteWindow.window.isDestroyed()) {
    try {
      const logData = {
        type: 'log',
        message,
        level,
        timestamp: new Date().toISOString(),
      };
      websiteWindow.webContentsView.webContents.executeJavaScript(
        `window.postMessage(${JSON.stringify(logData)}, '*');`
      );
      console.log(`DEBUG: Sent log to ${websiteName}: ${message}`);
    } catch (error) {
      console.log(`Could not send log to ${websiteName}:`, error);
    }
  } else {
    console.log(`DEBUG: No window found for ${websiteName} or window destroyed`);
  }
}
import { updateApplicationMenu } from './menu';
import { themeManager } from './theme-manager';
import { Store, WindowState } from '../store';
import { loadTemplateAsDataUrl } from './template-loader';
import { getWebsitePath } from '../utils/website-manager';

/**
 * Interface for tracking a website window.
 */
interface WebsiteWindow {
  window: BrowserWindow;
  webContentsView: WebContentsView;
  websiteName: string;
  websitePath?: string;
  serverUrl?: string; // Store the server URL for this website
  eleventyPort?: number; // HTTP port for Eleventy dev server
  httpsProxyPort?: number; // HTTPS proxy port (if using HTTPS mode)
  server?: WebsiteServer; // Reference to the website's individual server
}

let helpWindow: BrowserWindow | null = null;
const websiteWindows: Map<string, WebsiteWindow> = new Map();

/**
 * Find an available ephemeral port.
 */
async function findAvailablePort(startPort: number = 8081): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(startPort, () => {
      const port = (server.address() as net.AddressInfo)?.port;
      server.close(() => {
        if (port) {
          resolve(port);
        } else {
          reject(new Error('Could not determine port'));
        }
      });
    });

    server.on('error', async (err: Error & { code?: string }) => {
      if (err.code === 'EADDRINUSE') {
        try {
          const nextPort = await findAvailablePort(startPort + 1);
          resolve(nextPort);
        } catch (nextErr) {
          reject(nextErr);
        }
      } else {
        reject(err);
      }
    });
  });
}

/**
 * Create a dedicated help window for displaying documentation
 *
 * Creates a singleton help window that displays the Anglesite documentation
 * using a WebContentsView. The window loads the Eleventy-generated help content
 * and includes error handling with automatic retry logic.
 *
 * If a help window already exists and is not destroyed, it will be focused
 * instead of creating a new one.
 * @returns The help window BrowserWindow instance.
 * @example
 * ```typescript
 * const helpWin = createHelpWindow();
 * console.log(helpWin.getTitle()); // 'Anglesite'
 * ```
 */
export function createHelpWindow(): BrowserWindow {
  if (helpWindow && !helpWindow.isDestroyed()) {
    helpWindow.focus();
    return helpWindow;
  }

  helpWindow = new BrowserWindow({
    width: 1000,
    height: 700,
    title: 'Anglesite',
    show: false, // Don't show until ready
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '..', 'preload.js'),
    },
    titleBarStyle: 'default',
    // Enable native macOS window tabbing (same identifier allows tabbing with website windows)
    tabbingIdentifier: 'anglesite-website',
  });

  // Prevent HTML title from overriding window title
  helpWindow.on('page-title-updated', (event) => {
    event.preventDefault();
  });

  helpWindow.loadFile(path.join(__dirname, '..', 'index.html'));

  // Create preview WebContentsView for help content
  const helpWebContentsView = new WebContentsView({
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Add error handling
  helpWebContentsView.webContents.on('render-process-gone', (_event, details) => {
    console.error('Help WebContentsView render process gone:', details);
    setTimeout(() => {
      try {
        helpWebContentsView?.webContents.reload();
      } catch (error) {
        console.error('Failed to reload help WebContentsView:', error);
      }
    }, 1000);
  });

  helpWebContentsView.webContents.on('unresponsive', () => {
    console.error('Help WebContentsView webContents unresponsive');
  });

  helpWebContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    console.error('Help WebContentsView failed to load:', {
      errorCode,
      errorDescription,
      validatedURL,
    });
  });

  // Load help content when server is ready
  const loadHelpContent = () => {
    if (!isLiveServerReady()) {
      // Show loading message and retry
      const loadingHTML = `
        <!DOCTYPE html>
        <html>
          <head><title>Anglesite Help</title></head>
          <body style="font-family: system-ui; padding: 20px; text-align: center;">
            <h1>📚 Anglesite Help</h1>
            <p>Help content is loading...</p>
            <p><small>The documentation server is starting up</small></p>
          </body>
        </html>
      `;
      helpWebContentsView.webContents.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(loadingHTML)}`);

      // Retry after 500ms
      setTimeout(loadHelpContent, 500);
      return;
    }

    const serverUrl = getCurrentLiveServerUrl();
    console.log('Loading help content from:', serverUrl);

    helpWebContentsView.webContents.loadURL(serverUrl).catch((error) => {
      console.error('Failed to load help content:', error);

      // Show fallback HTML
      const fallbackHTML = `
        <!DOCTYPE html>
        <html>
          <head><title>Anglesite Help</title></head>
          <body style="font-family: system-ui; padding: 20px; text-align: center;">
            <h1>📚 Anglesite Help</h1>
            <p>Help content is loading...</p>
            <p><small>The documentation server is starting up</small></p>
          </body>
        </html>
      `;
      helpWebContentsView.webContents.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(fallbackHTML)}`);
    });
  };

  // Start loading help content
  setTimeout(loadHelpContent, 100);

  // Add WebContentsView to help window
  helpWindow.contentView.addChildView(helpWebContentsView);

  // Handle window resize
  helpWindow.on('resize', () => {
    if (helpWebContentsView) {
      const bounds = helpWindow!.getBounds();
      helpWebContentsView.setBounds({
        x: 0,
        y: 50, // Height of title bar + menu
        width: bounds.width,
        height: bounds.height - 50,
      });
    }
  });

  // Position the preview correctly
  const bounds = helpWindow.getBounds();
  helpWebContentsView.setBounds({
    x: 0,
    y: 50,
    width: bounds.width,
    height: bounds.height - 50,
  });

  // Update menu when focus changes
  helpWindow.on('focus', () => {
    updateApplicationMenu();
  });

  helpWindow.on('blur', () => {
    updateApplicationMenu();
  });

  // Clean up reference when window is closed
  helpWindow.on('closed', () => {
    helpWindow = null;
    updateApplicationMenu();
  });

  console.log('Help window created and ready');
  updateApplicationMenu();

  // Use ready-to-show event as recommended by Electron docs
  helpWindow.once('ready-to-show', () => {
    if (helpWindow && !helpWindow.isDestroyed()) {
      themeManager.applyThemeToWindow(helpWindow);
      helpWindow.show();
    }
  });

  return helpWindow;
}

/**
 * Create a new dedicated website window for editing and preview
 *
 * Creates a singleton window for the specified website with its own WebContentsView
 * for live preview. Each website gets its own isolated window to enable concurrent
 * editing of multiple websites.
 *
 * If a window already exists for the website and is not destroyed, it will be
 * focused instead of creating a new one.
 * @param websiteName Unique name of the website.
 * @param websitePath Optional file system path to the website directory.
 * @returns The website window BrowserWindow instance.
 * @example
 * ```typescript
 * const websiteWin = createWebsiteWindow('my-blog', '/path/to/my-blog');
 * console.log(websiteWin.getTitle()); // 'my-blog'
 * ```
 */
export function createWebsiteWindow(websiteName: string, websitePath?: string): BrowserWindow {
  // Check if window already exists for this website
  const existingWindow = websiteWindows.get(websiteName);
  if (existingWindow && !existingWindow.window.isDestroyed()) {
    existingWindow.window.focus();
    return existingWindow.window;
  }

  const window = new BrowserWindow({
    width: 1200,
    height: 800,
    title: websiteName,
    show: false, // Don't show until ready
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '..', 'preload.js'),
    },
    titleBarStyle: 'default',
    // Enable native macOS window tabbing
    tabbingIdentifier: 'anglesite-website',
  });

  // Prevent HTML title from overriding window title
  window.on('page-title-updated', (event) => {
    event.preventDefault();
  });

  window.loadFile(path.join(__dirname, '..', 'index.html'));

  // Create preview WebContentsView for website content
  const webContentsView = new WebContentsView({
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Add error handling
  webContentsView.webContents.on('render-process-gone', (_event, details) => {
    console.error('Website WebContentsView render process gone:', details);
    setTimeout(() => {
      try {
        webContentsView?.webContents.reload();
      } catch (error) {
        console.error('Failed to reload website WebContentsView:', error);
      }
    }, 1000);
  });

  webContentsView.webContents.on('unresponsive', () => {
    console.error('Website WebContentsView webContents unresponsive');
  });

  webContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    console.error('Website WebContentsView failed to load:', {
      errorCode,
      errorDescription,
      validatedURL,
    });
  });

  // Add WebContentsView to window
  window.contentView.addChildView(webContentsView);

  // Handle window resize
  window.on('resize', () => {
    if (webContentsView) {
      const bounds = window.getBounds();
      webContentsView.setBounds({
        x: 0,
        y: 90, // Account for menu bar and button toolbar
        width: bounds.width,
        height: bounds.height - 90,
      });
    }
  });

  // Position the preview correctly
  const bounds = window.getBounds();
  webContentsView.setBounds({
    x: 0,
    y: 90, // Account for menu bar and button toolbar
    width: bounds.width,
    height: bounds.height - 90,
  });

  // Store website window
  const websiteWindow: WebsiteWindow = {
    window,
    webContentsView,
    websiteName,
    websitePath,
  };
  websiteWindows.set(websiteName, websiteWindow);

  // Close start screen when first website window is created
  closeStartScreen();

  // Update menu and server URL when focus changes
  window.on('focus', () => {
    // Update the global server URL to match this window's website
    if (websiteWindow.serverUrl) {
      setLiveServerUrl(websiteWindow.serverUrl);
      setCurrentWebsiteName(websiteName);
    }
    updateApplicationMenu();
  });

  window.on('blur', () => {
    updateApplicationMenu();
  });

  // Clean up when window is closed
  window.on('closed', async () => {
    // Stop the individual server for this website
    const websiteWindow = websiteWindows.get(websiteName);
    if (websiteWindow?.server) {
      try {
        await stopWebsiteServer(websiteWindow.server);
      } catch (error) {
        console.error(`Error stopping server for ${websiteName}:`, error);
      }
    }
    websiteWindows.delete(websiteName);
    updateApplicationMenu();

    // Show start screen if this was the last website window
    if (websiteWindows.size === 0) {
      showStartScreenIfNeeded();
    }
  });

  console.log(`Website window created for: ${websiteName}`);
  updateApplicationMenu();

  // Use ready-to-show event as recommended by Electron docs
  window.once('ready-to-show', () => {
    if (window && !window.isDestroyed()) {
      themeManager.applyThemeToWindow(window);
      window.show();
    }
  });

  return window;
}

/**
 * Start individual server for a website and update its window.
 */
export async function startWebsiteServerAndUpdateWindow(websiteName: string, websitePath: string): Promise<void> {
  const websiteWindow = websiteWindows.get(websiteName);
  if (!websiteWindow || websiteWindow.window.isDestroyed()) {
    console.error(`Website window not found for server startup: ${websiteName}`);
    return;
  }

  try {
    sendLogToWebsite(websiteName, `🔄 Preparing to start server for ${websiteName}...`, 'startup');

    // Stop existing server if any
    if (websiteWindow.server) {
      sendLogToWebsite(websiteName, `🛑 Stopping existing server...`, 'info');
      await stopWebsiteServer(websiteWindow.server);
    }

    // Find available port
    const port = await findAvailablePort();
    console.log(`Starting server for ${websiteName} on port ${port}`);
    sendLogToWebsite(websiteName, `🔍 Found available port: ${port}`, 'info');

    // Start individual server
    sendLogToWebsite(websiteName, `🚀 Starting Eleventy server...`, 'info');
    const server = await startWebsiteServer(websitePath, websiteName, port);

    // Update website window with server info
    websiteWindow.server = server;
    websiteWindow.eleventyPort = port;
    websiteWindow.serverUrl = `http://localhost:${port}`;

    console.log(`Server ready for ${websiteName} at ${websiteWindow.serverUrl}`);
    sendLogToWebsite(websiteName, `✅ Server startup completed!`, 'info');

    // Load content in the window
    sendLogToWebsite(websiteName, `🌐 Loading website content...`, 'info');
    loadWebsiteContent(websiteName);
  } catch (error) {
    console.error(`Failed to start server for ${websiteName}:`, error);
    // Show fallback content
    const fallbackDataUrl = loadTemplateAsDataUrl('preview-fallback');
    websiteWindow.webContentsView.webContents.loadURL(fallbackDataUrl);
  }
}

/**
 * Load website content in its window.
 */
export function loadWebsiteContent(websiteName: string, retryCount: number = 0): void {
  const websiteWindow = websiteWindows.get(websiteName);
  if (!websiteWindow || websiteWindow.window.isDestroyed()) {
    console.error(`Website window not found: ${websiteName}`);
    return;
  }

  if (!isLiveServerReady()) {
    console.log('Live server not ready yet, retrying in 500ms...');
    setTimeout(() => loadWebsiteContent(websiteName, retryCount), 500);
    return;
  }

  // For dist builds, try to load website index.md as simple HTML
  const websitePath = websiteWindow.websitePath;
  if (websitePath) {
    const indexMdPath = path.join(websitePath, 'index.md');
    if (fs.existsSync(indexMdPath)) {
      console.log(`Found website markdown file: ${indexMdPath}`);
      try {
        const mdContent = fs.readFileSync(indexMdPath, 'utf8');

        // Extract title from frontmatter
        const titleMatch = mdContent.match(/title:\s*(.+)/);
        const title = titleMatch ? titleMatch[1].replace(/['"]/g, '') : websiteName;

        // Create simple HTML page
        const simpleHtml = `<!DOCTYPE html>
<html>
<head>
  <title>${title}</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { font-family: system-ui; max-width: 800px; margin: 0 auto; padding: 20px; line-height: 1.6; }
    h1 { color: #333; border-bottom: 2px solid #eee; padding-bottom: 10px; }
    h2 { color: #555; margin-top: 30px; }
    ul { margin: 15px 0; }
    li { margin: 5px 0; }
    .website-info { background: #f5f5f5; padding: 15px; border-radius: 5px; margin: 20px 0; }
  </style>
</head>
<body>
  <h1>${title}</h1>
  <div class="website-info">
    <p><strong>📁 Website:</strong> ${websiteName}</p>
    <p><strong>📍 Location:</strong> ${websitePath}</p>
    <p><strong>⚡ Status:</strong> Loaded directly from files</p>
  </div>
  <h2>Getting Started</h2>
  <ul>
    <li>Edit the index.md file to change this content</li>
    <li>Add more pages by creating new .md files</li>
    <li>Customize the layout in the _includes directory</li>
    <li>Add styles to style.css</li>
  </ul>
  <p>🚀 Happy building with Anglesite!</p>
</body>
</html>`;

        const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(simpleHtml)}`;
        websiteWindow.webContentsView.webContents.loadURL(dataUrl);
        websiteWindow.window.webContents.send('preview-loaded');
        console.log(`Loaded simple HTML version for ${websiteName}`);
        return;
      } catch (error) {
        console.error(`Failed to create simple HTML for ${websiteName}:`, error);
      }
    }
  }

  // Use individual server if available
  if (websiteWindow.serverUrl) {
    const serverUrl = websiteWindow.serverUrl;
    console.log(`Loading website content for ${websiteName} from individual server:`, serverUrl);
  } else {
    console.log(`No individual server available for ${websiteName}, showing fallback content`);

    try {
      // Show fallback content
      const fallbackDataUrl = loadTemplateAsDataUrl('preview-fallback');
      websiteWindow.webContentsView.webContents.loadURL(fallbackDataUrl);
      websiteWindow.window.webContents.send('preview-loaded');
      return;
    } catch (error) {
      console.error(`Failed to load fallback content for ${websiteName}:`, error);
      return;
    }
  }

  const serverUrl = websiteWindow.serverUrl;

  websiteWindow.webContentsView.webContents.removeAllListeners('did-fail-load');
  websiteWindow.webContentsView.webContents.removeAllListeners('did-finish-load');
  websiteWindow.webContentsView.webContents.removeAllListeners('did-fail-provisional-load');

  // Track if we successfully loaded
  let loadSuccess = false;

  websiteWindow.webContentsView.webContents.on('did-fail-provisional-load', () => {
    // Provisional load failures often happen when the server isn't quite ready
    if (retryCount < 3 && !loadSuccess) {
      console.log(`Provisional load failed for ${websiteName}, retrying (attempt ${retryCount + 1}/3)...`);
      setTimeout(() => loadWebsiteContent(websiteName, retryCount + 1), 1000);
    }
  });

  websiteWindow.webContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    console.error(`Failed to load content for ${websiteName}:`, {
      errorCode,
      errorDescription,
      validatedURL,
    });

    // Retry if we haven't exceeded retry count
    if (retryCount < 3 && !loadSuccess) {
      console.log(`Retrying load for ${websiteName} (attempt ${retryCount + 1}/3)...`);
      setTimeout(() => loadWebsiteContent(websiteName, retryCount + 1), 1000);
    } else if (!loadSuccess) {
      // Show fallback after all retries failed
      const fallbackDataUrl = loadTemplateAsDataUrl('preview-fallback');
      websiteWindow.webContentsView.webContents.loadURL(fallbackDataUrl);
    }
  });

  websiteWindow.webContentsView.webContents.on('did-finish-load', () => {
    loadSuccess = true;
    console.log(`Successfully loaded content for ${websiteName}`);
  });

  // Load the website content
  websiteWindow.webContentsView.webContents.loadURL(serverUrl).catch((error) => {
    console.error(`Failed to load content for ${websiteName}:`, error);

    // Retry if we haven't exceeded retry count
    if (retryCount < 3) {
      console.log(`Retrying after error for ${websiteName} (attempt ${retryCount + 1}/3)...`);
      setTimeout(() => loadWebsiteContent(websiteName, retryCount + 1), 1000);
    } else {
      // Show fallback after all retries failed
      const fallbackDataUrl = loadTemplateAsDataUrl('preview-fallback');
      websiteWindow.webContentsView.webContents.loadURL(fallbackDataUrl);
    }
  });

  // Send message to renderer
  websiteWindow.window.webContents.send('preview-loaded');
}

/**
 * Get help window reference.
 */
export function getHelpWindow(): BrowserWindow | null {
  return helpWindow && !helpWindow.isDestroyed() ? helpWindow : null;
}

/**
 * Get website window reference.
 */
export function getWebsiteWindow(websiteName: string): BrowserWindow | null {
  const websiteWindow = websiteWindows.get(websiteName);
  return websiteWindow && !websiteWindow.window.isDestroyed() ? websiteWindow.window : null;
}

/**
 * Returns the complete map of all currently open website windows keyed by website name.
 */
export function getAllWebsiteWindows(): Map<string, WebsiteWindow> {
  return websiteWindows;
}

/**
 * Save current window states to persistent storage.
 */
export function saveWindowStates(): void {
  const store = new Store();
  const windowStates: WindowState[] = [];

  // Note: Help window state is no longer persisted since we don't auto-show it on startup

  // Save website window states
  websiteWindows.forEach((websiteWindow, websiteName) => {
    if (!websiteWindow.window.isDestroyed()) {
      const bounds = websiteWindow.window.getBounds();
      const isMaximized = websiteWindow.window.isMaximized();

      const windowState: WindowState = {
        websiteName,
        websitePath: websiteWindow.websitePath,
        bounds,
        isMaximized,
      };

      windowStates.push(windowState);
    }
  });

  store.saveWindowStates(windowStates);
}

/**
 * Restore website windows from saved states.
 */
export async function restoreWindowStates(): Promise<void> {
  const store = new Store();
  const windowStates = store.getWindowStates();

  if (windowStates.length === 0) {
    // Show start screen when no websites are being restored
    showStartScreenIfNeeded();
    return;
  }

  for (const windowState of windowStates) {
    try {
      // Restore the website window
      await restoreWebsiteWindow(windowState);

      // Restore window bounds and maximized state after a delay to ensure the window is ready
      setTimeout(() => {
        const websiteWindow = websiteWindows.get(windowState.websiteName);
        if (websiteWindow && !websiteWindow.window.isDestroyed() && windowState.bounds) {
          if (windowState.isMaximized) {
            websiteWindow.window.maximize();
          } else {
            websiteWindow.window.setBounds(windowState.bounds);
          }
          console.log(`DEBUG: Restored bounds for ${windowState.websiteName}`);
        }
      }, 1000);
    } catch (error) {
      console.error(`DEBUG: Failed to restore window for ${windowState.websiteName}:`, error);
    }
  }
}

/**
 * Restore a single website window.
 */
async function restoreWebsiteWindow(windowState: WindowState): Promise<void> {
  try {
    // Get the website path
    const websitePath = windowState.websitePath || getWebsitePath(windowState.websiteName);
    console.log(`DEBUG: Attempting to restore ${windowState.websiteName} from path: ${websitePath}`);

    // Check if website directory exists
    if (!fs.existsSync(websitePath)) {
      console.error(`DEBUG: Website directory does not exist: ${websitePath}`);
      return; // Skip restoration if directory doesn't exist
    }

    // Create the window
    createWebsiteWindow(windowState.websiteName, websitePath);
    console.log(`DEBUG: Created window for ${windowState.websiteName}`);

    try {
      // Start individual server for this restored website
      await startWebsiteServerAndUpdateWindow(windowState.websiteName, websitePath);
      console.log(`DEBUG: Restored website window with individual server: ${windowState.websiteName}`);
    } catch (serverError) {
      console.error(
        `DEBUG: Failed to start server for ${windowState.websiteName}, window will show fallback content:`,
        serverError
      );
      // Don't throw - let the window exist with fallback content rather than failing completely
    }
  } catch (error) {
    console.error(`Failed to restore website window for ${windowState.websiteName}:`, error);
    throw error;
  }
}

/**
 * Gracefully closes all open windows (help and website windows) and saves their states.
 */
export async function closeAllWindows(): Promise<void> {
  // Save window states before closing
  saveWindowStates();

  // Stop all servers first before closing windows to prevent fsevents crashes
  const stopPromises: Promise<void>[] = [];
  websiteWindows.forEach((websiteWindow) => {
    if (websiteWindow.server) {
      stopPromises.push(
        stopWebsiteServer(websiteWindow.server).catch((error) => {
          console.error(`Error stopping server during shutdown:`, error);
        })
      );
    }
  });

  // Wait for all servers to stop
  await Promise.all(stopPromises);

  if (helpWindow && !helpWindow.isDestroyed()) {
    helpWindow.close();
  }

  websiteWindows.forEach((websiteWindow) => {
    if (!websiteWindow.window.isDestroyed()) {
      websiteWindow.window.close();
    }
  });

  websiteWindows.clear();
}

/**
 * Start screen window instance
 */
let startScreenWindow: BrowserWindow | null = null;

/**
 * Create and show the start screen window.
 */
export function createStartScreen(): BrowserWindow {
  if (startScreenWindow && !startScreenWindow.isDestroyed()) {
    startScreenWindow.focus();
    return startScreenWindow;
  }

  console.log('Creating start screen...');

  startScreenWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    title: 'Anglesite',
    show: false,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 20, y: 20 },
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '..', 'preload.js'),
    },
  });

  // Load the start screen template
  const startScreenDataUrl = loadTemplateAsDataUrl('start-screen');
  startScreenWindow.loadURL(startScreenDataUrl);

  startScreenWindow.once('ready-to-show', () => {
    if (startScreenWindow && !startScreenWindow.isDestroyed()) {
      themeManager.applyThemeToWindow(startScreenWindow);
      startScreenWindow.show();
      startScreenWindow.focus();
    }
  });

  startScreenWindow.on('closed', () => {
    startScreenWindow = null;
  });

  console.log('Start screen created');
  return startScreenWindow;
}

/**
 * Close the start screen window if it exists.
 */
export function closeStartScreen(): void {
  if (startScreenWindow && !startScreenWindow.isDestroyed()) {
    startScreenWindow.close();
  }
  startScreenWindow = null;
}

/**
 * Get the current start screen window.
 */
export function getStartScreen(): BrowserWindow | null {
  return startScreenWindow && !startScreenWindow.isDestroyed() ? startScreenWindow : null;
}

/**
 * Show the start screen if no windows are open and it's appropriate to do so.
 */
export function showStartScreenIfNeeded(): void {
  // Only show start screen if no website windows are open and no start screen is already showing
  if (websiteWindows.size === 0 && !getStartScreen() && !helpWindow) {
    createStartScreen();
  }
}
