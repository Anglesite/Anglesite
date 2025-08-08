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

  // Start live-server for the site preview (HTTP for now)
  liveServerProcess = spawn(
    "npx",
    ["live-server", "dist", "--port=8080", "--no-browser"],
    {
      cwd: process.cwd(),
      shell: true,
    }
  );

  let liveServerUrl = "";

  if (liveServerProcess.stdout) {
    liveServerProcess.stdout.on("data", (data: Buffer) => {
      const output = data.toString();
      console.log(`live-server: ${output}`);

      // Extract the URL from live-server output
      const urlMatch = output.match(/Serving ".*?" at (https?:\/\/[^\s]+)/);
      if (urlMatch) {
        // Clean the URL by taking only the valid URL part
        const rawUrl = urlMatch[1];
        // Find where the actual URL ends (before any color codes)
        // First split by whitespace to get the URL part
        const urlPart = rawUrl.split(/\s/)[0];
        // Then check for ANSI escape sequences
        const escIndex = urlPart.indexOf("\u001b"); // ESC character
        liveServerUrl =
          escIndex > -1 ? urlPart.substring(0, escIndex) : urlPart;
        setLiveServerUrl(liveServerUrl);
        liveServerReady = true;
        console.log(`Live server URL detected: ${liveServerUrl}`);
        console.log("Live server is ready");

        // Auto-load the preview once live-server is ready
        autoLoadPreview(win);
      }
    });
  }

  if (liveServerProcess.stderr) {
    liveServerProcess.stderr.on("data", (data: Buffer) => {
      console.error(`live-server error: ${data}`);
    });
  }

  liveServerProcess.on("close", (code: number) => {
    console.log(`live-server process exited with code ${code}`);
  });
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

  ipcMain.on("new-website", async () => {
    const { dialog } = await import("electron");
    dialog.showMessageBox({
      type: "info",
      title: "New Website",
      message:
        "New website functionality will be implemented in a future version.",
    });
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
            const focusedWindow = BrowserWindow.getFocusedWindow();
            if (focusedWindow) {
              focusedWindow.webContents.send("menu-new-website");
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
    console.log("Cleaning up live-server process");
    try {
      liveServerProcess.kill("SIGTERM");
    } catch (error) {
      console.warn("Failed to kill live-server process:", error);
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
