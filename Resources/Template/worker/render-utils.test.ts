import { describe, expect, test } from "vitest";
import { imageMediaTypeForUrl } from "./render-utils.ts";

describe("imageMediaTypeForUrl (#1770)", () => {
  test.each([
    ["https://media.example/a.jpg", "image/jpeg"],
    ["https://media.example/a.jpeg", "image/jpeg"],
    ["https://media.example/a.png", "image/png"],
    ["https://media.example/a.gif", "image/gif"],
    ["https://media.example/a.webp", "image/webp"],
    ["https://media.example/a.avif", "image/avif"],
    ["https://media.example/a.heic", "image/heic"],
  ])("maps %s to %s", (url, mediaType) => {
    expect(imageMediaTypeForUrl(url)).toBe(mediaType);
  });

  test("matches the extension case-insensitively", () => {
    expect(imageMediaTypeForUrl("https://media.example/IMG_0001.JPG")).toBe("image/jpeg");
  });

  test("reads the extension from the path, ignoring query and fragment", () => {
    expect(imageMediaTypeForUrl("https://media.example/a.png?w=1200&fmt=.gif#frag.jpg")).toBe("image/png");
  });

  test("returns undefined for an unknown extension rather than guessing", () => {
    expect(imageMediaTypeForUrl("https://media.example/a.bmp")).toBeUndefined();
    expect(imageMediaTypeForUrl("https://media.example/a.tiff")).toBeUndefined();
  });

  test("returns undefined when the path has no extension", () => {
    expect(imageMediaTypeForUrl("https://media.example/opaque-id")).toBeUndefined();
    expect(imageMediaTypeForUrl("https://media.example/dir.with.dots/")).toBeUndefined();
  });

  test("tolerates a relative or otherwise unparsable URL by falling back to the raw string", () => {
    expect(imageMediaTypeForUrl("/media/a.webp")).toBe("image/webp");
    expect(imageMediaTypeForUrl("/media/a.webp?x=1")).toBe("image/webp");
    expect(imageMediaTypeForUrl("")).toBeUndefined();
  });
});
