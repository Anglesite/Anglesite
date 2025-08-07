/**
 * @file Main process of the Electron application.
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/quick-start}
 */
import { app, BrowserWindow, ipcMain } from "electron";
import * as path from "path";
import { exec, spawn, ChildProcess } from "child_process";

/**
 * Live server process instance.
 * @type {ChildProcess}
 */
export let liveServerProcess: ChildProcess;

/**
 * Creates the main Electron browser window.
 * @returns {void}
 */
export function createWindow() {
  const win = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  // Start live-server and load its URL
  liveServerProcess = spawn(
    "npx",
    ["live-server", "dist", "--port=8080", "--no-browser"],
    {
      cwd: process.cwd(),
      shell: true,
    }
  );

  if (liveServerProcess.stdout) {
    liveServerProcess.stdout.on("data", (data: Buffer) => {
      console.log(`live-server: ${data}`);
      if (data.includes("Serving ")) {
        win.loadURL("http://127.0.0.1:8080");
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
}

app.whenReady().then(() => {
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
 * Event handler for when all windows are closed.
 * @returns {void}
 */
app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
  if (liveServerProcess) {
    liveServerProcess.kill(); // Terminate live-server when app closes
  }
});
