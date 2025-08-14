/**
 * @file Tests for the Eleventy configuration.
 */

// Mock the dependencies that .eleventy.js requires
jest.mock('@11ty/eleventy-plugin-webc', () => ({}));
jest.mock('nunjucks', () => ({
  Environment: jest.fn().mockImplementation(() => ({})),
  FileSystemLoader: jest.fn().mockImplementation(() => ({})),
}));

// Now require the module
const eleventyConfig = require('../app/eleventy/.eleventy.js');

/**
 * Describes the Eleventy configuration tests.
 */
describe('Eleventy Configuration', () => {
  it('should define input and output directories', () => {
    const config = eleventyConfig({
      addPlugin: jest.fn(),
      addPassthroughCopy: jest.fn(),
      setLibrary: jest.fn(),
      ignores: {
        add: jest.fn(),
      },
    });
    expect(config.dir).toBeDefined();
    expect(config.dir.includes).toBe('_includes');
    expect(config.dir.layouts).toBe('_includes');
  });
});
