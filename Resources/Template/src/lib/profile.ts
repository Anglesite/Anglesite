/**
 * Site representative profile (`src/data/profile.json`), shared by the h-card footer (Hcard.astro)
 * and the schema.org projection (schema.ts, V-1.8). The glob returns `{}` when the file is absent,
 * so an unconfigured site simply has no owner identity to project.
 */
const mods = import.meta.glob<{ default: Record<string, unknown> }>("../data/profile.json", {
  eager: true,
});

export interface SiteProfile {
  name?: string;
  url?: string;
  [key: string]: unknown;
}

export function siteProfile(): SiteProfile {
  return (Object.values(mods)[0]?.default ?? {}) as SiteProfile;
}

/** Whether `src/data/profile.json` exists at all — distinct from `siteProfile()`, which
 * collapses "absent" and "present but empty" to the same `{}` return value. */
export function profileExists(): boolean {
  return Object.keys(mods).length > 0;
}

/** The site owner's display name, when configured — used as the `author` of Article/BlogPosting. */
export function ownerName(): string | undefined {
  const name = siteProfile().name;
  return typeof name === "string" && name.length > 0 ? name : undefined;
}
