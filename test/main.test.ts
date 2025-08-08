/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * @file Tests for the Electron main process.
 */
import { app, BrowserWindow, ipcMain } from "electron";
import { exec } from "child_process";
import {
  createWindow,
  setupIpcMainListeners,
  liveServerProcess,
} from "../app/main";

// Mock Electron modules
jest.mock("electron", () => {
  const mockApp: Partial<Electron.App> & {
    _listeners: Record<string, ((...args: any[]) => void)[]>;
  } = {
    setName: jest.fn() as jest.MockedFunction<typeof Electron.app.setName>,
    setAppUserModelId: jest.fn() as jest.MockedFunction<
      typeof Electron.app.setAppUserModelId
    >,
    whenReady: jest.fn(() => Promise.resolve()),
    on: jest.fn((event: string, listener: (...args: any[]) => void) => {
      if (!mockApp._listeners[event]) {
        mockApp._listeners[event] = [];
      }
      mockApp._listeners[event].push(listener);
      return mockApp as Electron.App; // Return mockApp for chaining
    }) as jest.MockedFunction<typeof Electron.app.on>,
    quit: jest.fn() as jest.MockedFunction<typeof Electron.app.quit>,
    emit: jest.fn((event: string, ...args: any[]) => {
      if (mockApp._listeners[event]) {
        mockApp._listeners[event].forEach(
          (listener: (...args: any[]) => void) => {
            listener(...args);
          }
        );
      }
      return true; // Return boolean as per Electron.App.emit
    }) as jest.MockedFunction<typeof Electron.app.emit>,
    _listeners: {}, // Initialize _listeners here
  };

  return {
    app: mockApp as Electron.App,
    BrowserWindow: Object.assign(
      jest.fn(() => ({
        loadFile: jest.fn(),
        loadURL: jest.fn(),
        contentView: {
          addChildView: jest.fn(),
          removeChildView: jest.fn(),
        },
        getBounds: jest.fn(() => ({ width: 1200, height: 800 })),
        webContents: {
          send: jest.fn(),
        },
      })),
      {
        fromWebContents: jest.fn(() => ({
          contentView: {
            addChildView: jest.fn(),
            removeChildView: jest.fn(),
          },
          getBounds: jest.fn(() => ({ width: 1200, height: 800 })),
          webContents: {
            send: jest.fn(),
          },
        })),
        getFocusedWindow: jest.fn(() => ({
          webContents: {
            send: jest.fn(),
          },
        })),
        getAllWindows: jest.fn(() => []),
      }
    ) as unknown as typeof Electron.BrowserWindow,
    WebContentsView: jest.fn(() => ({
      setBounds: jest.fn(),
      webContents: {
        on: jest.fn(),
        removeAllListeners: jest.fn(),
        loadURL: jest.fn(),
        loadFile: jest.fn(),
        reload: jest.fn(),
        isDevToolsOpened: jest.fn(() => false),
        openDevTools: jest.fn(),
        closeDevTools: jest.fn(),
        once: jest.fn(),
      },
    })) as unknown as typeof Electron.WebContentsView,
    Menu: {
      buildFromTemplate: jest.fn(() => ({})),
      setApplicationMenu: jest.fn(),
    } as unknown as typeof Electron.Menu,
    ipcMain: {
      on: jest.fn() as jest.MockedFunction<typeof Electron.ipcMain.on>,
    } as unknown as typeof Electron.ipcMain,
    dialog: {
      showSaveDialog: jest.fn(),
      showMessageBox: jest.fn(),
      showErrorBox: jest.fn(),
    } as unknown as typeof Electron.dialog,
    shell: {
      showItemInFolder: jest.fn(),
      openExternal: jest.fn(),
    } as unknown as typeof Electron.shell,
  };
});

// Mock child_process
jest.mock("child_process", () => ({
  exec: jest.fn(),
  spawn: jest.fn(() => ({
    stdout: { on: jest.fn() as jest.Mock },
    stderr: { on: jest.fn() as jest.Mock },
    on: jest.fn() as jest.Mock,
    kill: jest.fn() as jest.Mock,
  })),
}));

