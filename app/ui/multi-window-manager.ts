/**
 * @file Multi-window management for website windows and help window.
 */
import { BrowserWindow, WebContentsView } from 'electron';
import * as path from 'path';
import { getCurrentLiveServerUrl, isLiveServerReady } from '../server/eleventy';
import { updateApplicationMenu } from './menu';
import { themeManager } from './theme-manager';
import { Store, WindowState } from '../store';
import { loadTemplateAsDataUrl } from './template-loader';

/**
 * Interface for tracking a website window.
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

  // Use the current server URL which should be set correctly by the IPC handler
  const serverUrl = getCurrentLiveServerUrl();
  console.log(`Loading website content for ${websiteName} from:`, serverUrl);

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
  console.log('DEBUG: Saving window states...');
  const store = new Store();
  const windowStates: WindowState[] = [];

  // Save help window state
  if (helpWindow && !helpWindow.isDestroyed()) {
    store.set('showHelpOnStartup', true);
    console.log('DEBUG: Help window will be restored');
  } else {
    store.set('showHelpOnStartup', false);
  }

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
      console.log(`DEBUG: Saved state for website window: ${websiteName}`);
    }
  });

  store.saveWindowStates(windowStates);
  console.log(`DEBUG: Saved ${windowStates.length} website window states`);
}

/**
 * Restore website windows from saved states.
 */
export async function restoreWindowStates(): Promise<void> {
  console.log('DEBUG: Restoring window states...');
  const store = new Store();
  const windowStates = store.getWindowStates();

  if (windowStates.length === 0) {
    console.log('DEBUG: No saved window states found');
    return;
  }

  console.log(`DEBUG: Found ${windowStates.length} saved window states`);

  for (const windowState of windowStates) {
    try {
      console.log(`DEBUG: Restoring website window: ${windowState.websiteName}`);

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
  // Functions are already available in this module
  const { switchToWebsite, setLiveServerUrl, setCurrentWebsiteName } = await import('../server/eleventy');
  const { addLocalDnsResolution } = await import('../dns/hosts-manager');
  const { restartHttpsProxy } = await import('../server/https-proxy');
  const { getWebsitePath } = await import('../utils/website-manager');

  try {
    // Get the website path
    const websitePath = windowState.websitePath || getWebsitePath(windowState.websiteName);

    // Create the window
    createWebsiteWindow(windowState.websiteName, websitePath);

    // Switch to the website and get the actual port
    const actualPort = await switchToWebsite(websitePath);
    console.log(
      'DEBUG: switchToWebsite completed for restored window:',
      windowState.websiteName,
      'on port:',
      actualPort
    );

    // Generate test domain and setup DNS
    const testDomain = `https://${windowState.websiteName}.test:8080`;
    const hostname = `${windowState.websiteName}.test`;

    await addLocalDnsResolution(hostname);

    // Check user's HTTPS preference
    const store = new Store();
    const httpsMode = store.get('httpsMode');

    if (httpsMode === 'https') {
      // Restart HTTPS proxy for the domain using the actual port
      const httpsSuccess = await restartHttpsProxy(8080, actualPort, hostname);
      if (httpsSuccess) {
        console.log(`Restored website HTTPS server ready at: ${testDomain}`);
        setLiveServerUrl(testDomain);
        setCurrentWebsiteName(windowState.websiteName);
      } else {
        console.log('HTTPS proxy failed for restored window, continuing with HTTP-only mode');
        setLiveServerUrl(`http://localhost:${actualPort}`);
        setCurrentWebsiteName(windowState.websiteName);
      }
    } else {
      console.log('HTTP-only mode by user preference, skipping HTTPS proxy for restored window');
      setLiveServerUrl(`http://localhost:${actualPort}`);
      setCurrentWebsiteName(windowState.websiteName);
    }

    // Load the website content with a delay to ensure everything is ready
    setTimeout(() => {
      loadWebsiteContent(windowState.websiteName);
      console.log(`DEBUG: loadWebsiteContent called for restored window: ${windowState.websiteName}`);
    }, 1500);
  } catch (error) {
    console.error(`Failed to restore website window for ${windowState.websiteName}:`, error);
    throw error;
  }
}

/**
 * Gracefully closes all open windows (help and website windows) and saves their states.
 */
export function closeAllWindows(): void {
  // Save window states before closing
  saveWindowStates();

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
