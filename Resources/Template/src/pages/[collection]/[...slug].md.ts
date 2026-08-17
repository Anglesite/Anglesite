import type { APIContext } from "astro";
import { getCollection, type CollectionEntry } from "astro:content";
import { ENTRY_COLLECTIONS, type EntryCollection } from "../../lib/collections.ts";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "../../lib/markdown-mirror.ts";

export async function getStaticPaths() {
  const paths: Array<{
    params: { collection: string; slug: string };
    props: { entry: CollectionEntry<EntryCollection> };
  }> = [];
  for (const collection of ENTRY_COLLECTIONS) {
    const entries = await getCollection(collection);
    // Business types (events/reviews/announcements) have no `draft` key — see the identical
    // comment in `[collection]/[...slug].astro`, which this route mirrors exactly.
    const visible = entries.filter((entry) => (import.meta.env.PROD ? !(entry.data as any).draft : true));
    for (const entry of visible) {
      paths.push({ params: { collection, slug: entry.id }, props: { entry } });
    }
  }
  return paths;
}

export function GET(context: APIContext) {
  const { entry } = context.props as { entry: CollectionEntry<EntryCollection> };
  const collection = context.params.collection as string;
  const markdown = renderMarkdownMirror({
    collection,
    id: entry.id,
    data: entry.data,
    body: entry.body ?? "",
  });
  return new Response(markdown, { headers: { "Content-Type": MARKDOWN_MIRROR_CONTENT_TYPE } });
}
