/**
 * @file Website creation and management utilities.
 */
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { dialog, BrowserWindow } from 'electron';

/**
 * Get the platform-specific websites directory path.
 * @returns Absolute path to the websites directory.
 */
function getWebsitesDirectory(): string {
  const appDataPath =
    process.platform === 'darwin'
      ? path.join(os.homedir(), 'Library', 'Application Support', 'Anglesite')
      : process.platform === 'win32'
        ? path.join(process.env.APPDATA || '', 'Anglesite')
        : path.join(os.homedir(), '.config', 'anglesite');

  return path.join(appDataPath, 'websites');
}

/**
 * Create a new website with the specified name and basic structure.
 *
 * Creates a new website directory in the application's websites folder.
 * Initializes it with a basic Eleventy site structure including:
 * - index.md with frontmatter configuration
 * - Basic Markdown content template
 *
 * The website directory is created using the provided name, and all necessary.
 * Parent directories are created automatically.
 * @param websiteName Unique name for the new website (used as directory name).
 * @returns Promise resolving to the absolute path of the created website directory.
 * @throws Error if a website with the same name already exists.
 * @example
 * ```typescript
 * const websitePath = await createWebsiteWithName('my-new-blog');
 * console.log(websitePath); // '/path/to/websites/my-new-blog'
 * ```
 */
export async function createWebsiteWithName(websiteName: string): Promise<string> {
  console.log('Creating new website:', websiteName);

  const websitesDir = getWebsitesDirectory();
  const newWebsitePath = path.join(websitesDir, websiteName);

  // Create websites directory if it doesn't exist
  if (!fs.existsSync(websitesDir)) {
    fs.mkdirSync(websitesDir, { recursive: true });
    console.log('Created websites directory:', websitesDir);
  }

  // Create new website directory
  if (fs.existsSync(newWebsitePath)) {
    throw new Error(`Website "${websiteName}" already exists`);
  }

  fs.mkdirSync(newWebsitePath, { recursive: true });

  // Use the app/eleventy/src directory as the template source
  const templateSourcePath = path.join(__dirname, '..', 'eleventy', 'src');

  // Copy all files from the template directory
  if (fs.existsSync(templateSourcePath)) {
    copyDirectoryRecursive(templateSourcePath, newWebsitePath);

    // Now customize the index.md with the website name
    const indexPath = path.join(newWebsitePath, 'index.md');
    if (fs.existsSync(indexPath)) {
      // Read the template content
      let indexContent = fs.readFileSync(indexPath, 'utf8');

      // Replace the title in frontmatter and content with website-specific values
      indexContent = indexContent.replace(/title: .*/, `title: Welcome to ${websiteName}!`);
      indexContent = indexContent.replace(
        /This is your new website!.*/,
        `Welcome to ${websiteName}! This is your new Anglesite-powered website.`
      );

      // Add a personalized welcome section
      const welcomeSection = `

## About ${websiteName}

Your new website is ready to go! ${websiteName} is powered by Anglesite and uses Eleventy for static site generation.

### Quick Tips

- This site was created from the Anglesite template
- All your content is stored locally on your computer
- Changes are automatically detected and rebuilt
- You can preview your site instantly in the Anglesite app`;

      // Insert the welcome section after the first paragraph
      indexContent = indexContent.replace(/(Edit this file to get started\.)/, `$1${welcomeSection}`);

      // Write the customized content back
      fs.writeFileSync(indexPath, indexContent);
    }
  }

  // Create _includes directory and copy layout files
  const includesDir = path.join(newWebsitePath, '_includes');
  if (!fs.existsSync(includesDir)) {
    fs.mkdirSync(includesDir, { recursive: true });

    // Copy layout files from app's eleventy includes
    const sourceIncludesPath = path.join(__dirname, '..', 'eleventy', 'includes');
    const layoutFiles = ['base-layout.njk', 'header.njk', 'style.css'];

    for (const file of layoutFiles) {
      const sourcePath = path.join(sourceIncludesPath, file);
      const destPath = path.join(includesDir, file);

      if (fs.existsSync(sourcePath)) {
        fs.copyFileSync(sourcePath, destPath);
        console.log(`Copied layout file: ${file}`);
      }
    }
  }

  console.log('New website created at:', newWebsitePath);
  return newWebsitePath;
}

