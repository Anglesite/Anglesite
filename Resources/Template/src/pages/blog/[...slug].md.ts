import type { APIContext } from "astro";
import { getCollection, type CollectionEntry } from "astro:content";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "../../lib/markdown-mirror.ts";

export async function getStaticPaths() {
  const posts = await getCollection("blog", ({ data }) => (import.meta.env.PROD ? !data.draft : true));
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}

export function GET(context: APIContext) {
  const { post } = context.props as { post: CollectionEntry<"blog"> };
  const markdown = renderMarkdownMirror({
    collection: "blog",
    id: post.id,
    data: post.data,
    body: post.body ?? "",
  });
  return new Response(markdown, { headers: { "Content-Type": MARKDOWN_MIRROR_CONTENT_TYPE } });
}
