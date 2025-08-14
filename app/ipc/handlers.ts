/**
 * @file IPC message handlers
 */
import { ipcMain, BrowserWindow, shell, dialog, Menu, MenuItem, IpcMainEvent } from 'electron';
import { exec } from 'child_process';
// @ts-expect-error - Eleventy may not have perfect TypeScript types
import Eleventy from '@11ty/eleventy';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import archiver from 'archiver';
import BagIt from 'bagit-fs';
import {
  showPreview,
  hidePreview,
  reloadPreview,
  togglePreviewDevTools,
  getNativeInput,
  getBagItMetadata,
  BagItMetadata,
} from '../ui/window-manager';
import {
  createWebsiteWindow,
  loadWebsiteContent,
  getAllWebsiteWindows,
  startWebsiteServerAndUpdateWindow,
} from '../ui/multi-window-manager';
import { getCurrentLiveServerUrl, isLiveServerReady } from '../server/eleventy';
import {
  createWebsiteWithName,
  validateWebsiteName,
  listWebsites,
  getWebsitePath,
  renameWebsite,
  deleteWebsite,
} from '../utils/website-manager';

/**
 * Setup all IPC message listeners for inter-process communication
 *
 * Registers handlers for all IPC channels used by the application:
 * - Website management (create, open, list, validate, rename, delete)
 * - Export functionality (folder, ZIP, BagIt formats)
 * - Preview controls (show, hide, reload, devtools)
 * - Server operations (build, restart, browser opening)
 * - Theme management (get/set theme preferences)
 * - Context menu interactions
 *
 * All handlers include proper error handling and user feedback via dialogs.
 * Export handlers support progress tracking and metadata collection for BagIt format.
 * @example
 * ```typescript
 * // Called during app initialization
 * setupIpcMainListeners();
 * ```
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
    await exportSiteHandler(event, false);
  });

  // Export site to zip handler
  ipcMain.on('menu-export-site-zip', async (event) => {
    await exportSiteHandler(event, true);
  });

  // Website creation handler
  ipcMain.on('new-website', async (event) => {
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
        let prompt = 'Enter a name for your new website:';
        if (validationError) {
          prompt = `${validationError}\n\nPlease enter a valid website name:`;
        }

        websiteName = await getNativeInput('New Website', prompt);

        if (!websiteName) {
          return;
        }

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
    try {
      const allWebsites = listWebsites();
      const openWebsiteWindows = getAllWebsiteWindows();
      const openWebsiteNames = Array.from(openWebsiteWindows.keys());

      // Filter out websites that are already open
      const availableWebsites = allWebsites.filter((websiteName) => !openWebsiteNames.includes(websiteName));

      return availableWebsites;
    } catch (error) {
      console.error('Failed to list websites:', error);
      throw error;
    }
  });

  // Website opening handler
  ipcMain.on('open-website', async (event, websiteName: string) => {
    console.log(`DEBUG: Received open-website IPC for: ${websiteName}`);
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
 * Handle export site requests for folder, zip, and bagit formats
 *
 * Exports the currently focused website in the requested format:
 * - false/undefined: Export as folder
 * - true: Export as ZIP archive
 * - 'bagit': Export as BagIt archival format with metadata collection
 *
 * The function automatically builds the site using Eleventy before export,
 * shows appropriate save dialogs, and handles progress feedback to the user.
 * @param event IPC main event (null when called directly)
 * @param exportFormat Export format: false (folder), true (ZIP), or 'bagit' (BagIt archive)
 * @returns Promise that resolves when export is complete
 * @throws Will show error dialogs to user on export failure
 * @example
 * ```typescript
 * // Export as ZIP
 * await exportSiteHandler(null, true);
 *
 * // Export as BagIt with metadata
 * await exportSiteHandler(null, 'bagit');
 * ```
 */
