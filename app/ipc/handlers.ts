/**
 * @file IPC message handlers
 */
import { ipcMain, BrowserWindow, shell, dialog, Menu, MenuItem, IpcMainEvent } from 'electron';
import { exec } from 'child_process';
import * as fs from 'fs';
import archiver from 'archiver';
import { showPreview, hidePreview, reloadPreview, togglePreviewDevTools, getNativeInput } from '../ui/window-manager';
import { createWebsiteWindow, loadWebsiteContent, getAllWebsiteWindows } from '../ui/multi-window-manager';
import {
  getCurrentLiveServerUrl,
  isLiveServerReady,
  switchToWebsite,
  setLiveServerUrl,
  setCurrentWebsiteName,
} from '../server/eleventy';
import {
  createWebsiteWithName,
  validateWebsiteName,
  listWebsites,
  getWebsitePath,
  renameWebsite,
  deleteWebsite,
} from '../utils/website-manager';
import { addLocalDnsResolution } from '../dns/hosts-manager';
import { restartHttpsProxy } from '../server/https-proxy';
import { Store } from '../store';

/**
 * Setup all IPC message listeners
 */
export function setupIpcMainListeners(): void {
  // Build command handler
  ipcMain.on('build', () => {
    exec('npm run build', (err, stdout) => {
      if (err) {
        console.error(err);
        return;
      }
      console.log(stdout);
    });
  });

  // Preview handlers
  ipcMain.on('preview', (event) => {
    const serverUrl = getCurrentLiveServerUrl();
    console.log('Preview requested, using server URL:', serverUrl);
    console.log('Live server ready:', isLiveServerReady());

    if (!isLiveServerReady()) {
      console.log('Live server not ready yet, waiting...');
      event.reply('preview-error', 'Live server is not ready yet. Please wait a moment and try again.');
      return;
    }

    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      showPreview(win);
    }
  });

  ipcMain.on('hide-preview', (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      hidePreview(win);
    }
  });

  ipcMain.on('toggle-devtools', () => {
    console.log('DevTools toggle requested');
    togglePreviewDevTools();
  });

  ipcMain.on('reload-preview', () => {
    reloadPreview();
  });

  // Browser handlers
  ipcMain.on('open-browser', async () => {
    try {
      await shell.openExternal(getCurrentLiveServerUrl());
    } catch {
      console.log('Failed to open .test domain, trying localhost');
      const localhostUrl = getCurrentLiveServerUrl().replace(/https:\/\/[^.]+\.test:/, 'https://localhost:');
      try {
        await shell.openExternal(localhostUrl);
      } catch (fallbackError) {
        console.error('Failed to open in browser:', fallbackError);
      }
    }
  });

  // Export site to folder handler
  ipcMain.on('menu-export-site-folder', async (event) => {
    console.log('DEBUG: Received menu-export-site-folder IPC message');
    await exportSiteHandler(event, false);
  });

  // Export site to zip handler
  ipcMain.on('menu-export-site-zip', async (event) => {
    console.log('DEBUG: Received menu-export-site-zip IPC message');
    await exportSiteHandler(event, true);
  });

  // Website creation handler
  ipcMain.on('new-website', async (event) => {
    console.log('DEBUG: Received new-website IPC message');

    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) {
      console.error('No window found for new-website IPC message');
      return;
    }

    try {
      let websiteName: string | null = null;
      let validationError = '';

      // Keep asking until user provides valid name or cancels
      do {
        console.log('DEBUG: Getting website name from user using native approach');

        let prompt = 'Enter a name for your new website:';
        if (validationError) {
          prompt = `${validationError}\n\nPlease enter a valid website name:`;
        }

        websiteName = await getNativeInput('New Website', prompt);

        if (!websiteName) {
          console.log('DEBUG: User cancelled website creation');
          return;
        }

        console.log('DEBUG: User provided website name:', websiteName);

        // Validate website name
        const validation = validateWebsiteName(websiteName);
        if (!validation.valid) {
          validationError = validation.error || 'Invalid website name';
          websiteName = null; // Reset to continue the loop
        } else {
          validationError = ''; // Clear any previous error
        }
      } while (!websiteName);

      await createNewWebsite(websiteName);
    } catch (error) {
      console.error('Failed to create new website:', error);
      dialog.showMessageBox(win, {
        type: 'error',
        title: 'Creation Failed',
        message: 'Failed to create website',
        detail: error instanceof Error ? error.message : String(error),
        buttons: ['OK'],
      });
    }
  });

  // Development tools
  ipcMain.on('clear-cache', (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      win.webContents.session.clearCache();
      console.log('Cache cleared');
    }
  });

  // File operations
  ipcMain.on('show-item-in-folder', async (event, filePath: string) => {
    if (filePath) {
      shell.showItemInFolder(filePath);
    }
  });

  // Website listing handler
  ipcMain.handle('list-websites', async () => {
    console.log('DEBUG: Received list-websites request');
    try {
      const allWebsites = listWebsites();
      const openWebsiteWindows = getAllWebsiteWindows();
      const openWebsiteNames = Array.from(openWebsiteWindows.keys());

      // Filter out websites that are already open
      const availableWebsites = allWebsites.filter((websiteName) => !openWebsiteNames.includes(websiteName));

      console.log('DEBUG: All websites:', allWebsites);
      console.log('DEBUG: Open websites:', openWebsiteNames);
      console.log('DEBUG: Available websites:', availableWebsites);
      return availableWebsites;
    } catch (error) {
      console.error('Failed to list websites:', error);
      throw error;
    }
  });

  // Website opening handler
  ipcMain.on('open-website', async (event, websiteName: string) => {
    console.log('DEBUG: Received open-website request for:', websiteName);

    try {
      await openWebsiteInNewWindow(websiteName);
      console.log(`Website "${websiteName}" opened successfully in new window`);
    } catch (error) {
      console.error('Failed to open website:', error);
      const websiteWindow = createWebsiteWindow(websiteName);
      dialog.showMessageBox(websiteWindow, {
        type: 'error',
        title: 'Open Failed',
        message: 'Failed to open website',
        detail: error instanceof Error ? error.message : String(error),
        buttons: ['OK'],
      });
    }
  });

  // Website context menu handler
  ipcMain.on('show-website-context-menu', (event, websiteName: string, position: { x: number; y: number }) => {
    const contextMenu = new Menu();
    const window = BrowserWindow.fromWebContents(event.sender);

    contextMenu.append(
      new MenuItem({
        label: 'Rename',
        click: () => {
          event.sender.send('website-context-menu-action', 'rename', websiteName);
        },
      })
    );

    contextMenu.append(
      new MenuItem({
        label: 'Delete',
        click: () => {
          event.sender.send('website-context-menu-action', 'delete', websiteName);
        },
      })
    );

    // Show context menu - let Electron position it automatically if window is provided
    if (window) {
      console.log('Showing context menu with window positioning');
      contextMenu.popup({ window });
    } else {
      console.log('Showing context menu at position:', position);
      contextMenu.popup({
        x: Math.round(position.x),
        y: Math.round(position.y),
      });
    }
  });

  // Website name validation handler
  ipcMain.handle('validate-website-name', async (event, name: string) => {
    console.log(`DEBUG: Received validate-website-name request for: "${name}"`);
    return validateWebsiteName(name);
  });

  // Website rename handler
  ipcMain.handle('rename-website', async (event, oldName: string, newName: string) => {
    console.log(`DEBUG: Received rename-website request: "${oldName}" -> "${newName}"`);

    try {
      const success = await renameWebsite(oldName, newName);
      console.log(`Website "${oldName}" renamed to "${newName}" successfully`);

      // Notify the website selection window to refresh
      event.sender.send('website-operation-completed');

      return success;
    } catch (error) {
      console.error('Failed to rename website:', error);
      throw error; // Let the frontend handle the error display
    }
  });

  // Website delete handler
  ipcMain.on('delete-website', async (event, websiteName: string) => {
    console.log(`DEBUG: Received delete-website request for: "${websiteName}"`);

    try {
      const window = BrowserWindow.fromWebContents(event.sender);
      const deleted = await deleteWebsite(websiteName, window || undefined);

      if (deleted) {
        console.log(`Website "${websiteName}" deleted successfully`);
        // Notify the website selection window to refresh
        event.sender.send('website-operation-completed');
      } else {
        console.log(`Website deletion cancelled by user: "${websiteName}"`);
      }
    } catch (error) {
      console.error('Failed to delete website:', error);
      const window = BrowserWindow.fromWebContents(event.sender);
      if (window) {
        dialog.showMessageBox(window, {
          type: 'error',
          title: 'Delete Failed',
          message: 'Failed to delete website',
          detail: error instanceof Error ? error.message : String(error),
          buttons: ['OK'],
        });
      }
    }
  });
}

