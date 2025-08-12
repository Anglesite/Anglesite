/**
 * @file Window and WebContentsView management.
 */
import { BrowserWindow, WebContentsView, ipcMain, WebContents } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import { getCurrentLiveServerUrl, isLiveServerReady } from '../server/eleventy';
import { themeManager } from './theme-manager';
import { loadTemplateAsDataUrl } from './template-loader';

let previewWebContentsView: WebContentsView | null = null;
let settingsWindow: BrowserWindow | null = null;

/**
 * Create the main application window.
 */
export function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '..', 'preload.js'),
    },
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 20, y: 20 },
  });

  win.loadFile(path.join(__dirname, '..', 'index.html'));

  // Create preview WebContentsView
  createPreviewWebContentsView();

  // Handle window resize to reposition WebContentsView
  win.on('resize', () => {
    if (previewWebContentsView) {
      const bounds = win.getBounds();
      previewWebContentsView.setBounds({
        x: 0,
        y: 90, // Height of both menu bars
        width: bounds.width,
        height: bounds.height - 90,
      });
    }
  });

  return win;
}

/**
 * Create preview WebContentsView for displaying live content.
 */
function createPreviewWebContentsView(): void {
  previewWebContentsView = new WebContentsView({
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Add error handling
  previewWebContentsView.webContents.on('render-process-gone', (_event, details) => {
    console.error('WebContentsView render process gone:', details);
    setTimeout(() => {
      try {
        previewWebContentsView?.webContents.reload();
      } catch (error) {
        console.error('Failed to reload WebContentsView:', error);
      }
    }, 1000);
  });

  previewWebContentsView.webContents.on('unresponsive', () => {
    console.error('WebContentsView webContents unresponsive');
  });

  previewWebContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    console.error('WebContentsView failed to load:', {
      errorCode,
      errorDescription,
      validatedURL,
    });
  });

  console.log('WebContentsView created and ready to display content');
}

/**
 * Auto-load preview when server is ready.
 */
export function autoLoadPreview(win: BrowserWindow): void {
  if (win && previewWebContentsView && isLiveServerReady()) {
    const currentUrl = getCurrentLiveServerUrl();
    console.log('Auto-loading preview with URL:', currentUrl);

    // Remove existing listeners to avoid duplicates
    previewWebContentsView.webContents.removeAllListeners('did-fail-load');
    previewWebContentsView.webContents.removeAllListeners('did-finish-load');

    previewWebContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
      console.error('Auto-load failed for URL:', validatedURL, 'Error:', errorCode, errorDescription);
      // Fallback to file:// protocol if HTTP fails
      loadLocalFilePreview(win);
    });

    previewWebContentsView.webContents.on('did-finish-load', () => {
      console.log('Auto-loaded preview successfully:', currentUrl);
    });

    // Load the current live server URL
    setTimeout(() => {
      const serverUrl = getCurrentLiveServerUrl();
      console.log('Auto-loading URL now:', serverUrl);

      previewWebContentsView?.webContents.loadURL(serverUrl).catch((error) => {
        console.error('Failed to load server URL:', error);

        // Show fallback HTML
        const fallbackDataUrl = loadTemplateAsDataUrl('preview-fallback');
        previewWebContentsView?.webContents.loadURL(fallbackDataUrl);
      });
    }, 100);

    // Add WebContentsView to window if not already added
    if (!win.contentView.children.includes(previewWebContentsView)) {
      win.contentView.addChildView(previewWebContentsView);
      console.log('WebContentsView added to window');
    }

    // Position the preview correctly
    const bounds = win.getBounds();
    previewWebContentsView.setBounds({
      x: 0,
      y: 90, // Height of both menu bars
      width: bounds.width,
      height: bounds.height - 90,
    });

    // Send message to renderer
    win.webContents.send('preview-loaded');
    console.log('Auto-preview loaded successfully');
  }
}

/**
 * Load local file preview as fallback.
 */
