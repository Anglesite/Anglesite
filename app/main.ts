/**
 * @file Main process of the Electron application.
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/quick-start}
 */
import { app, BrowserWindow, WebContentsView, ipcMain, Menu } from "electron";
import * as path from "path";
import * as fs from "fs";
import { exec, spawn, ChildProcess } from "child_process";

// Set application name as early as possible
app.setName("Anglesite");

/**
 * Live server process instance.
 * @type {ChildProcess}
 */
export let liveServerProcess: ChildProcess;

/**
 * Preview WebContentsView instance.
 * @type {WebContentsView}
 */
export let previewWebContentsView: WebContentsView;

/**
 * Creates the main Electron browser window.
 * @returns {void}
 */
export function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    title: "Anglesite",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Load the Electron app UI
  win.loadFile(path.join(__dirname, "index.html"));

  // Create the preview WebContentsView
  previewWebContentsView = new WebContentsView({
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
    },
  });

  console.log("WebContentsView created:", !!previewWebContentsView);

  // Add the WebContentsView to the window and show it immediately
  win.contentView.addChildView(previewWebContentsView);

  // Position the WebContentsView in the preview area
  previewWebContentsView.setBounds({ x: 0, y: 90, width: 1200, height: 710 });

  // Add general error handling to the WebContentsView
  previewWebContentsView.webContents.on("render-process-gone", () => {
    console.error("WebContentsView webContents crashed");
  });

  previewWebContentsView.webContents.on("unresponsive", () => {
    console.error("WebContentsView webContents unresponsive");
  });

  // Keep webSecurity enabled for better security

  console.log("WebContentsView created and ready to display content");

  // Start Eleventy's built-in server (no script injection, integrated with build)
  liveServerProcess = spawn(
    "npx",
    [
      "eleventy",
      "--config=eleventy/.eleventy.js",
      "--serve",
      "--port=8080",
      "--quiet",
    ],
    {
      cwd: process.cwd(),
      shell: true,
    }
  );

  let liveServerUrl = "";

  if (liveServerProcess.stdout) {
    liveServerProcess.stdout.on("data", (data: Buffer) => {
      const output = data.toString();
      console.log(`eleventy: ${output}`);

      // Eleventy outputs something like "[11ty] Server at http://localhost:8080/"
      const urlMatch = output.match(/Server at (https?:\/\/[^\s/]+)/);
      if (urlMatch) {
        liveServerUrl = urlMatch[1];
        setLiveServerUrl(liveServerUrl);
        liveServerReady = true;
        console.log(`Eleventy server URL detected: ${liveServerUrl}`);
        console.log("Eleventy server is ready");

        // Auto-load the preview once server is ready
        autoLoadPreview(win);
      }
    });
  }

  if (liveServerProcess.stderr) {
    liveServerProcess.stderr.on("data", (data: Buffer) => {
      console.error(`eleventy error: ${data}`);
    });
  }

  liveServerProcess.on("close", (code: number) => {
    console.log(`eleventy process exited with code ${code}`);
  });

  // Fallback: If Eleventy doesn't output the URL within 2 seconds, assume it's ready
  setTimeout(() => {
    if (!liveServerReady) {
      setLiveServerUrl(currentLiveServerUrl);
      liveServerReady = true;
      console.log(`Eleventy server URL (fallback): ${currentLiveServerUrl}`);
      console.log("Eleventy server is ready");
      autoLoadPreview(win);
    }
  }, 2000);
}

/**
 * Current live-server URL.
 * @type {string}
 */
let currentLiveServerUrl = "http://127.0.0.1:8080";

/**
 * Whether live-server is ready.
 * @type {boolean}
 */
let liveServerReady = false;

/**
 * Auto-loads the preview when live-server is ready.
 * @param {BrowserWindow} win - The main window
 * @returns {void}
 */
