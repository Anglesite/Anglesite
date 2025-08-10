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
 * Open Website Selection window
 */
export function openWebsiteSelectionWindow(): void {
  const websiteSelectionWindow = new BrowserWindow({
    width: 600,
    height: 500,
    title: "Open Website",
    resizable: true,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    titleBarStyle: "hiddenInset",
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  const htmlFilePath = path.join(
    __dirname,
    "..",
    "ui",
    "website-selection.html"
  );

  // Check if file exists, create fallback if not
  if (fs.existsSync(htmlFilePath)) {
    websiteSelectionWindow.loadFile(htmlFilePath);
  } else {
    const websiteSelectionHTML = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Open Website</title>
  <style>
    body { 
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
      margin: 0; 
      padding: 20px 20px 10px 20px; 
      background: #f5f5f5; 
    }
    .header {
      text-align: center;
      margin-bottom: 30px;
    }
    .title {
      font-size: 24px;
      font-weight: 600;
      color: #333;
      margin-bottom: 8px;
    }
    .subtitle {
      font-size: 14px;
      color: #666;
    }
    .websites-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      gap: 20px;
      margin-bottom: 30px;
    }
    .website-card {
      background: white;
      border-radius: 12px;
      padding: 20px;
      text-align: center;
      cursor: pointer;
      transition: all 0.2s ease;
      border: 1px solid #e1e1e1;
    }
    .website-card:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 25px rgba(0,0,0,0.1);
      border-color: #007AFF;
    }
    .website-icon {
      font-size: 48px;
      margin-bottom: 15px;
    }
    .website-name {
      font-size: 16px;
      font-weight: 500;
      color: #333;
      margin-bottom: 5px;
    }
    .website-name.editing {
      background: white;
      border: 2px solid #007AFF;
      border-radius: 4px;
      padding: 4px 8px;
      margin: -4px -8px 5px -8px;
      outline: none;
      box-shadow: 0 0 0 3px rgba(0, 122, 255, 0.1);
    }
    .website-name.editing.error {
      border-color: #FF3B30;
      box-shadow: 0 0 0 3px rgba(255, 59, 48, 0.1);
    }
    .validation-error {
      font-size: 12px;
      color: #FF3B30;
      margin-top: 5px;
      display: none;
    }
    .validation-error.show {
      display: block;
    }
    .website-path {
      font-size: 12px;
      color: #666;
      word-break: break-all;
    }
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: #666;
    }
    .empty-icon {
      font-size: 64px;
      margin-bottom: 20px;
    }
    .buttons {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-top: 20px;
      border-top: 1px solid #e1e1e1;
    }
    .buttons-left {
      flex: 1;
    }
    .buttons-right {
      flex: 0;
    }
    button {
      background: #e5e5e7;
      color: #333;
      border: none;
      padding: 10px 24px;
      border-radius: 6px;
      font-size: 14px;
      cursor: pointer;
      margin: 0 8px;
    }
    button:hover {
      background: #d1d1d6;
    }
    button.primary {
      background: #007AFF;
      color: white;
    }
    button.primary:hover {
      background: #0056CC;
    }
  </style>
</head>
<body>
  <div class="header">
    <div class="title">Open Website</div>
    <div class="subtitle">Select a website to open</div>
  </div>
  
  <div id="websitesContainer">
    <div class="empty-state">
      <div class="empty-icon">🌐</div>
      <div>Loading websites...</div>
    </div>
  </div>
  
  <div class="buttons">
    <div class="buttons-left">
      <button class="primary" onclick="createNewWebsite()">New</button>
    </div>
    <div class="buttons-right">
      <button onclick="window.close()">Cancel</button>
    </div>
  </div>
  
  <script>
    const { ipcRenderer } = require('electron');
    
    // Load websites when page loads
    document.addEventListener('DOMContentLoaded', () => {
      loadWebsites();
    });
    
    async function loadWebsites() {
      try {
        const websites = await ipcRenderer.invoke('list-websites');
        displayWebsites(websites);
      } catch (error) {
        console.error('Failed to load websites:', error);
        displayError();
      }
    }
    
    function displayWebsites(websites) {
      const container = document.getElementById('websitesContainer');
      
      if (websites.length === 0) {
        container.innerHTML = '<div class="empty-state"><div class="empty-icon">📁</div><div>No websites found</div><div style="font-size: 12px; margin-top: 8px;">Create a new website to get started</div></div>';
        return;
      }
      
      container.innerHTML = '<div class="websites-grid">' + 
        websites.map(website => \`
          <div class="website-card" onclick="openWebsite('\${website}')" oncontextmenu="showContextMenu(event, '\${website}')">
            <div class="website-icon">🌐</div>
            <div class="website-name" contenteditable="false" data-original="\${website}">\${website}</div>
            <div class="validation-error"></div>
            <div class="website-path">\${website}</div>
          </div>
        \`).join('') + 
        '</div>';
    }
    
    function displayError() {
      const container = document.getElementById('websitesContainer');
      container.innerHTML = '<div class="empty-state"><div class="empty-icon">⚠️</div><div>Failed to load websites</div></div>';
    }
    
    function openWebsite(websiteName) {
      ipcRenderer.send('open-website', websiteName);
      window.close();
    }
    
    function createNewWebsite() {
      ipcRenderer.send('new-website');
      window.close();
    }
    
    function showContextMenu(event, websiteName) {
      event.preventDefault();
      event.stopPropagation();
      
      // Let Electron handle the positioning automatically by just sending the request
      // The main process will show the context menu at the current mouse position
      ipcRenderer.send('show-website-context-menu', websiteName, {
        x: 0, // These will be ignored when using window-based positioning
        y: 0
      });
    }
    
    // Listen for context menu actions
    ipcRenderer.on('website-context-menu-action', (event, action, websiteName) => {
      if (action === 'rename') {
        startInlineEdit(websiteName);
      } else if (action === 'delete') {
        // Send delete request directly - the backend will handle confirmation
        ipcRenderer.send('delete-website', websiteName);
      }
    });
    
    // Listen for website operations completed to refresh the list
    ipcRenderer.on('website-operation-completed', () => {
      loadWebsites(); // Refresh the website list
    });
    
    let currentlyEditing = null;
    
    function startInlineEdit(websiteName) {
      // If another element is being edited, cancel it first
      if (currentlyEditing) {
        cancelInlineEdit();
      }
      
      // Find the website name element
      const nameElements = document.querySelectorAll('.website-name');
      const nameElement = Array.from(nameElements).find(el => el.textContent.trim() === websiteName);
      
      if (!nameElement) return;
      
      // Store reference and original value
      currentlyEditing = nameElement;
      const originalName = nameElement.getAttribute('data-original');
      
      // Make it editable and focused
      nameElement.contentEditable = 'true';
      nameElement.classList.add('editing');
      nameElement.focus();
      
      // Select all text
      const range = document.createRange();
      range.selectNodeContents(nameElement);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      
      // Add event listeners
      nameElement.addEventListener('blur', handleBlur);
      nameElement.addEventListener('keydown', handleKeydown);
      nameElement.addEventListener('input', handleInput);
    }
    
    function handleBlur(event) {
      if (!currentlyEditing) return;
      
      const newName = currentlyEditing.textContent.trim();
      const originalName = currentlyEditing.getAttribute('data-original');
      
      if (newName && newName !== originalName) {
        // Attempt to save the rename
        saveRename(originalName, newName);
      } else {
        // Cancel if empty or unchanged
        cancelInlineEdit();
      }
    }
    
    function handleKeydown(event) {
      if (!currentlyEditing) return;
      
      if (event.key === 'Escape') {
        event.preventDefault();
        cancelInlineEdit();
      } else if (event.key === 'Enter') {
        event.preventDefault();
        currentlyEditing.blur(); // This will trigger handleBlur
      }
    }
    
    function handleInput(event) {
      if (!currentlyEditing) return;
      
      const newName = currentlyEditing.textContent.trim();
      validateNameInRealTime(newName);
    }
    
    async function validateNameInRealTime(name) {
      if (!currentlyEditing) return;
      
      const errorElement = currentlyEditing.parentElement.querySelector('.validation-error');
      
      try {
        const validation = await ipcRenderer.invoke('validate-website-name', name);
        
        if (validation.valid) {
          currentlyEditing.classList.remove('error');
          errorElement.classList.remove('show');
          errorElement.textContent = '';
        } else {
          currentlyEditing.classList.add('error');
          errorElement.classList.add('show');
          errorElement.textContent = validation.error || 'Invalid name';
        }
      } catch (error) {
        console.error('Validation error:', error);
        currentlyEditing.classList.add('error');
        errorElement.classList.add('show');
        errorElement.textContent = 'Validation failed';
      }
    }
    
    async function saveRename(oldName, newName) {
      if (!currentlyEditing) return;
      
      try {
        await ipcRenderer.invoke('rename-website', oldName, newName);
        // Success - the website list will refresh automatically via the operation-completed event
        cleanupInlineEdit();
      } catch (error) {
        console.error('Rename failed:', error);
        
        // Show error and keep editing mode
        const errorElement = currentlyEditing.parentElement.querySelector('.validation-error');
        errorElement.classList.add('show');
        errorElement.textContent = error.message || 'Rename failed';
        currentlyEditing.classList.add('error');
        
        // Keep focus for user to try again
        currentlyEditing.focus();
      }
    }
    
    function cancelInlineEdit() {
      if (!currentlyEditing) return;
      
      // Restore original name
      const originalName = currentlyEditing.getAttribute('data-original');
      currentlyEditing.textContent = originalName;
      
      cleanupInlineEdit();
    }
    
    function cleanupInlineEdit() {
      if (!currentlyEditing) return;
      
      // Remove editing state
      currentlyEditing.contentEditable = 'false';
      currentlyEditing.classList.remove('editing', 'error');
      
      // Clear error message
      const errorElement = currentlyEditing.parentElement.querySelector('.validation-error');
      errorElement.classList.remove('show');
      errorElement.textContent = '';
      
      // Remove event listeners
      currentlyEditing.removeEventListener('blur', handleBlur);
      currentlyEditing.removeEventListener('keydown', handleKeydown);
      currentlyEditing.removeEventListener('input', handleInput);
      
      currentlyEditing = null;
    }
  </script>
</body>
</html>`;

    websiteSelectionWindow.loadURL(
      `data:text/html;charset=utf-8,${encodeURIComponent(websiteSelectionHTML)}`
    );
  }
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
