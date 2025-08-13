/**
 * @file Type definitions for custom Jest matchers
 *
 * Provides proper typing for mock objects and function signatures
 * used by the custom matchers.
 */

/**
 * Type for mock call arguments
 */
export type MockCall = unknown[];

/**
 * Type for window-like mock objects with common Electron BrowserWindow methods
 */
export interface WindowMock {
  isDestroyed?: jest.Mock<boolean>;
  isMaximized?: jest.Mock<boolean>;
  isFocused?: jest.Mock<boolean>;
  getTitle?: jest.Mock<string>;
  focus?: jest.Mock;
  show?: jest.Mock;
  close?: jest.Mock;
  getBounds?: jest.Mock;
  setBounds?: jest.Mock;
  maximize?: jest.Mock;
  on?: jest.Mock;
  once?: jest.Mock;
  loadFile?: jest.Mock;
  webContents?: {
    send?: jest.Mock;
    isLoading?: jest.Mock;
    executeJavaScript?: jest.Mock;
    once?: jest.Mock;
  };
}

/**
 * Type for functions that may receive various input types
 */
export type InputHandler<T = unknown> = (input: T) => unknown;

/**
 * Window state configuration for assertions
 */
export interface WindowState {
  destroyed?: boolean;
  maximized?: boolean;
  focused?: boolean;
  title?: string;
}

/**
 * Invalid input test values
 */
export const INVALID_INPUTS = [undefined, null, '', [], {}, 'non-existent', -1, NaN] as const;

/**
 * Type guard to check if a value is a string.
 * @param value The value to check
 * @returns True if the value is a string
 */
export function isString(value: unknown): value is string {
  return typeof value === 'string';
}

/**
 * Type guard to check if a value is a function.
 * @param value The value to check
 * @returns True if the value is a function
 */
export function isFunction(value: unknown): value is (...args: unknown[]) => unknown {
  return typeof value === 'function';
}
