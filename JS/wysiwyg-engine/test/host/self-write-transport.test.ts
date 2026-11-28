import { describe, it, expect, vi } from "vitest";
import {
  SelfWriteAnnouncingTransport,
  sameBlockTree,
  type EditorWriteMessage,
} from "../../src/host/self-write-transport.js";
import type { BlockModel, BlockNode, HostTransport, OpEnvelope, OpResult } from "../../src/types.js";

const model: BlockModel = { path: "src/pages/index.astro", version: "sha256:aaaaaaaaaaaa", rootIds: [], blocks: {} };

const editText: OpEnvelope = {
  id: "op-1",
  targetVersion: "sha256:000000000000",
  op: { kind: "editText", blockId: "t1", runs: [], previousRuns: [] },
};

function fakeInner(result: OpResult, log: string[] = []): HostTransport {
  return {
    sendOp: vi.fn(async () => {
      log.push("sendOp");
      return result;
    }),
    onModelUpdate: vi.fn(() => () => {}),
  };
}

describe("SelfWriteAnnouncingTransport (#2214)", () => {
  it("announces an editText write before sending it, then settles it with the new version", async () => {
    const log: string[] = [];
    const messages: EditorWriteMessage[] = [];
    const post = async (message: EditorWriteMessage) => {
      log.push(message.phase);
      messages.push(message);
    };
    const transport = new SelfWriteAnnouncingTransport(fakeInner({ status: "applied", model }, log), model.path, post);

    await expect(transport.sendOp(editText)).resolves.toEqual({ status: "applied", model });
    expect(log).toEqual(["expect", "sendOp", "settle"]);
    expect(messages).toEqual([
      { id: "op-1", phase: "expect", path: "src/pages/index.astro" },
      { id: "op-1", phase: "settle", version: "sha256:aaaaaaaaaaaa" },
    ]);
  });

  it("settles a rejected op as null, so the dev server doesn't skip a reload for it", async () => {
    const messages: EditorWriteMessage[] = [];
    const transport = new SelfWriteAnnouncingTransport(
      fakeInner({ status: "rejected", reason: "version-mismatch" }),
      model.path,
      async (message) => void messages.push(message),
    );

    await transport.sendOp(editText);
    expect(messages.at(-1)).toEqual({ id: "op-1", phase: "settle", version: null });
  });

  it("settles as null when the inner transport throws, and rethrows", async () => {
    const messages: EditorWriteMessage[] = [];
    const inner: HostTransport = { sendOp: async () => Promise.reject(new Error("bridge gone")), onModelUpdate: () => () => {} };
    const transport = new SelfWriteAnnouncingTransport(inner, model.path, async (message) => void messages.push(message));

    await expect(transport.sendOp(editText)).rejects.toThrow("bridge gone");
    expect(messages.at(-1)).toEqual({ id: "op-1", phase: "settle", version: null });
  });

  it("passes structural ops through without announcing them", async () => {
    const post = vi.fn(async () => {});
    const inner = fakeInner({ status: "applied", model });
    const transport = new SelfWriteAnnouncingTransport(inner, model.path, post);
    const insert: OpEnvelope = {
      id: "op-2",
      targetVersion: "v",
      op: { kind: "deleteBlock", blockId: "t1", previous: { parentId: "root", slot: "default", index: 0, block: { kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 1] } } },
    } as unknown as OpEnvelope;

    await transport.sendOp(insert);
    expect(post).not.toHaveBeenCalled();
    expect(inner.sendOp).toHaveBeenCalledWith(insert);
  });

  it("doesn't hold an op hostage to a slow dev server", async () => {
    vi.useFakeTimers();
    const inner = fakeInner({ status: "applied", model });
    const transport = new SelfWriteAnnouncingTransport(inner, model.path, () => new Promise(() => {}));

    const pending = transport.sendOp(editText);
    await vi.advanceTimersByTimeAsync(250);
    await expect(pending).resolves.toEqual({ status: "applied", model });
    vi.useRealTimers();
  });

  it("forwards model-update subscriptions to the inner transport", () => {
    const inner = fakeInner({ status: "applied", model });
    const transport = new SelfWriteAnnouncingTransport(inner, model.path, async () => {});
    const listener = () => {};
    transport.onModelUpdate(listener);
    expect(inner.onModelUpdate).toHaveBeenCalledWith(listener);
  });
});

describe("formatting edits still reload (#2243 review)", () => {
  const text = (id: string, value: string) => ({ id, kind: "text" as const, componentName: "", props: {}, slots: {}, sourceSpan: [0, 0] as [number, number], richText: [{ kind: "text" as const, text: value }] });
  const el = (id: string, tag: string, children: string[]): BlockNode => ({ id, kind: "element", componentName: tag, props: {}, slots: children.length ? { default: children } : {}, sourceSpan: [0, 0] });

  // The template's home page, roughly: <h1>Welcome</h1><p>Ready</p>.
  const before: BlockModel = {
    path: "src/pages/index.astro", version: "sha256:before000000", rootIds: ["n1", "n3"],
    blocks: { n1: el("n1", "h1", ["n2"]), n2: text("n2", "Welcome"), n3: el("n3", "p", ["n4"]), n4: text("n4", "Ready") },
  };
  // Plain text edit: same tree, new text.
  const retyped: BlockModel = { ...before, version: "sha256:retyped00000", blocks: { ...before.blocks, n2: text("n2", "Welcome home") } };
  // Add Link on "Welcome": <h1><a>Welcome</a></h1>. The sidecar renumbers in tree order, so the
  // <p> that was n3 is now n5, and n3 names the link's text.
  const linked: BlockModel = {
    path: "src/pages/index.astro", version: "sha256:linked000000", rootIds: ["n1", "n5"],
    blocks: { n1: el("n1", "h1", ["n2"]), n2: el("n2", "a", ["n3"]), n3: text("n3", "Welcome"), n5: el("n5", "p", ["n6"]), n6: text("n6", "Ready") },
  };

  it("sameBlockTree is true for a text change and false once markup was added", () => {
    expect(sameBlockTree(before, retyped)).toBe(true);
    expect(sameBlockTree(before, linked)).toBe(false);
  });

  async function settleFor(applied: BlockModel): Promise<string | null | undefined> {
    const messages: EditorWriteMessage[] = [];
    const transport = new SelfWriteAnnouncingTransport(
      fakeInner({ status: "applied", model: applied }),
      before.path,
      async (message) => void messages.push(message),
      () => before,
    );
    await transport.sendOp(editText);
    const settle = messages.find((m) => m.phase === "settle");
    return settle?.phase === "settle" ? settle.version : undefined;
  }

  it("a plain text edit settles with its version, so the dev server keeps the page", async () => {
    expect(await settleFor(retyped)).toBe("sha256:retyped00000");
  });

  it("an edit that added a link settles as null, so the page reloads and its block marks are rebuilt", async () => {
    expect(await settleFor(linked)).toBeNull();
  });
});
