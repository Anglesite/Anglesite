import type { MF2Document, MF2Item } from "./detect/microformats";

export interface FeedLink {
  title: string | null;
  url: string;
  type: "rss" | "atom" | "json";
}

export interface Findings {
  pageUrl: string;
  pageTitle: string;
  feeds: FeedLink[];
  webmentionUrl: string | null;
  activityPubUrl: string | null;
  relMeLinks: string[];
  mf2: MF2Document;
  mf2TypeCounts: Record<string, number>;
  hCard: MF2Item | null;
}
