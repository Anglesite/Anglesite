declare module "*microformat-shiv.cjs" {
  interface MicroformatShivOptions {
    node?: Node;
    html?: string;
    baseUrl?: string;
    filters?: string[];
  }

  interface MicroformatShivItem {
    type: string[];
    properties: Record<string, unknown[]>;
    children?: MicroformatShivItem[];
  }

  interface MicroformatShivDocument {
    items: MicroformatShivItem[];
    rels: Record<string, string[]>;
    "rel-urls": Record<string, { rels: string[]; text?: string }>;
  }

  interface MicroformatShivAPI {
    get(options?: MicroformatShivOptions): MicroformatShivDocument;
  }

  const Microformats: MicroformatShivAPI;
  export default Microformats;
}