export function loadLocalFilePreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    const distPath = path.resolve(process.cwd(), 'dist');
    const indexFile = path.join(distPath, 'index.html');
    const fileUrl = `file://${indexFile}`;

    console.log('Loading local file preview:', fileUrl);

    try {
      if (fs.existsSync(indexFile)) {
        previewWebContentsView.webContents.loadFile(indexFile);
      } else {
        console.error('Index file not found:', indexFile);
      }
    } catch (error) {
      console.error('Error loading local file preview:', error);
    }
  }
}

/**
 * Show preview in WebContentsView.
 */
export function showPreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    console.log('Showing WebContentsView and loading URL');

    // Add WebContentsView to window if not already added
    if (!win.contentView.children.includes(previewWebContentsView)) {
      win.contentView.addChildView(previewWebContentsView);
    }

    // Remove existing listeners
    previewWebContentsView.webContents.removeAllListeners('did-fail-load');
    previewWebContentsView.webContents.removeAllListeners('did-finish-load');

    previewWebContentsView.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
      console.error('Failed to load URL:', validatedURL, 'Error:', errorCode, errorDescription);
    });

    previewWebContentsView.webContents.on('did-finish-load', () => {
      const serverUrl = getCurrentLiveServerUrl();
      console.log('WebContentsView successfully loaded:', serverUrl);
    });

    // Load current server URL directly
    const serverUrl = getCurrentLiveServerUrl();
    setTimeout(() => {
      console.log('MAIN PROCESS: Actually loading URL now:', serverUrl);
      previewWebContentsView?.webContents.loadURL(serverUrl);
    }, 100);

    // Position correctly
    const bounds = win.getBounds();
    previewWebContentsView.setBounds({
      x: 0,
      y: 90,
      width: bounds.width,
      height: bounds.height - 90,
    });

    win.webContents.send('preview-loaded');
  }
}

/**
 * Hide preview WebContentsView.
 */
export function hidePreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    win.contentView.removeChildView(previewWebContentsView);
  }
}

/**
 * Reload preview content.
 */
export function reloadPreview(): void {
  if (previewWebContentsView) {
    previewWebContentsView.webContents.reload();
  }
}

/**
 * Toggle DevTools for the currently focused window.
 */
export async function togglePreviewDevTools(): Promise<void> {
  const focusedWindow = BrowserWindow.getFocusedWindow();
  if (!focusedWindow) {
    console.log('No focused window found for DevTools');
    return;
  }

  // Import here to avoid circular dependency
  const { getAllWebsiteWindows, getHelpWindow } = await import('./multi-window-manager');

  // Check if it's the help window
  const helpWindow = getHelpWindow();
  if (helpWindow === focusedWindow) {
    // For help window, find its WebContentsView
    const helpViews = helpWindow.contentView.children;
    if (helpViews.length > 0 && 'webContents' in helpViews[0]) {
      const webContents = (helpViews[0] as { webContents: WebContents }).webContents;
      if (webContents.isDevToolsOpened()) {
        webContents.closeDevTools();
      } else {
        webContents.openDevTools();
      }
    }
    return;
  }

  // Check if it's a website window
  const websiteWindows = getAllWebsiteWindows();
  for (const [, websiteWindow] of websiteWindows) {
    if (websiteWindow.window === focusedWindow) {
      const webContents = websiteWindow.webContentsView.webContents;
      if (webContents.isDevToolsOpened()) {
        webContents.closeDevTools();
      } else {
        webContents.openDevTools();
      }
      return;
    }
  }

  console.log('Focused window is not a recognized Anglesite window');
}

/**
 * BagIt metadata collection result.
 */
export interface BagItMetadata {
  externalIdentifier: string;
  externalDescription: string;
  sourceOrganization: string;
  organizationAddress: string;
  contactName: string;
  contactPhone: string;
  contactEmail: string;
}

