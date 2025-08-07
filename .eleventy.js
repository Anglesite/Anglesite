const webc = require("@11ty/eleventy-plugin-webc");

/**
 * @param {import("@11ty/eleventy").UserConfig} eleventyConfig
 * @returns {ReturnType<import("@11ty/eleventy").UserConfig>}
 */
module.exports = function (eleventyConfig) {
  eleventyConfig.addPlugin(webc, {
    components: "src/_includes/**/*.webc",
  });

  eleventyConfig.addPassthroughCopy({
    "src/_includes/style.css": "/style.css",
  });

  return {
    markdownTemplateEngine: "njk",
    dir: {
      input: "src",
      output: "dist",
      includes: "_includes",
    },
  };
};