function autoLoadPreview(win: BrowserWindow) {
  if (win && previewWebContentsView && liveServerReady) {
    console.log("Auto-loading preview with URL:", currentLiveServerUrl);

    // WebContentsView is already added to window, just position it
    // Add error handling for URL loading (only add listeners once)
    previewWebContentsView.webContents.removeAllListeners("did-fail-load");
    previewWebContentsView.webContents.removeAllListeners("did-finish-load");

    previewWebContentsView.webContents.on(
      "did-fail-load",
      (event, errorCode, errorDescription, validatedURL) => {
        console.error(
          "Auto-load failed for URL:",
          validatedURL,
          "Error:",
          errorCode,
          errorDescription
        );
        // Fallback to file:// protocol if HTTP fails
        loadLocalFilePreview(win);
      }
    );

    previewWebContentsView.webContents.on("did-finish-load", () => {
      console.log("Auto-loaded preview successfully:", currentLiveServerUrl);
    });

    // Load the local server content with a small delay
    setTimeout(() => {
      console.log("Auto-loading URL now:", currentLiveServerUrl);
      previewWebContentsView.webContents.loadURL(currentLiveServerUrl);
    }, 100);

    // Position it correctly (accounting for menu bars)
    const bounds = win.getBounds();
    previewWebContentsView.setBounds({
      x: 0,
      y: 90, // Height of both menu bars
      width: bounds.width,
      height: bounds.height - 90,
    });

    // Send message to renderer
    win.webContents.send("preview-loaded");
    console.log("Auto-preview loaded successfully");
  }
}

/**
 * Loads local content using file:// protocol as a secure fallback.
 * @param {BrowserWindow} win - The main window
 * @returns {void}
 */
function loadLocalFilePreview(win: BrowserWindow) {
  if (win && previewWebContentsView) {
    const distPath = path.resolve(process.cwd(), "dist");
    const indexFile = path.join(distPath, "index.html");
    const fileUrl = `file://${indexFile}`;

    console.log("Loading local file preview:", fileUrl);

    // Check if file exists before loading
    try {
      if (fs.existsSync(indexFile)) {
        previewWebContentsView.webContents.loadFile(indexFile);
      } else {
        console.error("Index file not found:", indexFile);
      }
    } catch (error) {
      console.error("Error loading local file preview:", error);
    }
  }
}

/**
 * Sets the current live-server URL.
 * @param {string} url - The live-server URL
 * @returns {void}
 */
export function setLiveServerUrl(url: string) {
  currentLiveServerUrl = url;
  liveServerReady = true;
}

/**
 * Gets user input using native approach - combines native dialogs with minimal custom window.
 * @param {BrowserWindow} parent - The parent window
 * @param {Object} options - Input options
 * @returns {Promise<string|null>}
 */