/**
 * Show BagIt metadata collection dialog for archival export
 *
 * Creates a modal dialog that collects Dublin Core metadata required for BagIt
 * archival format. The dialog pre-fills the external identifier with the website
 * name and allows the user to enter additional preservation metadata.
 * @param websiteName Name of the website being exported (used as default identifier).
 * @returns Promise resolving to collected metadata object or null if cancelled.
 * @example
 * ```typescript
 * const metadata = await getBagItMetadata('my-website');
 * if (metadata) {
 *   // Use metadata for BagIt export
 *   console.log(metadata.externalIdentifier); // 'my-website'
 * }
 * ```
 */
export async function getBagItMetadata(websiteName: string): Promise<BagItMetadata | null> {
  return new Promise((resolve) => {
    const metadataWindow = new BrowserWindow({
      width: 500,
      height: 650,
      title: 'BagIt Archive Metadata',
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      modal: true,
      show: false,
      webPreferences: {
        nodeIntegration: true,
        contextIsolation: false,
      },
    });

    const metadataDataUrl = loadTemplateAsDataUrl('bagit-metadata');
    metadataWindow.loadURL(metadataDataUrl);

    metadataWindow.once('ready-to-show', () => {
      if (metadataWindow && !metadataWindow.isDestroyed()) {
        themeManager.applyThemeToWindow(metadataWindow);
        metadataWindow.show();

        // Send default values to the dialog
        metadataWindow.webContents.send('bagit-metadata-defaults', {
          externalIdentifier: websiteName,
          externalDescription: '',
          sourceOrganization: '',
          organizationAddress: '',
          contactName: '',
          contactPhone: '',
          contactEmail: '',
        });
      }
    });

    const handleMetadataResult = (result: BagItMetadata | null) => {
      if (!metadataWindow.isDestroyed()) {
        metadataWindow.close();
      }
      resolve(result);
    };

    metadataWindow.on('closed', () => {
      resolve(null);
    });

    // Set up IPC listeners
    const handleDefaults = () => {
      if (!metadataWindow.isDestroyed()) {
        metadataWindow.webContents.send('bagit-metadata-defaults', {
          externalIdentifier: websiteName,
          externalDescription: '',
          sourceOrganization: '',
          organizationAddress: '',
          contactName: '',
          contactPhone: '',
          contactEmail: '',
        });
      }
    };

    const handleResult = (_event: unknown, result: BagItMetadata | null) => {
      ipcMain.removeListener('get-bagit-metadata-defaults', handleDefaults);
      ipcMain.removeListener('bagit-metadata-result', handleResult);
      handleMetadataResult(result);
    };

    ipcMain.on('get-bagit-metadata-defaults', handleDefaults);
    ipcMain.on('bagit-metadata-result', handleResult);
  });
}

/**
 * Get native input from user.
 */
export async function getNativeInput(title: string, prompt: string): Promise<string | null> {
  return new Promise((resolve) => {
    // Create a simple input dialog window with nodeIntegration enabled for this specific use case
    const inputWindow = new BrowserWindow({
      width: 400,
      height: 200,
      title,
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      modal: true,
      show: false, // Don't show immediately to prevent white flash
      webPreferences: {
        nodeIntegration: true,
        contextIsolation: false,
      },
    });

    const inputDataUrl = loadTemplateAsDataUrl('input-dialog', {
      title,
      prompt,
    });

    inputWindow.loadURL(inputDataUrl);

    // Use ready-to-show event following Electron best practices
    inputWindow.once('ready-to-show', () => {
      if (inputWindow && !inputWindow.isDestroyed()) {
        // Apply current theme to the input window before showing
        themeManager.applyThemeToWindow(inputWindow);
        inputWindow.show();
      }
    });

    // Handle input result
    const handleInputResult = (result: string | null) => {
      inputWindow.close();
      resolve(result);
    };

    // Handle window close
    inputWindow.on('closed', () => {
      resolve(null);
    });

    // Set up IPC listener for the result
    const handleResult = (_event: unknown, result: string | null) => {
      ipcMain.removeListener('input-dialog-result', handleResult);
      handleInputResult(result);
    };
    ipcMain.on('input-dialog-result', handleResult);
  });
}