/**
 * Handle export site requests for both folder and zip formats
 */
export async function exportSiteHandler(event: IpcMainEvent | null, exportAsZip: boolean): Promise<void> {
  console.log(`DEBUG: exportSiteHandler called with exportAsZip: ${exportAsZip}`);
  
  // Get window from event or focused window
  const win = event ? BrowserWindow.fromWebContents(event.sender) : BrowserWindow.getFocusedWindow();
  if (!win) {
    console.log('DEBUG: No window found for export handler');
    return;
  }

  try {
    // Get the currently focused website window to determine which website to export
    const focusedWindow = BrowserWindow.getFocusedWindow();
    const websiteWindows = getAllWebsiteWindows();
    let websiteToExport: string | null = null;

    // Find which website window is focused
    for (const [websiteName, websiteWindow] of websiteWindows) {
      if (websiteWindow.window === focusedWindow) {
        websiteToExport = websiteName;
        break;
      }
    }

    if (!websiteToExport) {
      console.log('DEBUG: No website selected for export');
      dialog.showMessageBox(win, {
        type: 'info',
        title: 'No Website Selected',
        message: 'Please open a website window first',
        detail: 'To export a website, you need to have a website window open and focused.',
        buttons: ['OK'],
      });
      return;
    }

    console.log(`DEBUG: Found website to export: ${websiteToExport}`);

    // Show appropriate save dialog based on export type
    const result = await dialog.showSaveDialog(win, {
      title: `Export ${websiteToExport}`,
      defaultPath: websiteToExport + (exportAsZip ? '.zip' : ''),
      filters: exportAsZip 
        ? [{ name: 'Zip Archive', extensions: ['zip'] }]
        : [{ name: 'Folder', extensions: [] }],
    });

    if (result.canceled || !result.filePath) {
      return;
    }

    const exportPath = result.filePath;

    // Get the website source path
    const websitePath = getWebsitePath(websiteToExport);
    console.log(`Exporting website "${websiteToExport}" from ${websitePath} to ${exportPath} (zip: ${exportAsZip})`);
    
    // Determine the build output directory
    const buildDir = exportAsZip ? exportPath.replace('.zip', '') : exportPath;

    // Build the current website in the target directory
    exec(
      `npx eleventy --config=app/eleventy/.eleventy.js --input="${websitePath}" --output="${buildDir}"`,
      { cwd: process.cwd() },
      (buildErr, buildStdout) => {
        if (buildErr) {
          console.error('Build failed:', buildErr);
          dialog.showMessageBox(win, {
            type: 'error',
            title: 'Export Failed',
            message: 'Failed to build website for export',
            detail: buildErr.message,
            buttons: ['OK'],
          });
          return;
        }

        console.log('Build completed:', buildStdout);

        // Create a zip archive if user chose zip export
        if (exportAsZip) {
          if (!fs.existsSync(buildDir)) {
            dialog.showMessageBox(win, {
              type: 'error',
              title: 'Export Failed',
              message: 'Built website not found',
              detail: 'The build directory was not found after building.',
              buttons: ['OK'],
            });
            return;
          }

          const output = fs.createWriteStream(exportPath);
          const archive = archiver('zip', { zlib: { level: 9 } });

          output.on('close', () => {
            console.log(`Export completed: ${archive.pointer()} total bytes`);
            // Clean up the temporary build directory
            fs.rmSync(buildDir, { recursive: true, force: true });
          });

          archive.on('error', (err: Error) => {
            console.error('Archive error:', err);
            dialog.showMessageBox(win, {
              type: 'error',
              title: 'Export Failed',
              message: 'Failed to create export archive',
              detail: err.message,
              buttons: ['OK'],
            });
          });

          archive.pipe(output);
          archive.directory(buildDir, false);
          archive.finalize();
        } else {
          // User chose folder export, files are already in place
          console.log(`Folder export completed: ${exportPath}`);
        }
      }
    );
  } catch (error) {
    console.error('Export failed:', error);
    dialog.showMessageBox(win, {
      type: 'error',
      title: 'Export Failed',
      message: 'Failed to export website',
      detail: error instanceof Error ? error.message : String(error),
      buttons: ['OK'],
    });
  }
}