async function getNativeInput(parent: BrowserWindow, options: {
  title: string;
  message: string;
  defaultValue?: string;
}): Promise<string | null> {
  // Go directly to the input window without interstitial dialog
  return new Promise((resolve) => {
    const inputWindow = new BrowserWindow({
      parent: parent,
      modal: true,
      width: 380,
      height: 180,
      resizable: false,
      minimizable: false,
      maximizable: false,
      title: options.title,
      titleBarStyle: 'default',
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        preload: path.join(__dirname, "preload.js"),
      },
    });

    // Remove menu bar for cleaner look
    inputWindow.setMenuBarVisibility(false);

    // Create minimal native-style HTML
    const inputHTML = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>${options.title}</title>
        <style>
          * { box-sizing: border-box; }
          body { 
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif; 
            margin: 0; padding: 16px; 
            background: #f5f5f5;
            display: flex;
            flex-direction: column;
            justify-content: center;
            height: 100vh;
          }
          .form { 
            background: white;
            padding: 16px;
            border-radius: 6px;
            border: 1px solid #d0d0d0;
          }
          label { 
            display: block; 
            margin-bottom: 8px; 
            font-size: 13px; 
            color: #333;
            font-weight: 500;
          }
          input { 
            width: 100%; 
            padding: 8px 12px; 
            font-size: 13px; 
            border: 1px solid #ccc; 
            border-radius: 4px;
            outline: none;
          }
          input:focus { border-color: #007AFF; }
          .buttons { 
            margin-top: 16px; 
            text-align: right;
          }
          button { 
            padding: 6px 16px; 
            margin-left: 8px; 
            font-size: 13px; 
            border: 1px solid #ccc; 
            border-radius: 4px; 
            cursor: pointer;
            background: white;
          }
          .primary { 
            background: #007AFF; 
            color: white; 
            border-color: #007AFF;
          }
          .primary:hover { background: #0056CC; }
          button:hover { background: #f0f0f0; }
          .primary:hover { background: #0056CC; }
        </style>
      </head>
      <body>
        <div class="form">
          <div style="margin-bottom: 12px; font-size: 14px; color: #666;">${options.message}</div>
          <label for="nameInput">Website Name:</label>
          <input type="text" id="nameInput" value="${options.defaultValue || ''}" autofocus>
          <div class="buttons">
            <button onclick="cancel()">Cancel</button>
            <button class="primary" onclick="submit()">Create</button>
          </div>
        </div>
        <script>
          function submit() {
            const value = document.getElementById('nameInput').value.trim();
            if (value) {
              window.electronAPI.send('input-dialog-result', value);
            }
          }
          function cancel() {
            window.electronAPI.send('input-dialog-result', null);
          }
          document.getElementById('nameInput').addEventListener('keydown', (e) => {
            if (e.key === 'Enter') submit();
            if (e.key === 'Escape') cancel();
          });
          // Auto-select the text for easy editing
          document.getElementById('nameInput').select();
        </script>
      </body>
      </html>
    `;

    // Write HTML to temp file and load it
    const tempPath = path.join(__dirname, 'native-input.html');
    fs.writeFileSync(tempPath, inputHTML, 'utf-8');
    inputWindow.loadFile(tempPath);

    // Set up result handling
    const handleResult = (_event: any, result: string | null) => {
      ipcMain.removeListener('input-dialog-result', handleResult);
      inputWindow.close();
      try { fs.unlinkSync(tempPath); } catch {}
      resolve(result);
    };

    ipcMain.on('input-dialog-result', handleResult);

    inputWindow.on('closed', () => {
      ipcMain.removeListener('input-dialog-result', handleResult);
      try { fs.unlinkSync(tempPath); } catch {}
      resolve(null);
    });
  });
}

/**
 * Switches the application to serve a different website.
 * @param {BrowserWindow} win - The browser window
 * @param {string} websitePath - Path to the website directory
 * @returns {Promise<void>}
 */
async function switchToWebsite(win: BrowserWindow, websitePath: string): Promise<void> {
  console.log("Switching to website at:", websitePath);
  
  // Stop the current live server
  if (liveServerProcess) {
    console.log("Stopping current Eleventy server");
    try {
      liveServerProcess.kill("SIGTERM");
    } catch (error) {
      console.warn("Error stopping live server:", error);
    }
  }

  // Start Eleventy server for the new website
  console.log("Starting Eleventy server for new website");
  console.log("Website path:", websitePath);
  
  liveServerProcess = spawn(
    process.platform === "win32" ? "npx.cmd" : "npx",
    [
      "eleventy",
      "--config=eleventy/.eleventy.js",
      `--input=${websitePath}`,
      "--serve",
      "--port=8080",
      "--quiet",
    ],
    {
      cwd: process.cwd(),
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    }
  );

  // Set up server output handling
  if (liveServerProcess.stdout) {
    liveServerProcess.stdout.on("data", (data: Buffer) => {
      const output = data.toString();
      console.log(`new eleventy: ${output}`);

      const urlMatch = output.match(/Server at (https?:\/\/[^\s/]+)/);
      if (urlMatch) {
        const newUrl = urlMatch[1];
        setLiveServerUrl(newUrl);
        console.log(`New website server ready at: ${newUrl}`);
        
        // Auto-load the new website in preview
        setTimeout(() => {
          if (previewWebContentsView) {
            console.log("Loading new website in preview:", newUrl);
            previewWebContentsView.webContents.loadURL(newUrl);
          }
        }, 500);
      }
    });
  }

  if (liveServerProcess.stderr) {
    liveServerProcess.stderr.on("data", (data: Buffer) => {
      console.error(`new eleventy error: ${data}`);
    });
  }

  liveServerProcess.on("close", (code: number) => {
    console.log(`new eleventy process exited with code ${code}`);
  });
}

/**
 * Creates a new website with the given name.
 * @param {BrowserWindow} win - The browser window
 * @param {string} websiteName - The name for the new website
 * @returns {Promise<void>}
 */
async function createWebsiteWithName(win: BrowserWindow, websiteName: string): Promise<void> {
  const { dialog } = await import("electron");
  
  // Validate website name (basic validation)
  if (!websiteName || websiteName.trim() === "" || /[<>:"/\\|?*]/.test(websiteName)) {
    dialog.showErrorBox(
      "Invalid Name",
      "Please enter a valid website name without special characters."
    );
    return;
  }

  try {
    console.log("Creating new website:", websiteName);
    
    // Get the userData directory
    const userDataPath = app.getPath("userData");
    const websitesDir = path.join(userDataPath, "websites");
    const newWebsitePath = path.join(websitesDir, websiteName);

    // Check if website already exists
    if (fs.existsSync(newWebsitePath)) {
      const overwriteResult = await dialog.showMessageBox(win, {
        type: "warning",
        title: "Website Exists",
        message: `A website named "${websiteName}" already exists. Do you want to overwrite it?`,
        buttons: ["Cancel", "Overwrite"],
        defaultId: 0,
        cancelId: 0,
      });

      if (overwriteResult.response === 0) {
        return; // User cancelled
      }
    }

    // Ensure websites directory exists
    if (!fs.existsSync(websitesDir)) {
      fs.mkdirSync(websitesDir, { recursive: true });
    }

    // Copy the template from eleventy/src
    const templatePath = path.join(process.cwd(), "eleventy", "src");
    const { cp } = await import("fs/promises");
    
    await cp(templatePath, newWebsitePath, { recursive: true });

    // Update the index.md with the website name
    const indexPath = path.join(newWebsitePath, "index.md");
    if (fs.existsSync(indexPath)) {
      let content = fs.readFileSync(indexPath, "utf-8");
      // Replace the title in the frontmatter
      content = content.replace(/^title: .*$/m, `title: ${websiteName}`);
      fs.writeFileSync(indexPath, content, "utf-8");
    }

    console.log("New website created at:", newWebsitePath);

    // Switch to the new website for editing
    console.log("Switching to edit the new website");
    await switchToWebsite(win, newWebsitePath);
    
    console.log(`Website "${websiteName}" created and ready for editing`);

  } catch (error) {
    console.error("Failed to create new website:", error);
    dialog.showErrorBox(
      "Creation Failed",
      `Failed to create website: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

/**
 * Sets up IPC main process listeners.
 * @returns {void}
 */
export function setupIpcMainListeners() {
  ipcMain.on("build", () => {
    exec("npm run build", (err, stdout) => {
      if (err) {
        console.error(err);
        return;
      }
      console.log(stdout);
    });
  });

  ipcMain.on("preview", (event) => {
    console.log("Preview requested, current URL:", currentLiveServerUrl);
    console.log("Live server ready:", liveServerReady);

    if (!liveServerReady) {
      console.log("Live server not ready yet, waiting...");
      event.reply(
        "preview-error",
        "Live server is not ready yet. Please wait a moment and try again."
      );
      return;
    }

    const win = BrowserWindow.fromWebContents(event.sender);
    if (win && previewWebContentsView) {
      console.log("Showing WebContentsView and loading URL");

      // WebContentsView is already added to window
      // Add error handling for URL loading (only add listeners once)
      previewWebContentsView.webContents.removeAllListeners("did-fail-load");
      previewWebContentsView.webContents.removeAllListeners("did-finish-load");

      previewWebContentsView.webContents.on(
        "did-fail-load",
        (event, errorCode, errorDescription, validatedURL) => {
          console.error(
            "Failed to load URL:",
            validatedURL,
            "Error:",
            errorCode,
            errorDescription
          );
        }
      );

      previewWebContentsView.webContents.on("did-finish-load", () => {
        console.log(
          "WebContentsView successfully loaded:",
          currentLiveServerUrl
        );
      });

      // Load the site in the WebContentsView
      console.log("Loading URL in WebContentsView:", currentLiveServerUrl);

      // Load the local server content with a small delay
      console.log("MAIN PROCESS: Loading local server content");
      setTimeout(() => {
        console.log(
          "MAIN PROCESS: Actually loading URL now:",
          currentLiveServerUrl
        );
        previewWebContentsView.webContents.loadURL(currentLiveServerUrl);
      }, 100);

      // Position it correctly (accounting for menu bars)
      const bounds = win.getBounds();
      previewWebContentsView.setBounds({
        x: 0,
        y: 90, // Height of both menu bars
        width: bounds.width,
        height: bounds.height - 90,
      });

      event.reply("preview-loaded");
      console.log(
        "MAIN PROCESS: Preview loaded successfully, WebContentsView should be visible now"
      );
    } else {
      console.error("No window or WebContentsView available");
    }
  });

  ipcMain.on("hide-preview", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win && previewWebContentsView) {
      win.contentView.removeChildView(previewWebContentsView);
    }
  });

  ipcMain.on("toggle-devtools", (event) => {
    console.log("DevTools toggle requested");
    if (previewWebContentsView && previewWebContentsView.webContents) {
      console.log("WebContentsView exists, toggling DevTools");
      if (previewWebContentsView.webContents.isDevToolsOpened()) {
        console.log("DevTools open, closing");
        previewWebContentsView.webContents.closeDevTools();
      } else {
        console.log("DevTools closed, opening");
        previewWebContentsView.webContents.openDevTools({ mode: "detach" });
      }
    } else {
      console.log("No WebContentsView or webContents available");
      // If no preview is loaded, load it first then open DevTools
      const win = BrowserWindow.fromWebContents(event.sender);
      if (win && previewWebContentsView) {
        console.log("Loading preview first, then opening DevTools");
        previewWebContentsView.webContents.loadURL(currentLiveServerUrl);

        const bounds = win.getBounds();
        previewWebContentsView.setBounds({
          x: 0,
          y: 90,
          width: bounds.width,
          height: bounds.height - 90,
        });

        // Open DevTools once the page is loaded
        previewWebContentsView.webContents.once("did-finish-load", () => {
          console.log("Preview loaded, opening DevTools");
          previewWebContentsView.webContents.openDevTools({ mode: "detach" });
        });

        event.reply("preview-loaded");
      }
    }
  });

  ipcMain.on("reload-preview", () => {
    if (previewWebContentsView && previewWebContentsView.webContents) {
      previewWebContentsView.webContents.reload();
    }
  });

  ipcMain.on("open-browser", async () => {
    const { shell } = await import("electron");
    shell.openExternal(currentLiveServerUrl);
  });

  ipcMain.on("new-website", async (event) => {
    console.log("DEBUG: Received new-website IPC message");
    const { dialog } = await import("electron");
    const win = BrowserWindow.fromWebContents(event.sender);

    if (!win) {
      console.log("DEBUG: No window found from event.sender");
      return;
    }

    try {
      console.log("DEBUG: Getting website name from user using native approach");
      
      // Use native dialogs for a more integrated experience
      const websiteName = await getNativeInput(win, {
        title: "Create New Website",
        message: "Enter a name for your new website:",
        defaultValue: "My Website"
      });
      
      if (websiteName && websiteName.trim()) {
        console.log("DEBUG: User provided website name:", websiteName);
        await createWebsiteWithName(win, websiteName.trim());
      } else {
        console.log("DEBUG: User cancelled or provided no name");
      }
      
    } catch (error) {
      console.error("DEBUG: Error in new-website handler:", error);
    }
  });

  // Handle the website name submission from the renderer
  ipcMain.on("create-website-with-name", async (event, websiteName: string) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return;
    
    await createWebsiteWithName(win, websiteName);
  });

  ipcMain.on("export-site", async (event) => {
    const { dialog } = await import("electron");
    const win = BrowserWindow.fromWebContents(event.sender);

    if (!win) return;

    // Show save dialog
    const result = await dialog.showSaveDialog(win, {
      title: "Export Site",
      defaultPath: "anglesite-export",
      buttonLabel: "Export",
      properties: ["createDirectory", "showOverwriteConfirmation"],
    });

    if (result.canceled || !result.filePath) {
      return;
    }

    // Build the site
    console.log("Building site for export...");
    exec("npm run build", async (err, stdout) => {
      if (err) {
        console.error("Build failed:", err);
        dialog.showErrorBox(
          "Export Failed",
          `Failed to build site: ${err.message}`
        );
        return;
      }

      console.log("Build output:", stdout);

      // Copy the dist folder to the selected location
      const sourcePath = path.join(process.cwd(), "dist");
      const destPath = result.filePath;

      // Use fs-extra or implement recursive copy
      const { cp } = await import("fs/promises");

      try {
        await cp(sourcePath, destPath, { recursive: true });

        // Show success message
        dialog
          .showMessageBox(win, {
            type: "info",
            title: "Export Complete",
            message: "Site exported successfully!",
            detail: `Your site has been exported to: ${destPath}`,
            buttons: ["OK", "Open Folder"],
          })
          .then((response) => {
            if (response.response === 1) {
              // Open folder in file explorer
              import("electron").then(({ shell }) => {
                shell.showItemInFolder(destPath);
              });
            }
          });
      } catch (copyErr) {
        console.error("Copy failed:", copyErr);
        dialog.showErrorBox(
          "Export Failed",
          `Failed to copy files: ${copyErr}`
        );
      }
    });
  });

  // Debug listener to confirm renderer is loaded
  ipcMain.on("renderer-loaded", (event, message) => {
    console.log("DEBUG: Renderer loaded successfully:", message);
  });
}

/**
 * Creates the application menu.
 * @returns {void}
 */
function createApplicationMenu() {
  const template: Electron.MenuItemConstructorOptions[] = [
    {
      label: "Anglesite",
      submenu: [
        {
          label: "About Anglesite",
          role: "about",
        },
        {
          type: "separator",
        },
        {
          label: "Hide Anglesite",
          accelerator: "Command+H",
          role: "hide",
        },
        {
          label: "Hide Others",
          accelerator: "Command+Shift+H",
          role: "hideOthers",
        },
        {
          label: "Show All",
          role: "unhide",
        },
        {
          type: "separator",
        },
        {
          label: "Quit Anglesite",
          accelerator: "Command+Q",
          role: "quit",
        },
      ],
    },
    {
      label: "File",
      submenu: [
        {
          label: "New Website",
          accelerator: "Command+N",
          click: () => {
            console.log("DEBUG: New Website menu clicked");
            const focusedWindow = BrowserWindow.getFocusedWindow();
            console.log("DEBUG: Focused window:", !!focusedWindow);
            if (focusedWindow) {
              console.log("DEBUG: Sending menu-new-website to focused window");
              focusedWindow.webContents.send("menu-new-website");
            } else {
              console.log("DEBUG: No focused window, trying all windows");
              const allWindows = BrowserWindow.getAllWindows();
              console.log("DEBUG: All windows count:", allWindows.length);
              if (allWindows.length > 0) {
                console.log("DEBUG: Sending menu-new-website to first window");
                allWindows[0].webContents.send("menu-new-website");
              }
            }
          },
        },
        {
          type: "separator",
        },
        {
          label: "Export Site...",
          accelerator: "Command+E",
          click: () => {
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.webContents.send("menu-export-site");
            }
          },
        },
      ],
    },
    {
      label: "View",
      submenu: [
        {
          label: "Reload",
          accelerator: "Command+R",
          click: () => {
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.webContents.send("menu-reload");
            }
          },
        },
        {
          label: "Toggle DevTools",
          accelerator: "Command+Option+I",
          click: () => {
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.webContents.send("menu-toggle-devtools");
            }
          },
        },
        {
          type: "separator",
        },
        {
          label: "Actual Size",
          accelerator: "Command+0",
          role: "resetZoom",
        },
        {
          label: "Zoom In",
          accelerator: "Command+Plus",
          role: "zoomIn",
        },
        {
          label: "Zoom Out",
          accelerator: "Command+-",
          role: "zoomOut",
        },
      ],
    },
    {
      label: "Window",
      submenu: [
        {
          label: "Minimize",
          accelerator: "Command+M",
          role: "minimize",
        },
        {
          label: "Close",
          accelerator: "Command+W",
          role: "close",
        },
      ],
    },
  ];

  // On Windows and Linux, adjust the menu template
  if (process.platform !== "darwin") {
    template.shift(); // Remove the first menu (app menu) on non-macOS
  }

  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(menu);
}

