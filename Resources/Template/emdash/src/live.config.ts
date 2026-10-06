/**
 * EmDash's live content collection (#2050). Articles on an EmDash site are read from EmDash on
 * request, never from `src/content/` (ADR decision 2). The template's own `content.config.ts`
 * still declares its build-time collections; on an EmDash site they are empty.
 */
import { defineLiveCollection } from "astro:content";
import { emdashLoader } from "emdash/runtime";

export const collections = {
  _emdash: defineLiveCollection({ loader: emdashLoader() }),
};
