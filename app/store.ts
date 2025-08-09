/**
 * @file Persistent storage for Anglesite application settings
 *
 * Manages user preferences and configuration state across app sessions
 * Settings are stored in JSON format in the user's application data directory
 */
import { app } from "electron";
import * as fs from "fs";
import * as path from "path";

/**
 * Application settings interface defining all configurable options
 */
export interface AppSettings {
  /** Whether automatic DNS configuration is enabled */
  autoDnsEnabled: boolean;
  /** HTTPS mode preference: 'https', 'http', or null if not yet configured */
  httpsMode: "https" | "http" | null;
  /** Whether the first launch setup assistant has been completed */
  firstLaunchCompleted: boolean;
  // Add more settings here as needed
}

/**
 * Persistent settings store with automatic JSON serialization
 * Handles loading, saving, and type-safe access to application settings
 */
export class Store {
  private path: string;
  private data: AppSettings;

  /**
   * Initialize the settings store
   * Loads existing settings from disk or creates default settings if none exist
   */
  constructor() {
    const userDataPath = app.getPath("userData");
    this.path = path.join(userDataPath, "settings.json");

    // Load existing settings or create defaults
    this.data = this.parseDataFile(this.path, {
      autoDnsEnabled: false,
      httpsMode: null,
      firstLaunchCompleted: false,
    });
  }

  /**
   * Get a setting value by key
   * @param key - The setting key to retrieve
   * @returns The current value of the specified setting
   */
  get<K extends keyof AppSettings>(key: K): AppSettings[K] {
    return this.data[key];
  }

  /**
   * Set a setting value and persist to disk
   * @param key - The setting key to update
   * @param val - The new value to set
   */
  set<K extends keyof AppSettings>(key: K, val: AppSettings[K]): void {
    this.data[key] = val;
    this.saveData();
  }

  /**
   * Get all current settings
   * @returns Complete settings object
   */
  getAll(): AppSettings {
    return this.data;
  }

  /**
   * Set multiple settings at once
   * @param {Partial<AppSettings>} settings - Settings to update
   * @returns {void}
   */
  setAll(settings: Partial<AppSettings>): void {
    this.data = { ...this.data, ...settings };
    this.saveData();
  }

  /**
   * Parse data file or return defaults
   * @param {string} filePath - Path to the settings file
   * @param {AppSettings} defaults - Default settings
   * @returns {AppSettings} The parsed settings or defaults
   */
  private parseDataFile(filePath: string, defaults: AppSettings): AppSettings {
    try {
      if (fs.existsSync(filePath)) {
        const fileContent = fs.readFileSync(filePath, "utf-8");
        return JSON.parse(fileContent);
      }
    } catch (error) {
      console.error("Error reading settings file:", error);
    }
    return defaults;
  }

  /**
   * Save data to file
   * @returns {void}
   */
  private saveData(): void {
    try {
      fs.writeFileSync(this.path, JSON.stringify(this.data, null, 2));
    } catch (error) {
      console.error("Error saving settings:", error);
    }
  }
}
