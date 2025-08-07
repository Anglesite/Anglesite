/**
 * @file Renderer process for the Electron application.
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/process-model#renderer-process}
 */
import { ipcRenderer } from "electron";

const buildButton = document.getElementById("build");

/**
 * Adds an event listener to the build button to trigger the build process.
 * @returns {void}
 */
if (buildButton) {
  buildButton.addEventListener("click", () => {
    ipcRenderer.send("build");
  });
}