app.whenReady().then(() => {
  // Set the application metadata
  app.setAppUserModelId("io.dwk.anglesite.app");

  // Create the custom menu
  createApplicationMenu();

  createWindow();
  setupIpcMainListeners();

  /**
   * Event handler for when the app is activated (e.g., clicking on the dock icon).
   * @returns {void}
   */
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

/**
 * Clean up live-server process.
 * @returns {void}
 */
function cleanupLiveServer() {
  if (liveServerProcess) {
    console.log("Cleaning up Eleventy server process");
    try {
      liveServerProcess.kill("SIGTERM");
    } catch (error) {
      console.warn("Failed to kill Eleventy server process:", error);
    }
    // Don't set to null to allow tests to verify the kill was called
  }
}

/**
 * Event handler for when all windows are closed.
 * @returns {void}
 */
app.on("window-all-closed", () => {
  cleanupLiveServer();
  if (process.platform !== "darwin") {
    app.quit();
  }
});

/**
 * Event handler for when the app is about to quit.
 * @returns {void}
 */
app.on("before-quit", () => {
  cleanupLiveServer();
});

/**
 * Event handler for when the process receives termination signals.
 * @returns {void}
 */
process.on("SIGINT", () => {
  console.log("Received SIGINT, cleaning up...");
  cleanupLiveServer();
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("Received SIGTERM, cleaning up...");
  cleanupLiveServer();
  process.exit(0);
});
