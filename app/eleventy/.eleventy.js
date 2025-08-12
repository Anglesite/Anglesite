const webc = require('@11ty/eleventy-plugin-webc');
const path = require('path');
const Nunjucks = require('nunjucks');

/**
 * Returns an absolute path relative to the project root.
 * @param relativePath Path relative to the project root.
 * @returns
 */
function rootDir(relativePath) {
  return path.resolve(process.cwd(), relativePath);
}

/**
 * @param eleventyConfig
 * @returns
 */
module.exports = function AnglesiteConfig(eleventyConfig) {
  const absoluteIncludesPath = rootDir('app/eleventy/includes');

  eleventyConfig.addPlugin(webc, {
    components: path.join(absoluteIncludesPath, '**/*.webc'),
  });

  eleventyConfig.setLibrary('njk', new Nunjucks.Environment(new Nunjucks.FileSystemLoader(absoluteIncludesPath)));

  eleventyConfig.addPassthroughCopy({
    [path.join(absoluteIncludesPath, 'style.css')]: '/style.css',
  });

  // Determine the effective input directory
  let inputDir = 'docs'; // Default input directory
  const cliInputArg = process.argv.find((arg) => arg.startsWith('--input='));
  if (cliInputArg) {
    inputDir = cliInputArg.split('=')[1];
  }

  // Calculate includes path relative to the effective input directory
  const includesPathRelative = path.relative(rootDir(inputDir), absoluteIncludesPath);

  return {
    markdownTemplateEngine: 'njk',
    dir: {
      input: inputDir,
      output: 'dist',
      includes: includesPathRelative,
    },
  };
};
