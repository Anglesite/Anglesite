/**
 * @file Multi-window management for website windows and help window.
 */
import { BrowserWindow, WebContentsView, Menu, MenuItem } from 'electron';
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

// Re-export for use in other modules
export { startWebsiteServer };

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
    } catch (error) {
      console.error(`Could not send log to ${websiteName}:`, error);
    }
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
const websiteServers: Map<string, WebsiteServer> = new Map();

/**
 * Find an available ephemeral port.
 */
export async function findAvailablePort(startPort: number = 8081): Promise<number> {
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

  // Load the website editor template instead of the simple index.html
  const websiteEditorDataUrl = loadTemplateAsDataUrl('website-editor');
  window.loadURL(websiteEditorDataUrl);

  // Add context menu for Anglesite's UI (non-production builds only)
  if (process.env.NODE_ENV !== 'production') {
    window.webContents.on('context-menu', (_event, params) => {
      const contextMenu = new Menu();

      contextMenu.append(
        new MenuItem({
          label: 'Inspect Element…',
          accelerator: 'CmdOrCtrl+Option+I',
          click: () => {
            window.webContents.inspectElement(params.x, params.y);
          },
        })
      );

      contextMenu.popup();
    });
  }

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
      // Website editor layout: left panel (200px) + center panel + right panel (200px)
      const leftPanelWidth = 200;
      const rightPanelWidth = 200;
      const toolbarHeight = 50; // Website editor toolbar: min-height 32px + padding 16px + border
      webContentsView.setBounds({
        x: leftPanelWidth,
        y: toolbarHeight,
        width: bounds.width - leftPanelWidth - rightPanelWidth,
        height: bounds.height - toolbarHeight,
      });
    }
  });

  // Position the preview correctly for website editor layout
  const bounds = window.getBounds();
  // Website editor layout: left panel (200px) + center panel + right panel (200px)
  const leftPanelWidth = 200;
  const rightPanelWidth = 200;
  const toolbarHeight = 50; // Website editor toolbar: min-height 32px + padding 16px + border
  const webContentsViewBounds = {
    x: leftPanelWidth,
    y: toolbarHeight,
    width: bounds.width - leftPanelWidth - rightPanelWidth,
    height: bounds.height - toolbarHeight,
  };
  webContentsView.setBounds(webContentsViewBounds);

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
    websiteServers.delete(websiteName);
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
      websiteServers.delete(websiteName);
    }

    // Find available port
    const port = await findAvailablePort();
    console.log(`Starting server for ${websiteName} on port ${port}`);
    sendLogToWebsite(websiteName, `🔍 Found available port: ${port}`, 'info');

    // Start individual server
    sendLogToWebsite(websiteName, `🚀 Starting Eleventy server...`, 'info');
    const server = await startWebsiteServer(websitePath, websiteName, port);

    // Store server in registry for global access
    websiteServers.set(websiteName, server);

    // Update website window with server info
    websiteWindow.server = server;
    websiteWindow.eleventyPort = port;
    websiteWindow.serverUrl = server.actualUrl || `http://localhost:${server.port}`;

    console.log(`Server ready for ${websiteName} at ${websiteWindow.serverUrl}`);
    sendLogToWebsite(websiteName, `✅ Server startup completed!`, 'info');

    // Send website data to the editor window now that server is ready
    websiteWindow.window.webContents.send('load-website', {
      name: websiteName,
      path: websitePath,
    });

    // Load content in the window with a delay to ensure WebContentsView is ready
    sendLogToWebsite(websiteName, `🌐 Loading website content...`, 'info');
    setTimeout(() => loadWebsiteContent(websiteName), 1000);
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
  console.log(`[DEBUG] loadWebsiteContent called for: ${websiteName}`);
  
  const websiteWindow = websiteWindows.get(websiteName);
  if (!websiteWindow || websiteWindow.window.isDestroyed()) {
    console.error(`Website window not found or destroyed: ${websiteName}`);
    return;
  }

  console.log(`[DEBUG] Website window found for: ${websiteName}`);
  console.log(`[DEBUG] Server URL: ${websiteWindow.serverUrl}`);
  console.log(`[DEBUG] WebContentsView exists: ${!!websiteWindow.webContentsView}`);

  // Don't try to load content if we don't have a server URL
  if (!websiteWindow.serverUrl) {
    console.log(`No server URL available for ${websiteName}, skipping content load`);
    return;
  }

  console.log(`Loading website content for ${websiteName} from: ${websiteWindow.serverUrl}`);
  
  // Simple approach - just load the URL without complex retry logic
  try {
    if (websiteWindow.webContentsView && websiteWindow.webContentsView.webContents && !websiteWindow.webContentsView.webContents.isDestroyed()) {
      console.log(`[DEBUG] Loading URL in WebContentsView: ${websiteWindow.serverUrl}`);
      
      // Add event listeners to see what happens
      websiteWindow.webContentsView.webContents.once('did-finish-load', () => {
        console.log(`[DEBUG] WebContentsView finished loading for: ${websiteName}`);
      });
      
      websiteWindow.webContentsView.webContents.once('did-fail-load', (event, errorCode, errorDescription, validatedURL) => {
        console.error(`[DEBUG] WebContentsView failed to load for: ${websiteName}`, {
          errorCode,
          errorDescription,
          validatedURL
        });
      });
      
      websiteWindow.webContentsView.webContents.loadURL(websiteWindow.serverUrl);
      websiteWindow.window.webContents.send('preview-loaded');
      console.log(`[DEBUG] loadURL called successfully for: ${websiteName}`);
    } else {
      console.error(`[DEBUG] WebContentsView or webContents not available for: ${websiteName}`);
    }
  } catch (error) {
    console.error(`Error loading content for ${websiteName}:`, error);
  }
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
 * Get website server by name.
 */
