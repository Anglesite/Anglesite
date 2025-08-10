/**
 * @file Main process of the Electron application (Refactored)
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/quick-start}
 */
import { app, Menu } from 'electron';
// Import modular components
import { createHelpWindow, closeAllWindows } from './ui/multi-window-manager';
import { createApplicationMenu } from './ui/menu';
import { setupIpcMainListeners } from './ipc/handlers';
import { Store } from './store';
import { handleFirstLaunch } from './utils/first-launch';
import { cleanupEleventyServer, startDefaultEleventyServer } from './server/eleventy';
import { createHttpsProxy } from './server/https-proxy';
import { addLocalDnsResolution, cleanupHostsFile, checkAndSuggestTouchIdSetup } from './dns/hosts-manager';

// Set application name as early as possible
app.setName('Anglesite');

/**
 * Main window instance - will become help window
 */
let mainWindow: Electron.BrowserWindow | null = null;

/**
 * App settings store
 */
let store: Store;

/**
 * Initialize the application
 */
async function initializeApp(): Promise<void> {
  console.log('Initializing Anglesite...');

  // Initialize app settings store
  store = new Store();

  // Check if first launch is needed
  if (!store.get('firstLaunchCompleted')) {
    await handleFirstLaunch(store);
  }

  // Create the help window as the main window
  mainWindow = createHelpWindow();

  // Set up the application menu
  const menu = createApplicationMenu();
  Menu.setApplicationMenu(menu);

  // Setup IPC handlers
  setupIpcMainListeners();

  // Clean up hosts file to match existing websites
  console.log('Cleaning up hosts file...');
  await cleanupHostsFile();

  // Check Touch ID setup and provide helpful information
  await checkAndSuggestTouchIdSetup();

  // Start the default Eleventy server for help/docs
  await startDefaultServer();

  console.log('Anglesite initialization complete - Help window ready');
}

/**
 * Start the default Eleventy server for docs
 */
async function startDefaultServer(): Promise<void> {
  const httpsMode = store.get('httpsMode') || 'http';
  await startDefaultEleventyServer(httpsMode, mainWindow, addLocalDnsResolution, createHttpsProxy, () => {
    // No need to auto-load preview for help window - it loads its own content
    console.log('Default server ready for help content');
  });
}

/**
 * App event handlers
 */
app.whenReady().then(() => {
  initializeApp();

  app.on('activate', () => {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (mainWindow === null) {
      initializeApp();
    }
  });
});

// Quit when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// Clean up resources when the app is about to quit
app.on('before-quit', () => {
  console.log('Cleaning up resources...');
  cleanupEleventyServer();
  closeAllWindows();
});

// Handle certificate errors for development
app.on('certificate-error', (event, _webContents, url, _error, _certificate, callback) => {
  // Allow self-signed certificates for local development
  if (url.includes('localhost') || url.includes('.test')) {
    event.preventDefault();
    callback(true);
  } else {
    callback(false);
  }
});

export { mainWindow };
