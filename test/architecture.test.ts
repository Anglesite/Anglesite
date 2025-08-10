/**
 * @file Simple architecture validation tests
 */

describe("Modular Architecture", () => {
  describe("Module Imports", () => {
    it("should import UI modules", () => {
      expect(() => require("../app/ui/window-manager")).not.toThrow();
      expect(() => require("../app/ui/menu")).not.toThrow();
    });

    it("should import server modules", () => {
      expect(() => require("../app/server/eleventy")).not.toThrow();
      expect(() => require("../app/server/https-proxy")).not.toThrow();
    });

    it("should import utility modules", () => {
      expect(() => require("../app/utils/website-manager")).not.toThrow();
      expect(() => require("../app/dns/hosts-manager")).not.toThrow();
      expect(() => require("../app/certificates")).not.toThrow();
    });

    it("should import IPC handlers", () => {
      expect(() => require("../app/ipc/handlers")).not.toThrow();
    });
  });

  describe("Function Exports", () => {
    it("should export functions from window manager", () => {
      const windowManager = require("../app/ui/window-manager");
      expect(typeof windowManager.createWindow).toBe("function");
    });

    it("should export functions from menu module", () => {
      const menu = require("../app/ui/menu");
      expect(typeof menu.createApplicationMenu).toBe("function");
    });

    it("should export functions from eleventy server", () => {
      const eleventy = require("../app/server/eleventy");
      expect(typeof eleventy.generateTestDomain).toBe("function");
      expect(typeof eleventy.getHostnameFromTestDomain).toBe("function");
      expect(typeof eleventy.validateWebsiteName).toBe("undefined"); // Not in this module
    });

    it("should export functions from website manager", () => {
      const websiteManager = require("../app/utils/website-manager");
      expect(typeof websiteManager.validateWebsiteName).toBe("function");
    });

    it("should export functions from hosts manager", () => {
      const hostsManager = require("../app/dns/hosts-manager");
      expect(typeof hostsManager.addLocalDnsResolution).toBe("function");
      expect(typeof hostsManager.cleanupHostsFile).toBe("function");
      expect(typeof hostsManager.updateHostsFile).toBe("function");
      expect(typeof hostsManager.checkAndSuggestTouchIdSetup).toBe("function");
    });
  });

  describe("Pure Functions", () => {
    it("should generate test domains correctly", () => {
      const { generateTestDomain } = require("../app/server/eleventy");

      expect(generateTestDomain("my-site")).toBe("https://my-site.test:8080");
      expect(generateTestDomain("test123")).toBe("https://test123.test:8080");
    });

    it("should extract hostnames from valid URLs", () => {
      const { getHostnameFromTestDomain } = require("../app/server/eleventy");

      expect(getHostnameFromTestDomain("https://my-site.test:8080")).toBe(
        "my-site.test"
      );
      expect(getHostnameFromTestDomain("https://example.test:8080")).toBe(
        "example.test"
      );
    });

    it("should validate website names", () => {
      const { validateWebsiteName } = require("../app/utils/website-manager");

      // Valid names
      expect(validateWebsiteName("valid-name").valid).toBe(true);
      expect(validateWebsiteName("site123").valid).toBe(true);
      expect(validateWebsiteName("my_site").valid).toBe(true);

      // Invalid names
      expect(validateWebsiteName("").valid).toBe(false);
      expect(validateWebsiteName("invalid name").valid).toBe(false);
      expect(validateWebsiteName("site@home").valid).toBe(false);
    });
  });

  describe("Refactoring Success", () => {
    it("should have moved main.ts from monolith to modular", () => {
      const fs = require("fs");
      const path = require("path");

      const mainPath = path.join(__dirname, "..", "app", "main.ts");
      const mainContent = fs.readFileSync(mainPath, "utf8");

      // Should be much shorter now (refactored)
      const lineCount = mainContent.split("\n").length;
      expect(lineCount).toBeLessThan(200); // Was over 2000 lines before

      // Should import from modules
      expect(mainContent).toContain("import { createHelpWindow");
      expect(mainContent).toContain("import { createApplicationMenu");
      expect(mainContent).toContain("import { setupIpcMainListeners");
      // Check that DNS management functions are imported (may be multi-line)
      expect(mainContent).toContain("addLocalDnsResolution");
      expect(mainContent).toContain("cleanupHostsFile");
      expect(mainContent).toContain("checkAndSuggestTouchIdSetup");
    });

    it("should have separate module files", () => {
      const fs = require("fs");
      const path = require("path");

      // Check that modular files exist
      const modules = [
        "ui/window-manager.ts",
        "ui/menu.ts",
        "server/eleventy.ts",
        "server/https-proxy.ts",
        "ipc/handlers.ts",
        "utils/website-manager.ts",
        "dns/hosts-manager.ts",
        "certificates.ts",
      ];

      modules.forEach((modulePath) => {
        const fullPath = path.join(__dirname, "..", "app", modulePath);
        expect(fs.existsSync(fullPath)).toBe(true);
      });
    });
  });
});
