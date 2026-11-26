import { describe, it, expect, vi } from "vitest";
import {
  SelfWriteAnnouncingTransport,
  type EditorWriteMessage,
} from "../../src/host/self-write-transport.js";
import type { BlockModel, HostTransport, OpEnvelope, OpResult } from "../../src/types.js";

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
