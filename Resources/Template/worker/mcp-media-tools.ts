/**
 * Hand-rolled MCP owner tools for the media endpoint (#1578): `@dwk/micropub` has no
 * `createMicropubMcpTools`-equivalent adapter for media yet (only `micropub_publish`), so these
 * two tools are built directly on its exported media primitives (`createMicropubMediaStore`) plus
 * the `MEDIA` R2 binding — deliberately minimal, matching the design doc's "manage media" scope:
 * list + upload only, no delete/undelete (deferred).
 *
 * @see docs/superpowers/specs/2026-08-30-mcp-owner-tools-design.md
 */
import { createMicropubMediaStore, type MicropubMediaStore } from "@dwk/micropub";
import { DEFAULT_LIMIT, MAX_LIMIT } from "@dwk/micropub";
import type { ToolDefinition } from "@dwk/mcp";

const REQUIRED_SCOPE = "media";

/**
 * `@dwk/micropub`'s `media.d.ts` declares `MEDIA_EXTENSIONS`, but the installed
 * `1.0.0-beta.3`'s public `index.js` doesn't actually re-export it (a types/runtime mismatch —
 * `node -e "import('@dwk/micropub').then(m => console.log(Object.keys(m)))"` confirms it's
 * absent, and the package's `exports` map blocks reaching `dist/media.js` directly to work
 * around it). Mirrored here rather than blocked on an upstream fix; keep in sync if the upstream
 * list changes.
 */
const SUPPORTED_MEDIA_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
  "video/mp4": "mp4",
  "audio/mpeg": "mp3",
};

function clampLimit(value: unknown): number {
  const n = typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : DEFAULT_LIMIT;
  return Math.min(Math.max(n, 1), MAX_LIMIT);
}

function clampOffset(value: unknown): number {
  const n = typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0;
  return Math.max(n, 0);
}

export interface MicropubMediaToolsConfig {
  readonly mediaEndpoint: string;
  readonly maxMediaBytes: number;
  readonly media: R2Bucket;
  readonly store: MicropubMediaStore;
}

/** Decode a base64 string into raw bytes, or `null` if it isn't valid base64. */
function decodeBase64(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

export function createMicropubMediaMcpTools(config: MicropubMediaToolsConfig): ToolDefinition[] {
  return [
    {
      name: "micropub_media_list",
      description: "List this site's uploaded media (newest first)",
      inputSchema: {
        type: "object",
        properties: {
          limit: { type: "number", description: `Max rows to return (1-${MAX_LIMIT}, default ${DEFAULT_LIMIT})` },
          offset: { type: "number", description: "Rows to skip (default 0)" },
        },
      },
      requiredScope: REQUIRED_SCOPE,
      annotations: { readOnlyHint: true },
      async handler(args) {
        const page = { limit: clampLimit(args.limit), offset: clampOffset(args.offset) };
        const rows = await config.store.list(page);
        if (rows.length === 0) {
          return { content: [{ type: "text", text: "No media uploaded yet." }] };
        }
        const text = rows
          .map((r) => `${config.mediaEndpoint}/${r.key} — ${r.contentType}, ${r.sizeBytes} bytes`)
          .join("\n");
        return { content: [{ type: "text", text }] };
      },
    },
    {
      name: "micropub_media_upload",
      description: "Upload a media file (image/audio/video) to this site's media library",
      inputSchema: {
        type: "object",
        properties: {
          contentBase64: { type: "string", description: "The file's bytes, base64-encoded" },
          contentType: {
            type: "string",
            description: `MIME type of the upload. Supported: ${Object.keys(SUPPORTED_MEDIA_TYPES).join(", ")}`,
          },
        },
        required: ["contentBase64", "contentType"],
      },
      requiredScope: REQUIRED_SCOPE,
      annotations: { readOnlyHint: false, destructiveHint: false },
      async handler(args) {
        const contentType = typeof args.contentType === "string" ? args.contentType : "";
        const extension = SUPPORTED_MEDIA_TYPES[contentType];
        if (!extension) {
          return {
            isError: true,
            content: [
              {
                type: "text",
                text: `Unsupported content type "${contentType}". Supported: ${Object.keys(SUPPORTED_MEDIA_TYPES).join(", ")}`,
              },
            ],
          };
        }
        const bytes = typeof args.contentBase64 === "string" ? decodeBase64(args.contentBase64) : null;
        if (!bytes) {
          return { isError: true, content: [{ type: "text", text: "contentBase64 is not valid base64." }] };
        }
        if (bytes.byteLength > config.maxMediaBytes) {
          return {
            isError: true,
            content: [{ type: "text", text: `Upload exceeds the ${config.maxMediaBytes}-byte limit.` }],
          };
        }
        const key = `${crypto.randomUUID()}.${extension}`;
        await config.media.put(key, bytes, { httpMetadata: { contentType } });
        await config.store.record({ key, contentType, sizeBytes: bytes.byteLength, now: Math.floor(Date.now() / 1000) });
        const url = `${config.mediaEndpoint}/${key}`;
        return {
          content: [{ type: "resource_link", uri: url, name: key, mimeType: contentType }],
        };
      },
    },
  ];
}

export { createMicropubMediaStore };