/**
 * Recursively copy directory contents.
 */
function copyDirectoryRecursive(source: string, target: string): void {
  if (!fs.existsSync(target)) {
    fs.mkdirSync(target, { recursive: true });
  }

  const files = fs.readdirSync(source);

  for (const file of files) {
    const sourcePath = path.join(source, file);
    const targetPath = path.join(target, file);

    if (fs.lstatSync(sourcePath).isDirectory()) {
      copyDirectoryRecursive(sourcePath, targetPath);
    } else {
      fs.copyFileSync(sourcePath, targetPath);
      console.log(`Copied: ${file}`);
    }
  }
}

/**
 * Get website name from user input.
 */
export async function getWebsiteNameFromUser(): Promise<string | null> {
  // For now, use a simple dialog - in a real implementation you'd want a proper input dialog
  const result = dialog.showMessageBoxSync({
    type: 'question',
    title: 'New Website',
    message: 'Enter website name:',
    buttons: ['Cancel', 'Create'],
    defaultId: 1,
    cancelId: 0,
  });

  if (result === 1) {
    // This is a simplified implementation - you'd need a proper text input dialog
    return 'my-new-website';
  }

  return null;
}

/**
 * Checks if a website name is valid according to naming rules and character restrictions.
 */
export function validateWebsiteName(name: string): {
  valid: boolean;
  error?: string;
} {
  if (!name || name.trim().length === 0) {
    return { valid: false, error: 'Website name cannot be empty' };
  }

  // Check for valid characters (letters, numbers, hyphens, underscores)
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    return {
      valid: false,
      error: 'Website name can only contain letters, numbers, hyphens, and underscores',
    };
  }

  // Check length
  if (name.length > 50) {
    return {
      valid: false,
      error: 'Website name must be 50 characters or less',
    };
  }

  return { valid: true };
}

/**
 * List all existing websites.
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
    console.error('Failed to list websites:', error);
    return [];
  }
}

/**
 * Delete a website.
 */
export async function deleteWebsite(websiteName: string, parentWindow?: BrowserWindow): Promise<boolean> {
  const websitesDir = getWebsitesDirectory();
  const websitePath = path.join(websitesDir, websiteName);

  if (!fs.existsSync(websitePath)) {
    throw new Error(`Website "${websiteName}" does not exist`);
  }

  const dialogOptions = {
    type: 'warning' as const,
    title: 'Delete Website',
    message: `Are you sure you want to delete "${websiteName}"?`,
    detail: 'This action cannot be undone.',
    buttons: ['Cancel', 'Delete'],
    defaultId: 0,
    cancelId: 0,
  };

  // Use the parent window if provided for proper modal behavior
  const result = parentWindow
    ? dialog.showMessageBoxSync(parentWindow, dialogOptions)
    : dialog.showMessageBoxSync(dialogOptions);

  if (result === 1) {
    try {
      fs.rmSync(websitePath, { recursive: true });
      console.log('Website deleted:', websitePath);
      return true;
    } catch (error) {
      console.error('Failed to delete website:', error);
      throw error;
    }
  }

  return false;
}

/**
 * Constructs the full file system path for a website given its name.
 */
export function getWebsitePath(websiteName: string): string {
  return path.join(getWebsitesDirectory(), websiteName);
}

/**
 * Rename a website.
 */
export async function renameWebsite(oldName: string, newName: string): Promise<boolean> {
  console.log(`Renaming website from "${oldName}" to "${newName}"`);

  // Validate the new name
  const validation = validateWebsiteName(newName);
  if (!validation.valid) {
    throw new Error(validation.error || 'Invalid website name');
  }

  const websitesDir = getWebsitesDirectory();
  const oldPath = path.join(websitesDir, oldName);
  const newPath = path.join(websitesDir, newName);

  // Check if old website exists
  if (!fs.existsSync(oldPath)) {
    throw new Error(`Website "${oldName}" does not exist`);
  }

  // Check if new name already exists
  if (fs.existsSync(newPath)) {
    throw new Error(`Website "${newName}" already exists`);
  }

  try {
    // Rename the directory
    fs.renameSync(oldPath, newPath);
    console.log(`Website renamed from "${oldName}" to "${newName}"`);
    return true;
  } catch (error) {
    console.error('Failed to rename website:', error);
    throw error;
  }
}
