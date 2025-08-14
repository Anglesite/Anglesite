const path = require('path');

// Try to load plugins, but handle gracefully if they're not available
let webc, Nunjucks;
try {
  webc = require('@11ty/eleventy-plugin-webc');
} catch {
  console.warn('Warning: @11ty/eleventy-plugin-webc not available');
}

try {
  Nunjucks = require('nunjucks');
} catch {
  console.warn('Warning: nunjucks not available');
}

/**
 * @param eleventyConfig
 * @returns
 */
module.exports = function AnglesiteConfig(eleventyConfig) {
  console.log('Eleventy config: __dirname =', __dirname);
  console.log('Eleventy config: process.cwd() =', process.cwd());

  // The includes directory is always relative to this config file
  const absoluteIncludesPath = path.resolve(__dirname, 'includes');
  console.log('Eleventy config: absoluteIncludesPath =', absoluteIncludesPath);

  // Only add plugins if they're available
  if (webc) {
    eleventyConfig.addPlugin(webc, {
      components: path.join(absoluteIncludesPath, '**/*.webc'),
    });
  }

  if (Nunjucks) {
    eleventyConfig.setLibrary('njk', new Nunjucks.Environment(new Nunjucks.FileSystemLoader(absoluteIncludesPath)));
  }

  eleventyConfig.addPassthroughCopy({
    [path.join(absoluteIncludesPath, 'style.css')]: '/style.css',
  });

  // Ignore Claude Code configuration files
  eleventyConfig.ignores.add('.claude/**');

  // Determine the effective input directory
  // When using programmatic API, Eleventy will handle the input directory
  // We should not override it in the config
  let inputDir = '.'; // Default to current directory - Eleventy will override this
  const cliInputArg = process.argv.find((arg) => arg.startsWith('--input='));
  if (cliInputArg) {
    inputDir = cliInputArg.split('=')[1];
  }

  console.log('Eleventy config: Using inputDir =', inputDir);

  // Use absolute path for includes to avoid path resolution issues
  console.log('Eleventy config: Using absoluteIncludesPath for includes =', absoluteIncludesPath);

  // Always use _includes - each directory should have its own copy
  const includesPath = '_includes';

  console.log('Eleventy config: Using includesPath =', includesPath);

  return {
    markdownTemplateEngine: 'njk',
    dir: {
      // Don't specify input or output when using programmatic API - let Eleventy handle it
      // input: inputDir,
      // output: 'dist', // Remove this - let the programmatic API set the output directory
      includes: includesPath, // Use computed includes path
      layouts: includesPath, // Use same path for layouts
    },
  };
};
