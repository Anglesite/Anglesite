/**
 * @file Tests for the Eleventy configuration.
 */
const eleventyConfig = require('../../app/eleventy/.eleventy');

/**
 * Describes the Eleventy configuration tests.
 */
describe('Eleventy Configuration', () => {
  it('should define input and output directories', () => {
    const config = eleventyConfig({
      addPlugin: () => {},
      addPassthroughCopy: () => {},
      setLibrary: () => {},
    });
    expect(config.dir).toBeDefined();
    expect(config.dir.input).toBe('docs');
    expect(config.dir.output).toBe('dist');
  });
});
