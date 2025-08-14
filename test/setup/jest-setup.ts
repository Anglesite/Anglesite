/**
 * @file Jest setup file that runs before all tests
 *
 * This file imports custom matchers and performs any other
 * global test setup required for the Anglesite test suite.
 */

// Import custom matchers to make them available in all test files
import '../matchers/custom-matchers';

// Import third-party mocks to ensure they're applied early
import '../mocks/third-party';

// Additional global setup can be added here if needed
