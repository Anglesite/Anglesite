/**
 * @file IPC message handlers
 */
import { ipcMain, BrowserWindow, shell, dialog } from "electron";
import { exec } from "child_process";
import {
  showPreview,
  hidePreview,
  reloadPreview,
  togglePreviewDevTools,
  getNativeInput,
  autoLoadPreview,
} from "../ui/window-manager";
import {
  getCurrentLiveServerUrl,
  isLiveServerReady,
  switchToWebsite,
} from "../server/eleventy";
import {
  createWebsiteWithName,
  validateWebsiteName,
} from "../utils/website-manager";
import { addLocalDnsResolution } from "../dns/hosts-manager";
import { restartHttpsProxy } from "../server/https-proxy";
import { Store } from "../store";

/**
 * Setup all IPC message listeners
 */
export function setupIpcMainListeners(): void {
  // Build command handler
  ipcMain.on("build", () => {
    exec("npm run build", (err, stdout) => {
      if (err) {
        console.error(err);
        return;
      }
      console.log(stdout);
    });
  });

  // Preview handlers
  ipcMain.on("preview", (event) => {
    const serverUrl = getCurrentLiveServerUrl();
    console.log("Preview requested, using server URL:", serverUrl);
    console.log("Live server ready:", isLiveServerReady());

    if (!isLiveServerReady()) {
      console.log("Live server not ready yet, waiting...");
      event.reply(
        "preview-error",
        "Live server is not ready yet. Please wait a moment and try again."
      );
      return;
    }

    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      showPreview(win);
    }
  });

  ipcMain.on("hide-preview", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      hidePreview(win);
    }
  });

  ipcMain.on("toggle-devtools", () => {
    console.log("DevTools toggle requested");
    togglePreviewDevTools();
  });

  ipcMain.on("reload-preview", () => {
    reloadPreview();
  });

  // Browser handlers
  ipcMain.on("open-browser", async () => {
    try {
      await shell.openExternal(getCurrentLiveServerUrl());
    } catch {
      console.log("Failed to open .test domain, trying localhost");
      const localhostUrl = getCurrentLiveServerUrl().replace(
        /https:\/\/[^.]+\.test:/,
        "https://localhost:"
      );
      try {
        await shell.openExternal(localhostUrl);
      } catch (fallbackError) {
        console.error("Failed to open in browser:", fallbackError);
      }
    }
  });

  // Website creation handler
  ipcMain.on("new-website", async (event) => {
    console.log("DEBUG: Received new-website IPC message");

    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) {
      console.error("No window found for new-website IPC message");
      return;
    }

    try {
      let websiteName: string | null = null;
      let validationError = "";

      // Keep asking until user provides valid name or cancels
      do {
        console.log(
          "DEBUG: Getting website name from user using native approach"
        );

        let prompt = "Enter a name for your new website:";
        if (validationError) {
          prompt = `${validationError}\n\nPlease enter a valid website name:`;
        }

        websiteName = await getNativeInput("New Website", prompt);

        if (!websiteName) {
          console.log("DEBUG: User cancelled website creation");
          return;
        }

        console.log("DEBUG: User provided website name:", websiteName);

        // Validate website name
        const validation = validateWebsiteName(websiteName);
        if (!validation.valid) {
          validationError = validation.error || "Invalid website name";
          websiteName = null; // Reset to continue the loop
        } else {
          validationError = ""; // Clear any previous error
        }
      } while (!websiteName);

      await createNewWebsite(win, websiteName);
    } catch (error) {
      console.error("Failed to create new website:", error);
      dialog.showMessageBox(win, {
        type: "error",
        title: "Creation Failed",
        message: "Failed to create website",
        detail: error instanceof Error ? error.message : String(error),
        buttons: ["OK"],
      });
    }
  });

  // Development tools
  ipcMain.on("clear-cache", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) {
      win.webContents.session.clearCache();
      console.log("Cache cleared");
    }
  });

  // File operations
  ipcMain.on("show-item-in-folder", async (event, filePath: string) => {
    if (filePath) {
      shell.showItemInFolder(filePath);
    }
  });
}

/**
 * Create a new website with the given name
 */
async function createNewWebsite(
  win: BrowserWindow,
  websiteName: string
): Promise<void> {
  console.log("Creating new website:", websiteName);

  try {
    // Create the website files
    const newWebsitePath = await createWebsiteWithName(websiteName);
    console.log("New website created at:", newWebsitePath);

    // Switch to edit the new website
    console.log("Switching to edit the new website");
    console.log(
      "DEBUG: About to call switchToWebsite with path:",
      newWebsitePath
    );

    await switchToWebsite(newWebsitePath);
    console.log("DEBUG: switchToWebsite completed");

    // Refresh the preview to show the new website
    autoLoadPreview(win);
    console.log("DEBUG: autoLoadPreview called for new website");

    // Generate test domain and setup DNS
    const testDomain = `https://${websiteName}.test:8080`;
    const hostname = `${websiteName}.test`;

    console.log("DEBUG: websitePath for new domain:", newWebsitePath);
    console.log("DEBUG: extracted websiteName:", websiteName);
    console.log("DEBUG: generated newTestDomain:", testDomain);

    // Setup DNS resolution
    await addLocalDnsResolution(hostname);

    // Check user's HTTPS preference
    const store = new Store();
    const httpsMode = store.get("httpsMode");

    if (httpsMode === "https") {
      // Restart HTTPS proxy for the new domain
      const httpsSuccess = await restartHttpsProxy(8080, 8081, hostname);
      if (httpsSuccess) {
        console.log(`New website HTTPS server ready at: ${testDomain}`);
      } else {
        console.log("HTTPS proxy failed, continuing with HTTP-only mode");
      }
    } else {
      console.log("HTTP-only mode by user preference, skipping HTTPS proxy");
    }

    console.log(`Website "${websiteName}" created and ready for editing`);
  } catch (error) {
    console.error("Failed to create new website:", error);
    throw error;
  }
}