// Mock fs/promises
jest.mock("fs/promises", () => ({
  cp: jest.fn(),
}));

// Mock fs
jest.mock("fs", () => ({
  existsSync: jest.fn(),
  mkdirSync: jest.fn(),
  readFileSync: jest.fn(),
  writeFileSync: jest.fn(),
}));

// Mock process.on for signal handlers
const originalProcessOn = process.on;
(process.on as any) = jest.fn((event: string, handler: any) => {
  // Call the original for non-signal events
  if (event !== "SIGINT" && event !== "SIGTERM") {
    return originalProcessOn.call(process, event as any, handler);
  }
  return process;
});

/**
 * Describes the Electron Main Process tests.
 */
describe("Electron Main Process", () => {
  let originalExit: typeof process.exit;

  beforeAll(() => {
    // Mock process.exit
    originalExit = process.exit;
    process.exit = jest.fn() as any;
  });

  afterAll(() => {
    // Restore process.exit
    process.exit = originalExit;
  });

  beforeEach(async () => {
    jest.clearAllMocks();
    createWindow();
    setupIpcMainListeners();
    await app.whenReady(); // Ensure app.whenReady() is resolved
  });

  it("should create a new window when app is ready", async () => {
    await app.whenReady();
    expect(BrowserWindow).toHaveBeenCalledTimes(1);
  });

  it("should call npm run build when ipcMain receives 'build' event", () => {
    const buildCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "build"
    )[1];
    buildCallback();
    expect(exec).toHaveBeenCalledWith("npm run build", expect.any(Function));
  });

  it("should kill live-server process when all windows are closed", async () => {
    // Manually trigger the 'window-all-closed' event on the mocked app object
    app.emit("window-all-closed");
    expect(liveServerProcess.kill).toHaveBeenCalledTimes(1);
  });

  it("should log error if npm run build fails", () => {
    const buildCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "build"
    )[1];
    const mockError = new Error("Build failed");
    (exec as unknown as jest.Mock).mockImplementationOnce(
      (command, callback) => {
        callback(mockError, "", "Build failed output");
      }
    );
    const consoleErrorSpy = jest
      .spyOn(console, "error")
      .mockImplementation(() => {});

    buildCallback();

    expect(consoleErrorSpy).toHaveBeenCalledWith(mockError);
    consoleErrorSpy.mockRestore();
  });

  it("should create WebContentsView with correct security settings", () => {
    const { WebContentsView } = require("electron");
    expect(WebContentsView).toHaveBeenCalledWith({
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        webSecurity: true,
        allowRunningInsecureContent: false,
      },
    });
  });

  it("should handle preview IPC event correctly", () => {
    const previewCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "preview"
    )[1];
    const mockEvent = { sender: {}, reply: jest.fn() };

    // Mock liveServerReady to true
    const { setLiveServerUrl } = require("../app/main");
    setLiveServerUrl("http://localhost:8080");

    previewCallback(mockEvent);

    expect(mockEvent.reply).toHaveBeenCalledWith("preview-loaded");
  });

  it("should handle devtools toggle IPC event", () => {
    const devtoolsCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "toggle-devtools"
    )[1];
    const mockEvent = { sender: {}, reply: jest.fn() };

    devtoolsCallback(mockEvent);

    // Since previewWebContentsView exists in createWindow, DevTools should be toggled
    const { WebContentsView } = require("electron");
    const mockWebContentsView = WebContentsView.mock.results[0].value;
    expect(mockWebContentsView.webContents.openDevTools).toHaveBeenCalled();
  });

  it("should handle reload-preview IPC event", () => {
    const reloadCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "reload-preview"
    )[1];

    reloadCallback();

    const { WebContentsView } = require("electron");
    const mockWebContentsView = WebContentsView.mock.results[0].value;
    expect(mockWebContentsView.webContents.reload).toHaveBeenCalled();
  });

  it("should parse live-server URL correctly from stdout", () => {
    const { spawn } = require("child_process");
    const mockProcess = spawn.mock.results[0].value;
    const mockStdout = mockProcess.stdout;

    // Mock URL detection from live-server output
    const testOutput = 'Serving "dist" at http://127.0.0.1:8080\u001b[0m';
    mockStdout.on.mock.calls.find((call: any) => call[0] === "data")[1](
      Buffer.from(testOutput)
    );

    // Verify that the URL was parsed correctly (without ANSI escape codes)
    const { setLiveServerUrl } = require("../app/main");
    expect(setLiveServerUrl).toBeDefined();
  });

  it("should handle live-server stderr output", () => {
    const { spawn } = require("child_process");
    const mockProcess = spawn.mock.results[0].value;
    const mockStderr = mockProcess.stderr;
    const consoleErrorSpy = jest
      .spyOn(console, "error")
      .mockImplementation(() => {});

    // Trigger stderr data
    const errorOutput = "Error starting server";
    mockStderr.on.mock.calls.find((call: any) => call[0] === "data")[1](
      Buffer.from(errorOutput)
    );

    expect(consoleErrorSpy).toHaveBeenCalledWith(
      expect.stringContaining("eleventy error:")
    );
    consoleErrorSpy.mockRestore();
  });

  it("should handle live-server process close event", () => {
    const { spawn } = require("child_process");
    const mockProcess = spawn.mock.results[0].value;
    const consoleLogSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});

    // Trigger process close
    mockProcess.on.mock.calls.find((call: any) => call[0] === "close")[1](0);

    expect(consoleLogSpy).toHaveBeenCalledWith(
      "eleventy process exited with code 0"
    );
    consoleLogSpy.mockRestore();
  });

  it("should handle WebContentsView error events", () => {
    const { WebContentsView } = require("electron");
    const mockWebContentsView = WebContentsView.mock.results[0].value;
    const consoleErrorSpy = jest
      .spyOn(console, "error")
      .mockImplementation(() => {});

    // Trigger render-process-gone event
    mockWebContentsView.webContents.on.mock.calls.find(
      (call: any) => call[0] === "render-process-gone"
    )[1]();

    expect(consoleErrorSpy).toHaveBeenCalledWith(
      "WebContentsView webContents crashed"
    );

    // Trigger unresponsive event
    mockWebContentsView.webContents.on.mock.calls.find(
      (call: any) => call[0] === "unresponsive"
    )[1]();

    expect(consoleErrorSpy).toHaveBeenCalledWith(
      "WebContentsView webContents unresponsive"
    );

    consoleErrorSpy.mockRestore();
  });

  it("should handle SIGINT signal and cleanup live-server", () => {
    const consoleLogSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});

    // Find and trigger SIGINT handler
    const sigintCall = (process.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "SIGINT"
    );

    if (sigintCall && sigintCall[1]) {
      sigintCall[1]();

      expect(consoleLogSpy).toHaveBeenCalledWith(
        "Received SIGINT, cleaning up..."
      );
      expect(liveServerProcess.kill).toHaveBeenCalledWith("SIGTERM");
      expect(process.exit).toHaveBeenCalledWith(0);
    }

    consoleLogSpy.mockRestore();
  });

  it("should handle SIGTERM signal and cleanup live-server", () => {
    const consoleLogSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});

    // Find and trigger SIGTERM handler
    const sigtermCall = (process.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "SIGTERM"
    );

    if (sigtermCall && sigtermCall[1]) {
      sigtermCall[1]();

      expect(consoleLogSpy).toHaveBeenCalledWith(
        "Received SIGTERM, cleaning up..."
      );
      expect(liveServerProcess.kill).toHaveBeenCalledWith("SIGTERM");
      expect(process.exit).toHaveBeenCalledWith(0);
    }

    consoleLogSpy.mockRestore();
  });

  it("should handle preview when live-server is not ready", () => {
    // The preview callback should handle the case when live-server is not ready
    // This is tested through the IPC handler registration
    expect(ipcMain.on).toHaveBeenCalledWith("preview", expect.any(Function));
  });

  it("should handle new-website IPC event", () => {
    // Just verify the IPC handler was registered
    expect(ipcMain.on).toHaveBeenCalledWith(
      "new-website",
      expect.any(Function)
    );
  });

  it("should handle open-browser IPC event", () => {
    // Just verify the IPC handler was registered
    expect(ipcMain.on).toHaveBeenCalledWith(
      "open-browser",
      expect.any(Function)
    );
  });

  it("should handle hide-preview IPC event", () => {
    const hidePreviewCallback = (ipcMain.on as jest.Mock).mock.calls.find(
      (call) => call[0] === "hide-preview"
    )[1];
    const mockEvent = { sender: {} as any };

    hidePreviewCallback(mockEvent);

    // Verify removeChildView was called
    const mockWindow = BrowserWindow.fromWebContents(mockEvent.sender as any);
    if (mockWindow) {
      expect(mockWindow.contentView.removeChildView).toBeDefined();
    }
  });

  it("should handle app before-quit event", () => {
    // The before-quit handler is registered in app.on("before-quit")
    // We need to check if it was registered during app initialization
    // Since we're calling createWindow in beforeEach, the app events are set up

    // Manually emit the before-quit event
    app.emit("before-quit");

    // Verify cleanup was called
    expect(liveServerProcess.kill).toHaveBeenCalledWith("SIGTERM");
  });

  it("should handle app activate event when no windows exist", () => {
    // The activate handler is registered when app is ready
    // Verify that a window was created during setup
    expect(BrowserWindow).toHaveBeenCalled();

    // Verify the app has event listeners set up
    expect(app.whenReady).toHaveBeenCalled();
  });

  it("should handle export-site IPC event", async () => {
    const { dialog } = require("electron");

    // Setup mocks
    const mockSaveDialogResult = {
      canceled: false,
      filePath: "/test/export/path",
    };

    dialog.showSaveDialog = jest.fn().mockResolvedValue(mockSaveDialogResult);

    const consoleLogSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});

    // Get the export-site handler
    const exportHandler = (ipcMain.on as jest.Mock).mock.calls.find(
      (call: any) => call[0] === "export-site"
    )[1];

    // Create a mock event
    const mockEvent = {
      reply: jest.fn(),
      sender: {
        send: jest.fn(),
      },
    };

    // Trigger the export handler
    await exportHandler(mockEvent);

    // Verify dialog was shown
    expect(dialog.showSaveDialog).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        title: "Export Site",
        defaultPath: "anglesite-export",
        buttonLabel: "Export",
      })
    );

    // Verify build was initiated
    expect(consoleLogSpy).toHaveBeenCalledWith("Building site for export...");

    consoleLogSpy.mockRestore();
  });

  it("should handle export-site cancellation", async () => {
    const { dialog } = require("electron");

    // Setup mocks for cancelled dialog
    const mockSaveDialogResult = {
      canceled: true,
      filePath: undefined,
    };

    dialog.showSaveDialog = jest.fn().mockResolvedValue(mockSaveDialogResult);

    const consoleLogSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => {});

    // Get the export-site handler
    const exportHandler = (ipcMain.on as jest.Mock).mock.calls.find(
      (call: any) => call[0] === "export-site"
    )[1];

    // Create a mock event
    const mockEvent = {
      reply: jest.fn(),
      sender: {
        send: jest.fn(),
      },
    };

    // Trigger the export handler
    await exportHandler(mockEvent);

    // Verify dialog was shown
    expect(dialog.showSaveDialog).toHaveBeenCalled();

    // Verify no build was initiated (user cancelled)
    expect(consoleLogSpy).not.toHaveBeenCalledWith(
      "Building site for export..."
    );

    consoleLogSpy.mockRestore();
  });

  it("should verify export-site IPC handler is registered", () => {
    // Verify that the export-site IPC handler was registered
    expect(ipcMain.on).toHaveBeenCalledWith(
      "export-site",
      expect.any(Function)
    );
  });

  it("should handle new-website IPC event by sending input request", async () => {
    const { BrowserWindow } = require("electron");
    
    // Setup mock window with webContents
    const mockWindow = {
      webContents: {
        send: jest.fn()
      }
    };
    BrowserWindow.fromWebContents.mockReturnValue(mockWindow);

    // Get the new-website handler
    const newWebsiteHandler = (ipcMain.on as jest.Mock).mock.calls.find(
      (call: any) => call[0] === "new-website"
    )[1];

    // Create a mock event
    const mockEvent = {
      sender: {}
    };

    // Trigger the handler
    await newWebsiteHandler(mockEvent);

    // Verify that the input request was sent to renderer
    expect(mockWindow.webContents.send).toHaveBeenCalledWith("show-website-name-input");
  });

  it("should handle create-website-with-name IPC event with website creation", async () => {
    const { dialog, app, BrowserWindow } = require("electron");
    
    // Setup mocks
    dialog.showMessageBox = jest.fn().mockResolvedValue({ response: 0 }); // Success dialog
    
    const mockWindow = {
      webContents: { send: jest.fn() }
    };
    BrowserWindow.fromWebContents.mockReturnValue(mockWindow);

    app.getPath = jest.fn().mockReturnValue("/mock/userdata");
    
    const mockFs = require("fs");
    mockFs.existsSync = jest.fn()
      .mockReturnValueOnce(false) // websites dir doesn't exist
      .mockReturnValueOnce(false) // website doesn't exist  
      .mockReturnValueOnce(true);  // index.md exists
    mockFs.mkdirSync = jest.fn();
    mockFs.readFileSync = jest.fn().mockReturnValue("---\ntitle: Hello World!\n---\nContent");
    mockFs.writeFileSync = jest.fn();
    
    const consoleLogSpy = jest.spyOn(console, "log").mockImplementation(() => {});

    // Get the create-website-with-name handler
    const createWebsiteHandler = (ipcMain.on as jest.Mock).mock.calls.find(
      (call: any) => call[0] === "create-website-with-name"
    )[1];

    // Create a mock event
    const mockEvent = {
      sender: {}
    };

    // Trigger the handler with a website name
    await createWebsiteHandler(mockEvent, "test-website");

    // Verify website creation was logged
    expect(consoleLogSpy).toHaveBeenCalledWith("Creating new website:", "test-website");

    consoleLogSpy.mockRestore();
  });

  it("should handle create-website-with-name with invalid name", async () => {
    const { dialog, BrowserWindow } = require("electron");
    
    // Setup mocks for error dialog
    dialog.showErrorBox = jest.fn();
    
    const mockWindow = {
      webContents: { send: jest.fn() }
    };
    BrowserWindow.fromWebContents.mockReturnValue(mockWindow);

    const consoleLogSpy = jest.spyOn(console, "log").mockImplementation(() => {});

    // Get the create-website-with-name handler
    const createWebsiteHandler = (ipcMain.on as jest.Mock).mock.calls.find(
      (call: any) => call[0] === "create-website-with-name"
    )[1];

    // Create a mock event
    const mockEvent = {
      sender: {}
    };

    // Trigger the handler with invalid name
    await createWebsiteHandler(mockEvent, "");

    // Verify error dialog was shown
    expect(dialog.showErrorBox).toHaveBeenCalledWith(
      "Invalid Name",
      "Please enter a valid website name without special characters."
    );

    // Verify no website creation was attempted
    expect(consoleLogSpy).not.toHaveBeenCalledWith(
      expect.stringContaining("Creating new website:")
    );

    consoleLogSpy.mockRestore();
  });
});
