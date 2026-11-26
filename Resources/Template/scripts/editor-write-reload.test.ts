import test from "node:test";
import assert from "node:assert/strict";
import {
  EditorWriteLedger,
  fileVersion,
  handleEditorWriteMessage,
  siteRelativePath,
} from "./editor-write-reload.ts";

test("fileVersion matches the sidecar's content hash (server/file-version.mjs)", () => {
  // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  assert.equal(fileVersion("hello"), "sha256:2cf24dba5fb0");
});

test("siteRelativePath keeps paths inside the site and rejects the rest", () => {
  assert.equal(siteRelativePath("src/pages/index.astro"), "src/pages/index.astro");
  assert.equal(siteRelativePath("src/pages/../pages/about.md"), "src/pages/about.md");
  assert.equal(siteRelativePath("../outside.md"), null);
  assert.equal(siteRelativePath(".."), null);
  assert.equal(siteRelativePath("/etc/passwd"), null);
  assert.equal(siteRelativePath(""), null);
});

test("a change is the editor's own only when the file is exactly the settled version", async () => {
  const ledger = new EditorWriteLedger();
  ledger.expect("op1", "src/pages/index.astro");
  ledger.settle("op1", fileVersion("new text"));

  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "new text"), true);
  // Someone else changed the file again afterwards.
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "hand edit"), false);
  // A different file.
  assert.equal(await ledger.isOwnWrite("src/pages/about.md", () => "new text"), false);
});

test("a change with no announced write reloads as before", async () => {
  const ledger = new EditorWriteLedger();
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "anything"), false);
});

test("a write that failed settles as null and doesn't skip the reload", async () => {
  const ledger = new EditorWriteLedger();
  ledger.expect("op1", "src/pages/index.astro");
  ledger.settle("op1", null);
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "whatever"), false);
});

test("the decision waits for an announced write still in flight", async () => {
  const ledger = new EditorWriteLedger();
  ledger.expect("op1", "src/pages/index.astro");
  const decision = ledger.isOwnWrite("src/pages/index.astro", () => "typed");
  setTimeout(() => ledger.settle("op1", fileVersion("typed")), 20);
  assert.equal(await decision, true);
});

test("an announced write that never settles stops holding the reload after the timeout", async () => {
  const ledger = new EditorWriteLedger({ settleTimeoutMs: 30 });
  ledger.expect("op1", "src/pages/index.astro");
  const started = Date.now();
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "typed"), false);
  assert.ok(Date.now() - started < 1_000);
});

test("settled writes expire after the grace window", async () => {
  let now = 0;
  const ledger = new EditorWriteLedger({ now: () => now });
  ledger.expect("op1", "src/pages/index.astro");
  ledger.settle("op1", fileVersion("typed"));
  now = 10_000;
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "typed"), false);
  assert.equal(ledger.size, 0);
});

test("a second settle for the same op is ignored", async () => {
  const ledger = new EditorWriteLedger();
  ledger.expect("op1", "src/pages/index.astro");
  ledger.settle("op1", fileVersion("first"));
  ledger.settle("op1", fileVersion("second"));
  assert.equal(await ledger.isOwnWrite("src/pages/index.astro", () => "first"), true);
});

test("handleEditorWriteMessage validates the request body", async () => {
  const ledger = new EditorWriteLedger();
  assert.equal(handleEditorWriteMessage(ledger, undefined), 400);
  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "expect" }), 400);
  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "expect", path: "../x" }), 400);
  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "settle", version: 3 }), 400);
  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "other" }), 400);
  assert.equal(handleEditorWriteMessage(ledger, { id: "", phase: "expect", path: "x" }), 400);

  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "expect", path: "src/pages/a.md" }), 204);
  assert.equal(handleEditorWriteMessage(ledger, { id: "a", phase: "settle", version: fileVersion("z") }), 204);
  assert.equal(await ledger.isOwnWrite("src/pages/a.md", () => "z"), true);
  assert.equal(handleEditorWriteMessage(ledger, { id: "b", phase: "settle", version: null }), 204);
});
