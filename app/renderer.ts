/**
 * @file Renderer process for the Electron application.
 * @see {@link https://www.electronjs.org/docs/latest/tutorial/process-model#renderer-process}
 */

console.log("DEBUG: Renderer script is executing");
console.log("DEBUG: window.electronAPI available:", !!window.electronAPI);

// Send a message to main process to confirm renderer is loaded
if (window.electronAPI) {
  window.electronAPI.send("renderer-loaded", "Renderer is working!");
}

// Simplified immediate registration
console.log("DEBUG: About to register show-website-name-input listener");

try {
  if (window.electronAPI && window.electronAPI.on) {
    console.log("DEBUG: electronAPI available, setting up listener");
    
    window.electronAPI.on("show-website-name-input", () => {
      console.log("DEBUG: *** WEBSITE NAME INPUT REQUESTED ***");
      
      const websiteName = prompt("Enter a name for your new website:", "My Website");
      console.log("DEBUG: User entered name:", websiteName);
      
      if (websiteName && websiteName.trim()) {
        console.log("DEBUG: Sending create-website-with-name:", websiteName.trim());
        window.electronAPI.send("create-website-with-name", websiteName.trim());
      } else {
        console.log("DEBUG: No website name provided, cancelling");
      }
    });
    
    console.log("DEBUG: Listener registered successfully");
  } else {
    console.error("DEBUG: No electronAPI available");
  }
} catch (error) {
  console.error("DEBUG: Error setting up listener:", error);
}

const newWebsiteButton = document.getElementById("new-website");
const previewButton = document.getElementById("preview");
const openBrowserButton = document.getElementById("open-browser");
const reloadButton = document.getElementById("reload");
const devToolsButton = document.getElementById("devtools");

/**
 * Adds event listener to the new website button.
 * @returns {void}
 */
if (newWebsiteButton) {
  newWebsiteButton.addEventListener("click", () => {
    window.electronAPI.send("new-website");
  });
}

/**
 * Adds event listener to the preview button to load the site preview.
 * @returns {void}
 */
if (previewButton) {
  previewButton.addEventListener("click", () => {
    console.log("Preview button clicked");
    window.electronAPI.send("preview");
  });
}

/**
 * Adds event listener to the open browser button to open the site in external browser.
 * @returns {void}
 */
if (openBrowserButton) {
  openBrowserButton.addEventListener("click", () => {
    window.electronAPI.send("open-browser");
  });
}

/**
 * Adds event listener to the reload button to refresh the site preview.
 * @returns {void}
 */
if (reloadButton) {
  reloadButton.addEventListener("click", () => {
    console.log("Reload button clicked");
    window.electronAPI.send("reload-preview");
  });
}

/**
 * Adds event listener to the DevTools button to toggle dev tools.
 * @returns {void}
 */
if (devToolsButton) {
  devToolsButton.addEventListener("click", () => {
    console.log("DevTools button clicked - sending IPC message");
    window.electronAPI.send("toggle-devtools");
    console.log("IPC message sent");
  });
} else {
  console.error("DevTools button not found!");
}

/**
 * Listens for preview loaded events from the main process.
 * @returns {void}
 */
window.electronAPI.on("preview-loaded", () => {
  console.log("Preview BrowserView loaded");
});

/**
 * Handle menu events from the application menu.
 * @returns {void}
 */
console.log("DEBUG: Registering menu-new-website event listener");
window.electronAPI.on("menu-new-website", () => {
  console.log("DEBUG: New website requested from menu");
  window.electronAPI.send("new-website");
  console.log("DEBUG: Sent new-website IPC message");
});

window.electronAPI.on("menu-reload", () => {
  if (reloadButton) {
    reloadButton.click();
  }
});

window.electronAPI.on("menu-toggle-devtools", () => {
  if (devToolsButton) {
    devToolsButton.click();
  }
});

window.electronAPI.on("menu-export-site", () => {
  console.log("Export site requested from menu");
  window.electronAPI.send("export-site");
});


/**
 * Add console log to confirm renderer is loaded.
 * @returns {void}
 */
window.addEventListener("DOMContentLoaded", () => {
  console.log(
    "DEBUG: Anglesite renderer loaded successfully with BrowserView support"
  );
  console.log("DEBUG: Setting up menu event listeners");
});
