import type { UserConfig } from "@11ty/eleventy";

/**
 * @file Eleventy configuration file.
 * @param {UserConfig} eleventyConfig Eleventy UserConfig object.
 * @returns {UserConfig}
 * @see {@link https://www.11ty.dev/docs/config/}
 */
export default function (eleventyConfig: UserConfig) {
  return {
    dir: {
      input: "src",
      output: "dist",
    },
  };
}
