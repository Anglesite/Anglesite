/**
 * @file Persistent storage for Anglesite application settings
 *
 * Manages user preferences and configuration state across app sessions.
 * Settings are stored in JSON format in the user's application data directory.
 */
import { app } from 'electron';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Interface for persisting website window state.
 */
export interface WindowState {
  /** Name of the website */
  websiteName: string;
  /** Path to the website directory */
  websitePath?: string;
  /** Window bounds */
  bounds?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  /** Whether the window was maximized */
  isMaximized?: boolean;
}

/**
 * Application settings interface defining all configurable options.
 */
export interface AppSettings {
  /** Whether automatic DNS configuration is enabled */
  autoDnsEnabled: boolean;
  /** HTTPS mode preference: 'https', 'http', or null if not yet configured */
  httpsMode: 'https' | 'http' | null;
  /** Whether the first launch setup assistant has been completed */
  firstLaunchCompleted: boolean;
  /** Theme preference: 'system', 'light', 'dark' */
  theme: 'system' | 'light' | 'dark';
  /** List of website windows to restore on startup */
  openWebsiteWindows: WindowState[];
  /** List of recently opened websites (up to 10, most recent first) */
  recentWebsites: string[];
  // Add more settings here as needed
}

/**
 * Persistent settings store with automatic JSON serialization.
 * Handles loading, saving, and type-safe access to application settings.
 */
export class Store {
  private path: string;
  private data: AppSettings;

  /**
   * Initialize the settings store.
   * Loads existing settings from disk or creates default settings if none exist.
   */
  constructor() {
    const userDataPath = app.getPath('userData');
    this.path = path.join(userDataPath, 'settings.json');

    // Load existing settings or create defaults
    this.data = this.parseDataFile(this.path, {
      autoDnsEnabled: false,
      httpsMode: null,
      firstLaunchCompleted: false,
      theme: 'system',
      openWebsiteWindows: [],
      recentWebsites: [],
    });
  }

  /**
   * Get a setting value by key.
   * @param key The setting key to retrieve
   * @returns The current value of the specified setting
   */
  get<K extends keyof AppSettings>(key: K): AppSettings[K] {
    return this.data[key];
  }

  /**
   * Set a setting value and persist to disk.
   * @param key The setting key to update
   * @param val The new value to set
   */
  set<K extends keyof AppSettings>(key: K, val: AppSettings[K]): void {
    this.data[key] = val;
    this.saveData();
  }

  /**
   * Get all current settings.
   * @returns Complete settings object
   */
  getAll(): AppSettings {
    return this.data;
  }

  /**
   * Set multiple settings at once.
   * @param settings Settings to update
   */
  setAll(settings: Partial<AppSettings>): void {
    this.data = { ...this.data, ...settings };
    this.saveData();
  }

  /**
   * Save current window states.
   * @param windowStates Array of window states to save
   */
  saveWindowStates(windowStates: WindowState[]): void {
    this.set('openWebsiteWindows', windowStates);
  }

  /**
   * Get saved window states.
   * @returns Array of saved window states
   */
  getWindowStates(): WindowState[] {
    return this.get('openWebsiteWindows');
  }

  /**
   * Clear saved window states.
   */
  clearWindowStates(): void {
    this.set('openWebsiteWindows', []);
  }

  /**
   * Add a website to the recent websites list.
   * Moves existing website to top or adds new one at the beginning.
   * Maintains a maximum of 10 recent websites.
   * @param websiteName Name of the website to add
   */
  addRecentWebsite(websiteName: string): void {
    const recentWebsites = this.get('recentWebsites').slice(); // Create a copy
    
    // Remove existing occurrence if present
    const existingIndex = recentWebsites.indexOf(websiteName);
    if (existingIndex !== -1) {
      recentWebsites.splice(existingIndex, 1);
    }
    
    // Add to beginning
    recentWebsites.unshift(websiteName);
    
    // Keep only the 10 most recent
    const limitedRecent = recentWebsites.slice(0, 10);
    
    this.set('recentWebsites', limitedRecent);
  }

  /**
   * Get the list of recent websites.
   * @returns Array of recent website names, most recent first
   */
  getRecentWebsites(): string[] {
    return this.get('recentWebsites');
  }

  /**
   * Clear the recent websites list.
   */
  clearRecentWebsites(): void {
    this.set('recentWebsites', []);
  }

  /**
   * Remove a specific website from the recent websites list.
   * @param websiteName Name of the website to remove
   */
  removeRecentWebsite(websiteName: string): void {
    const recentWebsites = this.get('recentWebsites').slice();
    const index = recentWebsites.indexOf(websiteName);
    if (index !== -1) {
      recentWebsites.splice(index, 1);
      this.set('recentWebsites', recentWebsites);
    }
  }

  /**
   * Parse data file or return defaults.
   * @param filePath Path to the settings file
   * @param defaults Default settings
   * @returns The parsed settings or defaults
   */
  private parseDataFile(filePath: string, defaults: AppSettings): AppSettings {
    try {
      if (fs.existsSync(filePath)) {
        const fileContent = fs.readFileSync(filePath, 'utf-8');
        return JSON.parse(fileContent);
      }
    } catch (error) {
      console.error('Error reading settings file:', error);
    }
    return defaults;
  }

  /**
   * Save data to file.
   */
  private saveData(): void {
    try {
      fs.writeFileSync(this.path, JSON.stringify(this.data, null, 2));
    } catch (error) {
      console.error('Error saving settings:', error);
    }
  }
}