export function getWebsiteServer(websiteName: string): WebsiteServer | undefined {
  return websiteServers.get(websiteName);
}

/**
 * Get all currently running website servers mapped by website name.
 */
export function getAllWebsiteServers(): Map<string, WebsiteServer> {
  return websiteServers;
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
        }
      }, 1000);
    } catch (error) {
      console.error(`Failed to restore window for ${windowState.websiteName}:`, error);
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

    // Check if website directory exists
    if (!fs.existsSync(websitePath)) {
      console.error(`Website directory does not exist: ${websitePath}`);
      return; // Skip restoration if directory doesn't exist
    }

    // Create the window
    createWebsiteWindow(windowState.websiteName, websitePath);

    try {
      // Start individual server for this restored website
      await startWebsiteServerAndUpdateWindow(windowState.websiteName, websitePath);
    } catch (serverError) {
      console.error(
        `Failed to start server for ${windowState.websiteName}, window will show fallback content:`,
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

/**
 * Toggle DevTools for the currently focused window (help or website window).
 */
export async function togglePreviewDevTools(): Promise<void> {
  const focusedWindow = BrowserWindow.getFocusedWindow();
  if (!focusedWindow) {
    console.log('No focused window found for DevTools');
    return;
  }

  // Check if it's the help window
  if (helpWindow === focusedWindow) {
    // For help window, find its WebContentsView
    const helpViews = helpWindow.contentView.children;
    if (helpViews.length > 0 && 'webContents' in helpViews[0]) {
      const webContents = (helpViews[0] as WebContentsView).webContents;
      if (webContents.isDevToolsOpened()) {
        webContents.closeDevTools();
      } else {
        webContents.openDevTools({ mode: 'detach' });
      }
    }
    return;
  }

  // Check if it's a website window
  for (const [, websiteWindow] of websiteWindows) {
    if (websiteWindow.window === focusedWindow) {
      const webContents = websiteWindow.webContentsView.webContents;
      if (webContents.isDevToolsOpened()) {
        webContents.closeDevTools();
      } else {
        webContents.openDevTools({ mode: 'detach' });
      }
      return;
    }
  }

  console.log('Focused window is not a help or website window');
}

/**
 * Check if a website window is currently focused.
 */
export function isWebsiteEditorFocused(): boolean {
  const focusedWindow = BrowserWindow.getFocusedWindow();
  if (!focusedWindow) return false;

  // Check if the focused window is any website window
  for (const [, websiteWindow] of websiteWindows) {
    if (websiteWindow.window === focusedWindow) {
      return true;
    }
  }
  return false;
}

/**
 * Get the name of the currently focused website project.
 */
export function getCurrentWebsiteEditorProject(): string | null {
  const focusedWindow = BrowserWindow.getFocusedWindow();
  if (!focusedWindow) return null;

  // Find the website name for the focused window
  for (const [websiteName, websiteWindow] of websiteWindows) {
    if (websiteWindow.window === focusedWindow) {
      return websiteName;
    }
  }
  return null;
}

/**
 * Show the WebContentsView for preview mode.
 */
export function showWebsitePreview(websiteName: string): void {
  console.log(`Showing website preview for: ${websiteName}`);
  const websiteWindow = websiteWindows.get(websiteName);
  if (websiteWindow && !websiteWindow.window.isDestroyed()) {
    websiteWindow.webContentsView.setVisible(true);
    console.log(`WebContentsView made visible for: ${websiteName}`);
  } else {
    console.error(`Website window not found for preview show: ${websiteName}`);
  }
}

/**
 * Hide the WebContentsView for edit mode.
 */
export function hideWebsitePreview(websiteName: string): void {
  console.log(`Hiding website preview for: ${websiteName}`);
  const websiteWindow = websiteWindows.get(websiteName);
  if (websiteWindow && !websiteWindow.window.isDestroyed()) {
    websiteWindow.webContentsView.setVisible(false);
    console.log(`WebContentsView hidden for: ${websiteName}`);
  } else {
    console.error(`Website window not found for preview hide: ${websiteName}`);
  }
}
