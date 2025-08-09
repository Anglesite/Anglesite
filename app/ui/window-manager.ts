/**
 * @file Window and WebContentsView management
 */
import { BrowserWindow, WebContentsView, ipcMain } from "electron";
import * as path from "path";
import * as fs from "fs";
import { getCurrentLiveServerUrl, isLiveServerReady } from "../server/eleventy";

let previewWebContentsView: WebContentsView | null = null;
let settingsWindow: BrowserWindow | null = null;

/**
 * Create the main application window
 */
export function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, "..", "preload.js"),
    },
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 20, y: 20 },
  });

  win.loadFile(path.join(__dirname, "..", "index.html"));

  // Create preview WebContentsView
  createPreviewWebContentsView();

  // Handle window resize to reposition WebContentsView
  win.on("resize", () => {
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
 * Create preview WebContentsView for displaying live content
 */
function createPreviewWebContentsView(): void {
  previewWebContentsView = new WebContentsView({
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Add error handling
  previewWebContentsView.webContents.on(
    "render-process-gone",
    (_event, details) => {
      console.error("WebContentsView render process gone:", details);
      setTimeout(() => {
        try {
          previewWebContentsView?.webContents.reload();
        } catch (error) {
          console.error("Failed to reload WebContentsView:", error);
        }
      }, 1000);
    }
  );

  previewWebContentsView.webContents.on("unresponsive", () => {
    console.error("WebContentsView webContents unresponsive");
  });

  previewWebContentsView.webContents.on(
    "did-fail-load",
    (_event, errorCode, errorDescription, validatedURL) => {
      console.error("WebContentsView failed to load:", {
        errorCode,
        errorDescription,
        validatedURL,
      });
    }
  );

  console.log("WebContentsView created and ready to display content");
}

/**
 * Auto-load preview when server is ready
 */
export function autoLoadPreview(win: BrowserWindow): void {
  if (win && previewWebContentsView && isLiveServerReady()) {
    const currentUrl = getCurrentLiveServerUrl();
    console.log("Auto-loading preview with URL:", currentUrl);

    // Remove existing listeners to avoid duplicates
    previewWebContentsView.webContents.removeAllListeners("did-fail-load");
    previewWebContentsView.webContents.removeAllListeners("did-finish-load");

    previewWebContentsView.webContents.on(
      "did-fail-load",
      (_event, errorCode, errorDescription, validatedURL) => {
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
      console.log("Auto-loaded preview successfully:", currentUrl);
    });

    // Load the current live server URL
    setTimeout(() => {
      const serverUrl = getCurrentLiveServerUrl();
      console.log("Auto-loading URL now:", serverUrl);

      previewWebContentsView?.webContents.loadURL(serverUrl).catch((error) => {
        console.error("Failed to load server URL:", error);

        // Show fallback HTML
        const fallbackHTML = `
          <!DOCTYPE html>
          <html>
            <head><title>Anglesite Preview</title></head>
            <body style="font-family: system-ui; padding: 20px; text-align: center;">
              <h1>🌐 Anglesite</h1>
              <p>Preview area - waiting for content</p>
              <p><small>The server is running at <a href="http://localhost:8081" target="_blank">http://localhost:8081</a></small></p>
            </body>
          </html>
        `;
        previewWebContentsView?.webContents.loadURL(
          `data:text/html;charset=utf-8,${encodeURIComponent(fallbackHTML)}`
        );
      });
    }, 100);

    // Add WebContentsView to window if not already added
    if (!win.contentView.children.includes(previewWebContentsView)) {
      win.contentView.addChildView(previewWebContentsView);
      console.log("WebContentsView added to window");
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
    win.webContents.send("preview-loaded");
    console.log("Auto-preview loaded successfully");
  }
}

/**
 * Load local file preview as fallback
 */
export function loadLocalFilePreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    const distPath = path.resolve(process.cwd(), "dist");
    const indexFile = path.join(distPath, "index.html");
    const fileUrl = `file://${indexFile}`;

    console.log("Loading local file preview:", fileUrl);

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
 * Show preview in WebContentsView
 */
export function showPreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    console.log("Showing WebContentsView and loading URL");

    // Add WebContentsView to window if not already added
    if (!win.contentView.children.includes(previewWebContentsView)) {
      win.contentView.addChildView(previewWebContentsView);
    }

    // Remove existing listeners
    previewWebContentsView.webContents.removeAllListeners("did-fail-load");
    previewWebContentsView.webContents.removeAllListeners("did-finish-load");

    previewWebContentsView.webContents.on(
      "did-fail-load",
      (_event, errorCode, errorDescription, validatedURL) => {
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
      const serverUrl = getCurrentLiveServerUrl();
      console.log("WebContentsView successfully loaded:", serverUrl);
    });

    // Load current server URL directly
    const serverUrl = getCurrentLiveServerUrl();
    setTimeout(() => {
      console.log("MAIN PROCESS: Actually loading URL now:", serverUrl);
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

    win.webContents.send("preview-loaded");
  }
}

/**
 * Hide preview WebContentsView
 */
export function hidePreview(win: BrowserWindow): void {
  if (win && previewWebContentsView) {
    win.contentView.removeChildView(previewWebContentsView);
  }
}

/**
 * Reload preview content
 */
export function reloadPreview(): void {
  if (previewWebContentsView) {
    previewWebContentsView.webContents.reload();
  }
}

/**
 * Toggle DevTools for preview
 */
export function togglePreviewDevTools(): void {
  if (previewWebContentsView?.webContents) {
    if (previewWebContentsView.webContents.isDevToolsOpened()) {
      previewWebContentsView.webContents.closeDevTools();
    } else {
      previewWebContentsView.webContents.openDevTools();
    }
  }
}

/**
 * Get native input from user
 */
export async function getNativeInput(
  title: string,
  prompt: string
): Promise<string | null> {
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
      webPreferences: {
        nodeIntegration: true,
        contextIsolation: false,
      },
    });

    const inputHTML = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>${title}</title>
  <style>
    body { 
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
      margin: 0; padding: 20px; background: #f5f5f5; 
    }
    .container { 
      background: white; border-radius: 8px; padding: 20px; 
      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    }
    .prompt { margin-bottom: 15px; color: #333; font-size: 14px; }
    input { 
      width: 100%; padding: 8px 12px; border: 1px solid #ddd; 
      border-radius: 6px; font-size: 14px; margin-bottom: 20px;
      box-sizing: border-box;
    }
    .buttons { text-align: right; }
    button { 
      background: #007AFF; color: white; border: none; 
      padding: 8px 20px; border-radius: 6px; font-size: 13px; 
      cursor: pointer; margin-left: 8px; 
    }
    button:hover { background: #0056CC; }
    button.secondary { background: #e5e5e7; color: #333; }
    button.secondary:hover { background: #d1d1d6; }
  </style>
</head>
<body>
  <div class="container">
    <div class="prompt">${prompt}</div>
    <input type="text" id="userInput" placeholder="Enter website name..." autofocus>
    <div class="buttons">
      <button class="secondary" onclick="cancel()">Cancel</button>
      <button onclick="submit()">OK</button>
    </div>
  </div>
  <script>
    const { ipcRenderer } = require('electron');
    
    function cancel() {
      ipcRenderer.send('input-dialog-result', null);
    }
    
    function submit() {
      const value = document.getElementById('userInput').value.trim();
      ipcRenderer.send('input-dialog-result', value || null);
    }
    
    document.getElementById('userInput').addEventListener('keypress', function(e) {
      if (e.key === 'Enter') submit();
      if (e.key === 'Escape') cancel();
    });
  </script>
</body>
</html>`;

    inputWindow.loadURL(
      `data:text/html;charset=utf-8,${encodeURIComponent(inputHTML)}`
    );

    // Handle input result
    const handleInputResult = (result: string | null) => {
      inputWindow.close();
      resolve(result);
    };

    // Handle window close
    inputWindow.on("closed", () => {
      resolve(null);
    });

    // Set up IPC listener for the result
    const handleResult = (_event: unknown, result: string | null) => {
      ipcMain.removeListener("input-dialog-result", handleResult);
      handleInputResult(result);
    };
    ipcMain.on("input-dialog-result", handleResult);
  });
}

/**
 * Show first launch setup assistant for HTTPS/HTTP mode selection
 * Displays a modal dialog allowing users to choose between HTTPS (with CA installation)
 * or HTTP (simple) mode for local development
 * @returns Promise resolving to "https", "http", or null if cancelled
 */
export async function showFirstLaunchAssistant(): Promise<
  "https" | "http" | null
> {
  return new Promise((resolve) => {
    const assistantWindow = new BrowserWindow({
      width: 520,
      height: 480,
      title: "Welcome to Anglesite",
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      modal: true,
      titleBarStyle: "hiddenInset",
      webPreferences: {
        nodeIntegration: true,
        contextIsolation: false,
      },
    });

    // Load the HTML file
    const htmlFilePath = path.join(__dirname, "..", "ui", "first-launch.html");
    console.log("Loading first launch HTML from:", htmlFilePath);

    // Check if file exists
    if (fs.existsSync(htmlFilePath)) {
      assistantWindow.loadFile(htmlFilePath);
    } else {
      console.error("First launch HTML file not found at:", htmlFilePath);
      // Fall back to a simple HTML
      assistantWindow.loadURL(
        `data:text/html;charset=utf-8,${encodeURIComponent(`
          <!DOCTYPE html>
          <html>
            <head><title>Welcome to Anglesite</title></head>
            <body style="font-family: system-ui; padding: 20px; text-align: center;">
              <h1>💎 Welcome to Anglesite</h1>
              <p>Setup assistant loading...</p>
            </body>
          </html>
        `)}`
      );
    }

    // Handle window close
    assistantWindow.on("closed", () => {
      resolve(null);
    });

    // Set up IPC listener for the result
    const handleResult = (_event: unknown, result: "https" | "http" | null) => {
      ipcMain.removeListener("first-launch-result", handleResult);
      assistantWindow.close();
      resolve(result);
    };
    ipcMain.on("first-launch-result", handleResult);
  });
}

/**
 * Open Settings window
 */
export function openSettingsWindow(): void {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 500,
    height: 300,
    title: "Settings",
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    titleBarStyle: "default",
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, "..", "preload.js"),
    },
  });

  const settingsHTML = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Settings</title>
  <style>
    body { font-family: system-ui; margin: 0; padding: 20px; background: #f5f5f5; }
    .setting-group { background: white; border-radius: 6px; padding: 20px; margin-bottom: 16px; }
    .setting-title { font-size: 13px; font-weight: 600; margin-bottom: 8px; }
    .setting-description { font-size: 11px; color: #666; margin-bottom: 16px; line-height: 1.4; }
    label { display: flex; align-items: center; cursor: pointer; }
    input[type="checkbox"] { margin-right: 8px; }
    .buttons { text-align: right; margin-top: 20px; }
    button { background: #007AFF; color: white; border: none; padding: 8px 20px; border-radius: 6px; font-size: 13px; cursor: pointer; margin-left: 8px; }
    button:hover { background: #0056CC; }
    button.secondary { background: #e5e5e7; color: #333; }
    button.secondary:hover { background: #d1d1d6; }
  </style>
</head>
<body>
  <div class="setting-group">
    <div class="setting-title">Development Domains</div>
    <div class="setting-description">
      When enabled, Anglesite will automatically configure *.test wildcard domains.
    </div>
    <label>
      <input type="checkbox" id="autoDomains" checked>
      <span>Automatically configure .test domains</span>
    </label>
  </div>
  <div class="buttons">
    <button class="secondary" onclick="window.close()">Cancel</button>
    <button onclick="saveSettings()">Save Settings</button>
  </div>
  <script>
    function saveSettings() {
      const autoDomains = document.getElementById('autoDomains').checked;
      // TODO: Save to store
      window.close();
    }
  </script>
</body>
</html>`;

  settingsWindow.loadURL(
    `data:text/html;charset=utf-8,${encodeURIComponent(settingsHTML)}`
  );
}