export async function exportSiteHandler(event: IpcMainEvent | null, exportFormat: boolean | 'bagit'): Promise<void> {
  console.log(`DEBUG: exportSiteHandler called with exportFormat: ${exportFormat}`);

  // Get window from event or focused window
  const win = event ? BrowserWindow.fromWebContents(event.sender) : BrowserWindow.getFocusedWindow();
  if (!win) {
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

    // Determine export format details
    const isBagIt = exportFormat === 'bagit';
    const isZip = exportFormat === true;

    // For BagIt exports, collect metadata first
    let metadata: BagItMetadata | null = null;
    if (isBagIt) {
      metadata = await getBagItMetadata(websiteToExport);
      if (!metadata) {
        // User cancelled the metadata dialog
        return;
      }
    }

    let defaultExtension = '';
    let filters: { name: string; extensions: string[] }[] = [];

    if (isBagIt) {
      defaultExtension = '.bagit.zip';
      filters = [{ name: 'BagIt Archive', extensions: ['zip'] }];
    } else if (isZip) {
      defaultExtension = '.zip';
      filters = [{ name: 'Zip Archive', extensions: ['zip'] }];
    } else {
      defaultExtension = '';
      filters = [{ name: 'Folder', extensions: [] }];
    }

    // Show appropriate save dialog based on export type
    const result = await dialog.showSaveDialog(win, {
      title: `Export ${websiteToExport}`,
      defaultPath: websiteToExport + defaultExtension,
      filters,
    });

    if (result.canceled || !result.filePath) {
      return;
    }

    const exportPath = result.filePath;

    // Get the website source path
    const websitePath = getWebsitePath(websiteToExport);
    console.log(
      `Exporting website "${websiteToExport}" from ${websitePath} to ${exportPath} (format: ${exportFormat})`
    );

    // Determine the build output directory
    let buildDir: string;
    if (isBagIt) {
      buildDir = exportPath.replace('.bagit.zip', '');
    } else if (isZip) {
      buildDir = exportPath.replace('.zip', '');
    } else {
      buildDir = exportPath;
    }

    // Build the current website in the target directory using Eleventy programmatic API
    try {
      // In packaged apps, config file is relative to __dirname, in dev it's relative to cwd
      const isPackaged = process.env.NODE_ENV === 'production' || !process.env.NODE_ENV;
      const configPath = isPackaged
        ? path.resolve(__dirname, '..', 'eleventy', '.eleventy.js') // __dirname is in dist/app/ipc/, so go up one level
        : path.resolve(process.cwd(), 'app/eleventy/.eleventy.js');

      console.log(`Using Eleventy config: ${configPath}`);
      console.log(`Config exists: ${fs.existsSync(configPath)}`);
      console.log(`__dirname: ${__dirname}`);
      console.log(`process.cwd(): ${process.cwd()}`);
      console.log(`isPackaged: ${isPackaged}`);

      const elev = new Eleventy(websitePath, buildDir, {
        quietMode: false,
        configPath: configPath,
      });

      console.log(`Building website from ${websitePath} to ${buildDir}`);
      await elev.write();
      console.log('Build completed successfully');

      // Handle different export formats
      if (isBagIt) {
        // Use metadata collected before save dialog
        if (!metadata) {
          // This should not happen since we check above, but add safety check
          fs.rmSync(buildDir, { recursive: true, force: true });
          return;
        }
        await createBagItArchive(buildDir, exportPath, websiteToExport, win, metadata);
      } else if (isZip) {
        await createZipArchive(buildDir, exportPath, win);
      } else {
        // Folder export - files are already in place
        console.log(`Folder export completed: ${exportPath}`);
      }
    } catch (buildErr) {
      console.error('Build failed:', buildErr);
      dialog.showMessageBox(win, {
        type: 'error',
        title: 'Export Failed',
        message: 'Failed to build website for export',
        detail: buildErr instanceof Error ? buildErr.message : String(buildErr),
        buttons: ['OK'],
      });
      return;
    }
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
 * Create a zip archive from the build directory.
 */
async function createZipArchive(buildDir: string, exportPath: string, win: BrowserWindow): Promise<void> {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(buildDir)) {
      dialog.showMessageBox(win, {
        type: 'error',
        title: 'Export Failed',
        message: 'Built website not found',
        detail: 'The build directory was not found after building.',
        buttons: ['OK'],
      });
      reject(new Error('Build directory not found'));
      return;
    }

    const output = fs.createWriteStream(exportPath);
    const archive = archiver('zip', { zlib: { level: 9 } });

    output.on('close', () => {
      console.log(`Zip export completed: ${archive.pointer()} total bytes`);
      // Clean up the temporary build directory
      fs.rmSync(buildDir, { recursive: true, force: true });
      resolve();
    });

    archive.on('error', (err: Error) => {
      console.error('Zip archive error:', err);
      dialog.showMessageBox(win, {
        type: 'error',
        title: 'Export Failed',
        message: 'Failed to create zip archive',
        detail: err.message,
        buttons: ['OK'],
      });
      reject(err);
    });

    archive.pipe(output);
    archive.directory(buildDir, false);
    archive.finalize();
  });
}

