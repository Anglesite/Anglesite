/**
 * @file Tests for the Electron renderer process.
 */
import { ipcRenderer } from "electron";

// Mock Electron's ipcRenderer
jest.mock("electron", () => ({
  // Corrected: Removed unnecessary escaping of curly braces
  ipcRenderer: {
    send: jest.fn(),
  },
}));

describe("Renderer Process", () => {
  let buildButton: HTMLElement;

  beforeEach(() => {
    jest.clearAllMocks();
    // Set up a minimal DOM for the test
    document.body.innerHTML = '<button id="build">Build</button>'; // Corrected: Escaped double quotes within the string
    buildButton = document.getElementById("build") as HTMLElement;

    // Dynamically import the renderer script after the DOM is set up
    jest.isolateModules(() => {
      jest.requireActual("../dist/app/renderer.js");
    });
  });

  it("should send a 'build' message when the build button is clicked", () => {
    // Corrected: Escaped single quote within the string
    buildButton.click();
    expect(ipcRenderer.send).toHaveBeenCalledWith("build");
  });
});
