/**
 * @file Multi-window management for website windows and help window
 */
import { BrowserWindow, WebContentsView } from 'electron';
import * as path from 'path';
import { getCurrentLiveServerUrl, isLiveServerReady } from '../server/eleventy';
import { updateApplicationMenu } from './menu';
import { themeManager } from './theme-manager';

/**
 * Interface for tracking a website window
 */
interface WebsiteWindow {
  window: BrowserWindow;
  webContentsView: WebContentsView;
  websiteName: string;
  websitePath?: string;
}

let helpWindow: BrowserWindow | null = null;
const websiteWindows: Map<string, WebsiteWindow> = new Map();

/**
 * Create a dedicated help window for /docs
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
 * Create a new website window
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
        y: 50,
        width: bounds.width,
        height: bounds.height - 50,
      });
    }
  });

  // Position the preview correctly
  const bounds = window.getBounds();
  webContentsView.setBounds({
    x: 0,
    y: 50,
    width: bounds.width,
    height: bounds.height - 50,
  });

  // Store website window
  const websiteWindow: WebsiteWindow = {
    window,
    webContentsView,
    websiteName,
    websitePath,
  };
  websiteWindows.set(websiteName, websiteWindow);

  // Update menu when focus changes
  window.on('focus', () => {
    updateApplicationMenu();
  });

  window.on('blur', () => {
    updateApplicationMenu();
  });

  // Clean up when window is closed
  window.on('closed', () => {
    websiteWindows.delete(websiteName);
    updateApplicationMenu();
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
 * Load website content in its window
 */
export function loadWebsiteContent(websiteName: string): void {
  const websiteWindow = websiteWindows.get(websiteName);
  if (!websiteWindow || websiteWindow.window.isDestroyed()) {
    console.error(`Website window not found: ${websiteName}`);
    return;
  }

  if (!isLiveServerReady()) {
    console.log('Live server not ready yet, waiting...');
    return;
  }

  // Try website-specific URL first, fallback to main server if DNS fails
  const websiteUrl = `https://${websiteName}.test:8080`;
  const fallbackUrl = getCurrentLiveServerUrl();

  console.log(`Loading website content for ${websiteName} from:`, websiteUrl);

  websiteWindow.webContentsView.webContents.removeAllListeners('did-fail-load');
  websiteWindow.webContentsView.webContents.removeAllListeners('did-finish-load');

  websiteWindow.webContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    // Only handle actual website loading failures, not data URLs
    if (!validatedURL.startsWith('data:text/html')) {
      console.log(`DNS resolution failed for ${websiteName}.test, trying fallback URL`);

      // Try fallback URL if website-specific URL fails
      if (validatedURL === websiteUrl) {
        websiteWindow.webContentsView.webContents.loadURL(fallbackUrl).catch((fallbackError) => {
          console.error(`Both website and fallback URLs failed for ${websiteName}:`, fallbackError);
        });
      }
    }
  });

  websiteWindow.webContentsView.webContents.on('did-finish-load', () => {
    console.log(`Successfully loaded content for ${websiteName}`);
  });

  // Load the website content with a small delay to ensure HTTPS proxy is ready
  setTimeout(() => {
    websiteWindow.webContentsView.webContents.loadURL(websiteUrl).catch((error) => {
      console.error(`Failed to load content for ${websiteName}:`, error);
      // Auto-fallback to main server URL if website-specific URL fails
      console.log(`Trying fallback URL for ${websiteName}: ${fallbackUrl}`);
      websiteWindow.webContentsView.webContents.loadURL(fallbackUrl).catch((fallbackError) => {
        console.error(`Both website and fallback URLs failed for ${websiteName}:`, fallbackError);
      });
    });
  }, 500);

  // Send message to renderer
  websiteWindow.window.webContents.send('preview-loaded');
}

/**
 * Get help window reference
 */
export function getHelpWindow(): BrowserWindow | null {
  return helpWindow && !helpWindow.isDestroyed() ? helpWindow : null;
}

/**
 * Get website window reference
 */
export function getWebsiteWindow(websiteName: string): BrowserWindow | null {
  const websiteWindow = websiteWindows.get(websiteName);
  return websiteWindow && !websiteWindow.window.isDestroyed() ? websiteWindow.window : null;
}

/**
 * Get all website windows
 */
export function getAllWebsiteWindows(): Map<string, WebsiteWindow> {
  return websiteWindows;
}

/**
 * Close all windows
 */
export function closeAllWindows(): void {
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
