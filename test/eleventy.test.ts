/**
 * @file Tests for the Eleventy configuration.
 */
import eleventyConfig from "../.eleventy";

/**
 * Describes the Eleventy configuration tests.
 */
describe("Eleventy Configuration", () => {
  it("should define input and output directories", () => {
    const config = eleventyConfig({
      addPlugin: () => {},
      addPassthroughCopy: () => {},
    });
    expect(config.dir).toBeDefined();
    expect(config.dir.input).toBe("src");
    expect(config.dir.output).toBe("dist");
  });
});