/**
 * Create a new website with the given name and open it in a new window
 */
async function createNewWebsite(websiteName: string): Promise<void> {
  console.log('Creating new website:', websiteName);

  try {
    // Create the website files
    const newWebsitePath = await createWebsiteWithName(websiteName);
    console.log('New website created at:', newWebsitePath);

    // Open the new website in a new window (with isNewWebsite = true)
    await openWebsiteInNewWindow(websiteName, newWebsitePath, true);

    console.log(`Website "${websiteName}" created and opened in new window`);
  } catch (error) {
    console.error('Failed to create new website:', error);
    throw error;
  }
}

/**
 * Open a website in a new dedicated window
 */
async function openWebsiteInNewWindow(websiteName: string, websitePath?: string, isNewWebsite: boolean = false): Promise<void> {
  console.log(`Opening website "${websiteName}" in new window (new website: ${isNewWebsite})`);

  try {
    // Get website path if not provided
    const actualWebsitePath = websitePath || getWebsitePath(websiteName);
    console.log('DEBUG: Opening website at path:', actualWebsitePath);

    // Create a new window for this website
    createWebsiteWindow(websiteName, actualWebsitePath);

    // Switch to the selected website and get the actual port
    const actualPort = await switchToWebsite(actualWebsitePath);
    console.log('DEBUG: switchToWebsite completed for:', websiteName, 'on port:', actualPort);

    // Generate test domain and setup DNS
    const testDomain = `https://${websiteName}.test:8080`;
    const hostname = `${websiteName}.test`;

    console.log('DEBUG: generated test domain:', testDomain);

    // Setup DNS resolution
    await addLocalDnsResolution(hostname);

    // Check user's HTTPS preference
    const store = new Store();
    const httpsMode = store.get('httpsMode');

    if (httpsMode === 'https') {
      // Restart HTTPS proxy for the domain using the actual port
      const httpsSuccess = await restartHttpsProxy(8080, actualPort, hostname);
      if (httpsSuccess) {
        console.log(`Website HTTPS server ready at: ${testDomain}`);
        // Update the server URL for the new website
        setLiveServerUrl(testDomain);
        setCurrentWebsiteName(websiteName);
      } else {
        console.log('HTTPS proxy failed, continuing with HTTP-only mode');
        // Fallback to HTTP URL with actual port
        setLiveServerUrl(`http://localhost:${actualPort}`);
        setCurrentWebsiteName(websiteName);
      }
    } else {
      console.log('HTTP-only mode by user preference, skipping HTTPS proxy');
      // Set HTTP URL with actual port
      setLiveServerUrl(`http://localhost:${actualPort}`);
      setCurrentWebsiteName(websiteName);
    }

    // Load the website content in its window (after HTTPS proxy is ready)
    // Add a longer delay for new websites to ensure Eleventy has fully processed the files
    const delay = isNewWebsite ? 2500 : 1000;
    setTimeout(() => {
      loadWebsiteContent(websiteName);
      console.log('DEBUG: loadWebsiteContent called for website window');
    }, delay);

    console.log(`Website "${websiteName}" ready in dedicated window`);
  } catch (error) {
    console.error(`Failed to open website "${websiteName}" in new window:`, error);
    throw error;
  }
}
