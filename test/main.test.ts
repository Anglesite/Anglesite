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
    BrowserWindow: jest.fn(() => ({
      loadFile: jest.fn(),
      loadURL: jest.fn(),
    })) as unknown as typeof Electron.BrowserWindow,
    ipcMain: {
      on: jest.fn() as jest.MockedFunction<typeof Electron.ipcMain.on>,
    } as unknown as typeof Electron.ipcMain,
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

/**
 * Describes the Electron Main Process tests.
 */
describe("Electron Main Process", () => {
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
});