/**
 * Create a BagIt archive from the build directory using Gladstone.
 */
async function createBagItArchive(
  buildDir: string,
  exportPath: string,
  websiteName: string,
  win: BrowserWindow,
  metadata: BagItMetadata
): Promise<void> {
  try {
    if (!fs.existsSync(buildDir)) {
      dialog.showMessageBox(win, {
        type: 'error',
        title: 'Export Failed',
        message: 'Built website not found',
        detail: 'The build directory was not found after building.',
        buttons: ['OK'],
      });
      throw new Error('Build directory not found');
    }

    console.log(`Creating BagIt archive for ${websiteName}...`);

    // Create a unique temporary directory in the OS tmp directory
    const tmpDir = os.tmpdir();
    const uniqueId = `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
    const tempBagDir = path.join(tmpDir, `anglesite_bagit_${uniqueId}`);

    // Get package info for bag metadata
    const packageJsonPath = path.join(process.cwd(), 'package.json');
    let bagSoftwareAgent = 'Anglesite';

    try {
      const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
      const version = packageJson.version || '0.1.0';
      const homepage = packageJson.homepage || 'https://github.com/anglesite/anglesite';
      bagSoftwareAgent = `Anglesite ${version} ${homepage}`;
    } catch (error) {
      console.warn('Could not read package.json for BagIt metadata:', error);
    }

    // Prepare BagIt metadata
    const bagMetadata: { [key: string]: string } = {
      'External-Description': metadata.externalDescription,
      'External-Identifier': metadata.externalIdentifier,
      'Source-Organization': metadata.sourceOrganization,
      'Bagging-Date': new Date().toISOString().split('T')[0],
      'Bag-Software-Agent': bagSoftwareAgent,
    };

    // Add optional fields only if provided
    if (metadata.organizationAddress.trim()) {
      bagMetadata['Organization-Address'] = metadata.organizationAddress;
    }
    if (metadata.contactName.trim()) {
      bagMetadata['Contact-Name'] = metadata.contactName;
    }
    if (metadata.contactPhone.trim()) {
      bagMetadata['Contact-Phone'] = metadata.contactPhone;
    }
    if (metadata.contactEmail.trim()) {
      bagMetadata['Contact-Email'] = metadata.contactEmail;
    }

    // Create the bag using bagit-fs
    const bag = BagIt(tempBagDir, 'sha256', bagMetadata);

    // Copy all files from build directory to bag
    await new Promise<void>((resolve, reject) => {
      // Track created directories to avoid redundant mkdir calls
      const createdDirs = new Set<string>();

      const copyFiles = (sourceDir: string, targetPrefix = '') => {
        const files = fs.readdirSync(sourceDir, { withFileTypes: true });
        let pending = files.length;

        if (pending === 0) {
          resolve();
          return;
        }

        files.forEach((file) => {
          const sourcePath = path.join(sourceDir, file.name);
          const targetPath = path.join(targetPrefix, file.name);

          if (file.isDirectory()) {
            // Create the directory in the bag if it has a path
            if (targetPath) {
              const bagDirPath = targetPath;
              if (!createdDirs.has(bagDirPath)) {
                createdDirs.add(bagDirPath);
                bag.mkdir(bagDirPath, (err) => {
                  if (err) {
                    console.warn(`Failed to create directory ${bagDirPath}:`, err);
                  }
                  // Recursively copy directory contents
                  copyFiles(sourcePath, targetPath);
                  pending--;
                  if (pending === 0) resolve();
                });
              } else {
                // Directory already created, just recurse
                copyFiles(sourcePath, targetPath);
                pending--;
                if (pending === 0) resolve();
              }
            } else {
              // Root level, just recurse
              copyFiles(sourcePath, targetPath);
              pending--;
              if (pending === 0) resolve();
            }
          } else {
            // Copy file to bag
            const readStream = fs.createReadStream(sourcePath);
            // Use relative path - BagIt library automatically handles /data/ prefix
            const bagPath = targetPath;
            const writeStream = bag.createWriteStream(bagPath);

            readStream.pipe(writeStream);
            writeStream.on('finish', () => {
              pending--;
              if (pending === 0) resolve();
            });
            writeStream.on('error', reject);
          }
        });
      };

      copyFiles(buildDir);
    });

    // Finalize the bag
    await new Promise<void>((resolve) => {
      bag.finalize(() => {
        console.log('BagIt structure finalized');
        resolve();
      });
    });

    console.log('BagIt structure created, creating archive...');

    // Create a temporary zip file from the bag
    const tempZipPath = path.join(tmpDir, `anglesite_bagit_${uniqueId}.zip`);
    await createZipArchiveFromDirectory(tempBagDir, tempZipPath);

    // Copy the completed archive to the user-selected location
    fs.copyFileSync(tempZipPath, exportPath);

    // Clean up temporary files and directories
    fs.rmSync(tempBagDir, { recursive: true, force: true });
    fs.rmSync(tempZipPath, { force: true });
    fs.rmSync(buildDir, { recursive: true, force: true });

    console.log(`BagIt archive completed: ${exportPath}`);
  } catch (error) {
    console.error('BagIt archive creation failed:', error);

    // Clean up any temporary files on error
    const tmpDir = os.tmpdir();
    const tempDirs = fs.readdirSync(tmpDir).filter((name) => name.startsWith('anglesite_bagit_'));
    tempDirs.forEach((dir) => {
      try {
        const fullPath = path.join(tmpDir, dir);
        if (fs.existsSync(fullPath)) {
          if (fs.statSync(fullPath).isDirectory()) {
            fs.rmSync(fullPath, { recursive: true, force: true });
          } else {
            fs.rmSync(fullPath, { force: true });
          }
        }
      } catch (cleanupError) {
        console.warn('Failed to clean up temporary file:', dir, cleanupError);
      }
    });

    dialog.showMessageBox(win, {
      type: 'error',
      title: 'Export Failed',
      message: 'Failed to create BagIt archive',
      detail: error instanceof Error ? error.message : String(error),
      buttons: ['OK'],
    });
    throw error;
  }
}

/**
 * Helper function to create a zip archive from a directory.
 */
async function createZipArchiveFromDirectory(sourceDir: string, outputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outputPath);
    const archive = archiver('zip', { zlib: { level: 9 } });

    output.on('close', () => {
      console.log(`BagIt zip archive created: ${archive.pointer()} total bytes`);
      resolve();
    });

    archive.on('error', (err: Error) => {
      console.error('BagIt zip archive error:', err);
      reject(err);
    });

    archive.pipe(output);
    archive.directory(sourceDir, false);
    archive.finalize();
  });
}

/**
 * Create a new website with the given name and open it in a new window.
 */
async function createNewWebsite(websiteName: string): Promise<void> {
  console.log('Creating new website:', websiteName);

  let websiteCreated = false;
  let newWebsitePath = '';

  try {
    // Step 1: Create the website files (this validates name and creates directory)
    newWebsitePath = await createWebsiteWithName(websiteName);
    websiteCreated = true;
    console.log('New website created at:', newWebsitePath);

    // Step 2: Open the new website in a new window (with isNewWebsite = true)
    await openWebsiteInNewWindow(websiteName, newWebsitePath, true);

    console.log(`Website "${websiteName}" created and opened in new window`);
  } catch (error) {
    console.error('Failed to create new website:', error);

    // If we created the website directory but failed to open it, clean up
    if (websiteCreated && newWebsitePath) {
      try {
        console.log('Cleaning up partially created website directory...');
        if (fs.existsSync(newWebsitePath)) {
          fs.rmSync(newWebsitePath, { recursive: true, force: true });
          console.log('Cleaned up website directory:', newWebsitePath);
        }
      } catch (cleanupError) {
        console.error('Failed to clean up website directory:', cleanupError);
        // Don't throw cleanup error, let the original error be thrown
      }
    }

    // If the error is about website already existing, provide a helpful message
    if (error instanceof Error && error.message.includes('already exists')) {
      // Check if the website actually exists and is valid
      try {
        const { getWebsitePath } = await import('../utils/website-manager');
        const existingPath = getWebsitePath(websiteName);
        if (fs.existsSync(existingPath)) {
          // Website exists, try to open it instead
          console.log('Website already exists, attempting to open existing website...');
          await openWebsiteInNewWindow(websiteName, existingPath, false);
          console.log(`Opened existing website "${websiteName}" successfully`);
          return; // Success - exit without throwing
        }
      } catch (openError) {
        console.error('Failed to open existing website:', openError);
        // Fall through to throw original error
      }
    }

    throw error;
  }
}

/**
 * Open a website in a new dedicated window.
 */
export async function openWebsiteInNewWindow(
  websiteName: string,
  websitePath?: string,
  isNewWebsite: boolean = false
): Promise<void> {
  console.log(`Opening website "${websiteName}" in new window (new website: ${isNewWebsite})`);

  let windowCreated = false;

  try {
    // Step 1: Get website path if not provided
    const actualWebsitePath = websitePath || getWebsitePath(websiteName);
    console.log(`Website path resolved to: ${actualWebsitePath}`);

    // Verify the website directory exists
    if (!fs.existsSync(actualWebsitePath)) {
      throw new Error(`Website directory does not exist: ${actualWebsitePath}`);
    }

    // Step 2: Create a new window for this website
    createWebsiteWindow(websiteName, actualWebsitePath);
    windowCreated = true;
    console.log(`Window created for: ${websiteName}`);

    // Step 3: Try to start individual server for this website, fallback gracefully
    try {
      await startWebsiteServerAndUpdateWindow(websiteName, actualWebsitePath);
      console.log(`Individual server started successfully for: ${websiteName}`);
    } catch (serverError) {
      console.warn(`Failed to start individual server for ${websiteName}, using fallback content:`, serverError);
      // Load with fallback content - this is not a fatal error
      try {
        loadWebsiteContent(websiteName);
        console.log(`Fallback content loaded for: ${websiteName}`);
      } catch (fallbackError) {
        console.error(`Failed to load fallback content for ${websiteName}:`, fallbackError);
        // Don't throw here - window is created, user can manually reload
      }
    }

    console.log(`Website "${websiteName}" ready in dedicated window`);
  } catch (error) {
    console.error(`Failed to open website "${websiteName}" in new window:`, error);

    // If we created a window but failed later, the window will remain open
    // which is probably what the user wants (they can see the error and try to reload)
    if (windowCreated) {
      console.log(
        `Window was created for ${websiteName} but startup failed. Window remains open for manual intervention.`
      );
    }

    throw new Error(
      `Failed to open website "${websiteName}": ${error instanceof Error ? error.message : String(error)}`
    );
  }
}
