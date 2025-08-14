#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

/**
 * Generate application icons from SVG source.
 */
function buildIcons() {
  // Check if ImageMagick is installed
  try {
    execSync('magick -version', { stdio: 'ignore' });
  } catch {
    console.error('Error: ImageMagick is not installed. Please install it first.');
    console.error('On macOS: brew install imagemagick');
    console.error('On Ubuntu/Debian: sudo apt-get install imagemagick');
    process.exit(1);
  }

  // Check if source SVG exists
  const sourceSvg = path.join('icons', 'src', 'icon.svg');
  if (!fs.existsSync(sourceSvg)) {
    console.error(`Error: Source icon not found at ${sourceSvg}`);
    process.exit(1);
  }

  // Create icons directory if it doesn't exist
  console.log('Preparing icons directory...');
  fs.mkdirSync('icons', { recursive: true });

  // Copy source SVG to icons directory
  fs.copyFileSync(sourceSvg, path.join('icons', 'icon.svg'));

  // Icon sizes to generate
  const sizes = [
    { size: '1024x1024', output: 'icon.png' },
    { size: '512x512', output: 'icon@2x.png' },
    { size: '256x256', output: '256x256.png' },
    { size: '128x128', output: '128x128.png' },
    { size: '64x64', output: '64x64.png' },
    { size: '48x48', output: '48x48.png' },
    { size: '32x32', output: '32x32.png' },
    { size: '24x24', output: '24x24.png' },
    { size: '16x16', output: '16x16.png' },
  ];

  console.log('Generating icon sizes...');

  sizes.forEach(({ size, output }) => {
    console.log(`  - Generating ${size} (${output})...`);
    const outputPath = path.join('icons', output);

    try {
      execSync(`magick "${sourceSvg}" -resize ${size} "${outputPath}"`, { stdio: 'ignore' });
    } catch (error) {
      console.error(`Failed to generate ${output}:`, error.message);
      process.exit(1);
    }
  });

  console.log('Icon generation complete!');
}

// Run the build
if (require.main === module) {
  buildIcons();
}
