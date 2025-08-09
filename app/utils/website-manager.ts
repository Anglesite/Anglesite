/**
 * @file Website creation and management utilities
 */
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { dialog } from "electron";

/**
 * Get the websites directory path
 */
function getWebsitesDirectory(): string {
  const appDataPath =
    process.platform === "darwin"
      ? path.join(os.homedir(), "Library", "Application Support", "Anglesite")
      : process.platform === "win32"
      ? path.join(process.env.APPDATA || "", "Anglesite")
      : path.join(os.homedir(), ".config", "anglesite");

  return path.join(appDataPath, "websites");
}

/**
 * Create a new website with the given name
 */
export async function createWebsiteWithName(
  websiteName: string
): Promise<string> {
  console.log("Creating new website:", websiteName);

  const websitesDir = getWebsitesDirectory();
  const newWebsitePath = path.join(websitesDir, websiteName);

  // Create websites directory if it doesn't exist
  if (!fs.existsSync(websitesDir)) {
    fs.mkdirSync(websitesDir, { recursive: true });
    console.log("Created websites directory:", websitesDir);
  }

  // Create new website directory
  if (fs.existsSync(newWebsitePath)) {
    throw new Error(`Website "${websiteName}" already exists`);
  }

  fs.mkdirSync(newWebsitePath, { recursive: true });

  // Create basic website structure
  const indexContent = [
    "---",
    "layout: base-layout.njk",
    "title: " + websiteName,
    "---",
    "",
    "# Welcome to " + websiteName,
    "",
    "This is your new website! Edit this file to get started.",
    "",
    "## Getting Started",
    "",
    "- Edit this markdown file to change the content",
    "- Add more pages by creating new .md files",
    "- Customize the layout in the _includes directory",
    "- Add styles to style.css",
    "",
    "Happy building! 🚀",
    "",
  ].join("\n");

  fs.writeFileSync(path.join(newWebsitePath, "index.md"), indexContent);

  console.log("New website created at:", newWebsitePath);
  return newWebsitePath;
}

/**
 * Get website name from user input
 */
export async function getWebsiteNameFromUser(): Promise<string | null> {
  // For now, use a simple dialog - in a real implementation you'd want a proper input dialog
  const result = dialog.showMessageBoxSync({
    type: "question",
    title: "New Website",
    message: "Enter website name:",
    buttons: ["Cancel", "Create"],
    defaultId: 1,
    cancelId: 0,
  });

  if (result === 1) {
    // This is a simplified implementation - you'd need a proper text input dialog
    return "my-new-website";
  }

  return null;
}

/**
 * Validate website name
 */
export function validateWebsiteName(name: string): {
  valid: boolean;
  error?: string;
} {
  if (!name || name.trim().length === 0) {
    return { valid: false, error: "Website name cannot be empty" };
  }

  // Check for valid characters (letters, numbers, hyphens, underscores)
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    return {
      valid: false,
      error:
        "Website name can only contain letters, numbers, hyphens, and underscores",
    };
  }

  // Check length
  if (name.length > 50) {
    return {
      valid: false,
      error: "Website name must be 50 characters or less",
    };
  }

  return { valid: true };
}

/**
 * List all existing websites
 */
export function listWebsites(): string[] {
  const websitesDir = getWebsitesDirectory();

  if (!fs.existsSync(websitesDir)) {
    return [];
  }

  try {
    return fs
      .readdirSync(websitesDir, { withFileTypes: true })
      .filter((dirent) => dirent.isDirectory())
      .map((dirent) => dirent.name);
  } catch (error) {
    console.error("Failed to list websites:", error);
    return [];
  }
}

/**
 * Delete a website
 */
export async function deleteWebsite(websiteName: string): Promise<boolean> {
  const websitesDir = getWebsitesDirectory();
  const websitePath = path.join(websitesDir, websiteName);

  if (!fs.existsSync(websitePath)) {
    throw new Error(`Website "${websiteName}" does not exist`);
  }

  const result = dialog.showMessageBoxSync({
    type: "warning",
    title: "Delete Website",
    message: `Are you sure you want to delete "${websiteName}"?`,
    detail: "This action cannot be undone.",
    buttons: ["Cancel", "Delete"],
    defaultId: 0,
    cancelId: 0,
  });

  if (result === 1) {
    try {
      fs.rmSync(websitePath, { recursive: true });
      console.log("Website deleted:", websitePath);
      return true;
    } catch (error) {
      console.error("Failed to delete website:", error);
      throw error;
    }
  }

  return false;
}

/**
 * Get website path
 */
export function getWebsitePath(websiteName: string): string {
  return path.join(getWebsitesDirectory(), websiteName);
}
