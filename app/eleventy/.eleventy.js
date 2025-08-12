const path = require('path');

// Try to load plugins, but handle gracefully if they're not available
let webc, Nunjucks;
try {
  webc = require('@11ty/eleventy-plugin-webc');
} catch (e) {
  console.warn('Warning: @11ty/eleventy-plugin-webc not available');
}

try {
  Nunjucks = require('nunjucks');
} catch (e) {
  console.warn('Warning: nunjucks not available');
}

/**
 * Returns an absolute path relative to the project root.
 * @param relativePath Path relative to the project root.
 * @returns
 */
function rootDir(relativePath) {
  // In packaged apps, use __dirname to find the app root
  // In dev, use process.cwd()
  const isPackaged = process.env.NODE_ENV === 'production' || !process.env.NODE_ENV;
  const appRoot = isPackaged 
    ? path.resolve(__dirname, '..', '..')  // From dist/app/eleventy/ to dist/
    : process.cwd();
  return path.resolve(appRoot, relativePath);
}

/**
 * @param eleventyConfig
 * @returns
 */
module.exports = function AnglesiteConfig(eleventyConfig) {
  console.log('Eleventy config: __dirname =', __dirname);
  console.log('Eleventy config: process.cwd() =', process.cwd());
  
  const absoluteIncludesPath = rootDir('app/eleventy/includes');
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

  return {
    markdownTemplateEngine: 'njk',
    dir: {
      // Don't specify input when using programmatic API - let Eleventy handle it
      // input: inputDir,
      output: 'dist',
      includes: absoluteIncludesPath,  // Use absolute path
    },
  };
};
