export interface FeedLink {
  title: string | null;
  url: string;
  type: "rss" | "atom" | "json";
}