/**
 * Show first launch setup assistant for HTTPS/HTTP mode selection
 * Displays a modal dialog allowing users to choose between HTTPS (with CA installation)
 * or HTTP (simple) mode for local development.
 * @returns Promise resolving to "https", "http", or null if cancelled.
 */
export async function showFirstLaunchAssistant(): Promise<'https' | 'http' | null> {
  return new Promise((resolve) => {
    const assistantWindow = new BrowserWindow({
      width: 520,
      height: 480,
      title: 'Welcome to Anglesite',
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      modal: true,
      show: false, // Don't show immediately to prevent white flash
      titleBarStyle: 'hiddenInset',
      webPreferences: {
        nodeIntegration: true,
        contextIsolation: false,
      },
    });

    // Load the HTML file
    const htmlFilePath = path.join(__dirname, '..', 'ui', 'first-launch.html');
    console.log('Loading first launch HTML from:', htmlFilePath);

    // Check if file exists
    if (fs.existsSync(htmlFilePath)) {
      assistantWindow.loadFile(htmlFilePath);
    } else {
      console.error('First launch HTML file not found at:', htmlFilePath);
      // Fall back to a simple HTML
      const welcomeDataUrl = loadTemplateAsDataUrl('welcome-assistant');
      assistantWindow.loadURL(welcomeDataUrl);
    }

    // Use ready-to-show event following Electron best practices
    assistantWindow.once('ready-to-show', () => {
      if (assistantWindow && !assistantWindow.isDestroyed()) {
        // Apply current theme to the first launch assistant before showing
        themeManager.applyThemeToWindow(assistantWindow);
        assistantWindow.show();
      }
    });

    // Handle window close
    assistantWindow.on('closed', () => {
      resolve(null);
    });

    // Set up IPC listener for the result
    const handleResult = (_event: unknown, result: 'https' | 'http' | null) => {
      ipcMain.removeListener('first-launch-result', handleResult);
      assistantWindow.close();
      resolve(result);
    };
    ipcMain.on('first-launch-result', handleResult);
  });
}

/**
 * Creates and displays a modal window for selecting and opening existing websites.
 */
export function openWebsiteSelectionWindow(): void {
  const websiteSelectionWindow = new BrowserWindow({
    width: 600,
    height: 500,
    title: 'Open Website',
    resizable: true,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false, // Don't show immediately to prevent white flash
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  const htmlFilePath = path.join(__dirname, '..', 'ui', 'website-selection.html');

  // Check if file exists, create fallback if not
  if (fs.existsSync(htmlFilePath)) {
    websiteSelectionWindow.loadFile(htmlFilePath);
  } else {
    const websiteSelectionDataUrl = loadTemplateAsDataUrl('website-selection');

    websiteSelectionWindow.loadURL(websiteSelectionDataUrl);

    // Use ready-to-show event following Electron best practices
    websiteSelectionWindow.once('ready-to-show', () => {
      if (websiteSelectionWindow && !websiteSelectionWindow.isDestroyed()) {
        // Apply current theme to the website selection window before showing
        themeManager.applyThemeToWindow(websiteSelectionWindow);
        websiteSelectionWindow.show();
      }
    });
  }
}

/**
 * Creates and displays the application settings window, or focuses it if already open.
 */
export function openSettingsWindow(): void {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 500,
    height: 300,
    title: 'Settings',
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false, // Don't show immediately to prevent white flash
    titleBarStyle: 'default',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, '..', 'preload.js'),
    },
  });

  const settingsDataUrl = loadTemplateAsDataUrl('settings');

  settingsWindow.loadURL(settingsDataUrl);

  // Use ready-to-show event following Electron best practices
  settingsWindow.once('ready-to-show', () => {
    if (settingsWindow && !settingsWindow.isDestroyed()) {
      // Apply current theme to the settings window before showing
      themeManager.applyThemeToWindow(settingsWindow);
      settingsWindow.show();
    }
  });
}
