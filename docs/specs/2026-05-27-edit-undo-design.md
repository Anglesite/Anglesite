# Per-edit undo — HEAD-only revert via the hidden `anglesite/edits` branch

**Status:** approved — ready for implementation
**Note (2026-09-08, #1957):** the chat row's Undo button and the `undo_edit` revert described here remain; the ⌘Z bridge (`EditUndoCoordinator`, #527) was removed with the click-to-edit overlay — the window's Edit ▸ Undo now belongs to the block editor's own inverse ops and structural content operations.
**Tracks:** [Anglesite-app#33](https://github.com/Anglesite/Anglesite-app/issues/33) — Phase 9 step 4 of [build-plan.md](../build-plan.md#phase-9--v1-multi-site--drag-drop-images)
**Cross-repo:** paired PR against [Anglesite/anglesite](https://github.com/Anglesite/anglesite) for the new `undo_edit` MCP tool
**Date:** 2026-05-27

## Motivation

Every successful `apply_edit` on a site already commits the post-patch file content to the hidden `refs/heads/anglesite/edits` branch (per Phase 5 step 4, `server/edit-history.mjs`). The branch is durable, append-only, and accurate — but today it's invisible to the owner. Phase 9 step 4 surfaces it: every edit shows up in the chat panel as a row with an inline **Undo** button, and clicking Undo rewinds the most-recent edit by writing the parent commit's blob back to disk.

The scope deliberately stays at **HEAD-only undo** for v1: only the most-recent edit's row has an enabled Undo button. After an undo, the row above it becomes the new head and its Undo enables. This keeps the v1 model trivially correct (git revert HEAD is always safe inside the hidden branch) while still covering the realistic case — "I just did something wrong, take it back." Multi-level revert (undoing an arbitrary past edit while preserving subsequent ones), redo, and time-travel scrubbing are out of scope; the architecture deliberately doesn't preclude them.

## Behavior

### Chat-panel rendering

A new `Role.edit` joins the existing `user / assistant / system / error` cases on `ChatModel.Message`. Edit rows show:

- The file that was edited (`src/pages/about.astro`), relative path within the site.
- A relative timestamp ("2 min ago") that updates on a 1-min tick while the chat is visible.
- An inline **Undo** button — enabled only on the row that corresponds to the current `refs/heads/anglesite/edits` HEAD. Earlier rows render the button disabled-grey. After an undo, the row's button is replaced with a small "Undone" marker; the row's metadata is updated to reflect the new state.

The visual treatment is intentionally restrained: a single line with a left-edge color stripe matching the existing system-message style, the Undo button right-aligned. No file diff, no SHA, no expanded view.

### The Undo click

Clicking Undo invokes the plugin's new `undo_edit` MCP tool (see *New MCP tool* below). Three outcomes the UI handles:

1. **Clean undo** — the on-disk file matches what the hidden branch recorded post-edit (the typical case). The plugin writes the parent commit's blob back to disk and advances the hidden branch with a new commit (`undo edit <file>`). The chat row marks itself "Undone." The Astro dev server's filesystem watcher picks up the write and reloads the preview.
2. **Working-tree drift** — the on-disk file differs from the hidden-branch HEAD's blob (the owner edited the file externally via Finder/VS Code/CLI between the edit and the Undo click). The undo is **refused** with a `working-tree-modified` reason; the UI presents a small modal sheet: *"This file has been modified outside Anglesite since the edit. Undoing will overwrite those changes."* with **Undo anyway** / **Cancel** buttons. **Undo anyway** re-invokes `undo_edit` with `force: true`; the plugin skips the working-tree check and writes the blob back, losing any uncommitted external changes. (If the owner had committed those changes to another git branch, the commits survive in git's normal reflog — but Anglesite has no UI to recover them; "Cancel" + opening the file externally is the safer path.)
3. **Write failure** — permissions, missing directory, disk-full, etc. The plugin returns `undo-refused` with reason `write-failed` and a detail string. The chat row's Undo button disables; an inline `.error` system message appears: *"Couldn't undo: <detail>"*.

### What counts as "edit happened"?

Every `EditReply` with `status: .applied` **AND** a non-nil `commit` field from `MCPApplyEditRouter` corresponds to a new commit on the hidden branch and gets a chat row. (Replies with `status: .applied` but `commit == nil` happen when the site isn't a git repo — those don't surface in chat because there's nothing to undo against.) The router gains an optional `onEdit` observer parameter; `SiteWindow.loadAndStart` wires it to `ChatModel.recordEdit(_:)`. The observer fires after the JS overlay's `evaluateJavaScript` reply but before the next edit can land — the chat-row append is effectively serialized with the edit pipeline.

## Prerequisite: structured `EditReply` (Phase 9.3 loose-end fix)

The Swift `EditReply` struct in `Sources/AnglesiteBridge/EditRouter.swift` is currently `{ id, status, message? }`. The plugin's structured reply (`{ type, id, file, range, commit, result? }`) gets stuffed into `message` as a JSON-string blob. Phase 9.3's image-drop overlay code was unit-tested in jsdom by passing structured replies directly, but in production those structured fields aren't extracted — the JS would have to parse `message` as JSON to recover `result.src` / `result.srcset`. This is a latent bug from Phase 9.3 that the smoke test didn't catch because the smoke went directly to the MCP server, not through the WKWebView bridge.

Phase 9.4 fixes it because the undo affordance needs structured access to `commit` from Swift. The struct becomes:

```swift
public struct EditReply: Sendable, Equatable, Encodable {
    public let id: String
    public let status: Status
    public let message: String?
    /// The source file the patch landed on (relative path within the site).
    public let file: String?
    /// SHA of the commit on refs/heads/anglesite/edits that captures this edit.
    public let commit: String?
    /// Op-scoped metadata. For `replace-image-src` carries `{ src, srcset? }`.
    public let result: ImageResult?

    public struct ImageResult: Sendable, Equatable, Encodable {
        public let src: String
        public let srcset: String?
    }
}
```

`MCPApplyEditRouter.apply` parses the plugin's `content[0].text` (the JSON-encoded edit-applied body) into those fields. The JS overlay receives a structured object — no client-side JSON parse needed; the TS `EditReply` interface from Phase 9.3 (`result?`, `detail?`, `reason?`) lines up with the wire format Swift now emits.

## Architecture

```
SiteWindow (existing)
  ├─ PreviewModel (existing)
  │      └ MCPApplyEditRouter (extended)
  │           ├ parses structured reply fields
  │           └ optionally invokes onEdit observer
  │                  │
  │                  ▼
  ├─ ChatModel (extended)
  │      ├ .recordEdit(EditReply) → append Message(role: .edit, editMetadata: …)
  │      ├ .undoEdit(messageID)   → calls UndoCommand
  │      └ tracks current head SHA (the most-recent unundone .edit row's commit)
  │
  └─ ChatView (extended)
        └ MessageRow handles .edit role
             ├ render: file + relative time + Undo button
             ├ Undo enabled iff message.commit == model.currentHeadSHA
             └ click → ChatModel.undoEdit(messageID)

AnglesiteCore (existing module)
  └─ UndoCommand (new)
        ├ public func undo(commit:force:) async -> UndoResult
        └ wraps MCPClient.callTool("undo_edit", { commit, force })

Plugin server (../anglesite)
  └─ server/undo-edit.mjs (new module)
        └ MCP tool handler: read HEAD, diff with parent, check working tree,
          write parent blobs to disk, advance branch with new commit
```

### `ChatModel.Message` extensions

```swift
enum Role: Equatable { case user, assistant, system, error, edit }

struct EditMetadata: Equatable, Codable {
    let file: String
    let commit: String
    var undone: Bool
}

// On Message:
var editMetadata: EditMetadata?
```

The JSONL persistence schema gains the optional `editMetadata` field. Older entries don't carry it; `ChatHistoryStore.decode` treats it as `nil` when absent. New entries with `role: .edit` always carry it.

### `ChatModel.currentHeadSHA`

Derived from `messages`: the latest message whose `role == .edit` and `editMetadata.undone == false`. Updated reactively whenever a row's `undone` flag flips or a new `.edit` row appends. The view binds Undo-enabled-state to `message.editMetadata?.commit == model.currentHeadSHA`.

After an undo, `currentHeadSHA` shifts to the row above the undone one. If there's no prior `.edit` row (the undone row was the first), `currentHeadSHA` becomes `nil` and no row has an enabled Undo button.

## Data flow

### Edit happens

```
1. Overlay: postEdit({ op, value, ... })
2. AnglesiteScriptHandler decodes, routes to MCPApplyEditRouter
3. MCPApplyEditRouter calls MCP apply_edit, parses content[0].text
4. EditReply { id, status: .applied, file, commit, result } returned
5. AnglesiteScriptHandler.evaluateJavaScript(reply) → overlay applies UI updates
6. MCPApplyEditRouter.onEdit?(reply) → ChatModel.recordEdit(reply)
7. ChatModel appends Message(role: .edit, editMetadata: { file, commit, undone: false })
8. ChatHistoryStore.append persists the new row
9. ChatView re-renders; the new row's Undo button is enabled (it's now the head)
```

### Undo click — happy path

```
1. ChatView Undo click → ChatModel.undoEdit(messageID)
2. ChatModel finds message, extracts editMetadata.commit
3. Calls UndoCommand.undo(commit: commit, force: false)
4. UndoCommand calls MCPClient.callTool("undo_edit", { commit, force: false })
5. Plugin's undo-edit handler:
     - parent = git rev-parse <commit>^
     - for each file in tree-diff(HEAD, parent):
         - hash the on-disk file's content via `git hash-object <file>`
         - if hash ≠ HEAD's blob for that file → record drift, abort
     - if all match: for each file, write parent's blob content to disk
     - advance refs/heads/anglesite/edits to a new commit with the parent's tree
6. Plugin returns { status: "undone", newCommit: <sha> }
7. UndoCommand maps to UndoResult.success(newCommit)
8. ChatModel.undoEdit:
     - sets message.editMetadata.undone = true
     - persists the update (see "Persistence of updates" below)
     - currentHeadSHA recomputes to the next un-undone edit row above (or nil)
9. ChatView re-renders; the undone row shows "Undone", the prior row's Undo enables
10. Astro dev server's file watcher picks up the write; preview reloads
```

### Undo click — working-tree drift

```
1–6 above proceed identically.
6'. Plugin returns { status: "refused", reason: "working-tree-modified", files: [...] }
7'. UndoCommand maps to UndoResult.workingTreeModified(files: [...])
8'. ChatModel presents a warn-and-confirm sheet (via a @Bindable conflictPrompt)
9'. User clicks "Undo anyway" → ChatModel re-invokes UndoCommand.undo(commit, force: true)
     - the plugin skips the working-tree check on force: true; happy path resumes
10'. Or user clicks Cancel → no-op, sheet dismisses
```

## Persistence of updates

The chat history is append-only JSONL. Marking a row `undone` is a mutation, which JSONL doesn't model directly. Two options were considered:

- **Append a synthetic "undone" record** that references the original's id. On load, post-process: any message whose id appears in an "undone" record gets `editMetadata.undone = true`. Keeps the file strictly append-only; load is O(n) over the file.
- **Rewrite the file** with the updated row. Simpler in memory but loses the JSONL invariant; risk of partial-write corruption.

Phase 9.4 picks **append a synthetic "undone" record**. The existing JSONL entries are message rows that decode via `Message.init(persisted:)`. The new record is a distinct shape — `ChatHistoryStore` recognizes it by a top-level `"kind": "undone"` key (existing message rows have a `role` field but no `kind`). The wire format:

```jsonl
{ "kind": "undone", "messageID": "<UUID>", "newCommit": "<sha>", "timestamp": "…" }
```

`ChatHistoryStore.load` reads the file linearly; for each line it attempts to detect the record kind. Message rows decode as before. "undone" records are accumulated in a side-map (`messageID → newCommit`) that gets applied after the message array is built — each referenced message's `editMetadata.undone` flips to `true`. Existing record loading is unchanged; the new code path is purely additive.

## New plugin module — `server/undo-edit.mjs`

The plugin's `server/` directory gains one new file and one new MCP tool registration in `server/index.mjs`.

### MCP tool signature

```
Name: undo_edit
Description: Revert the most-recent commit on refs/heads/anglesite/edits by writing
             the parent commit's blobs back to disk and advancing the branch.

Arguments:
  commit  (optional string) - SHA to undo. Must equal current HEAD of
                              anglesite/edits. Future versions may relax this
                              for arbitrary-commit undo; v1 enforces head-only.
  force   (optional bool, default false) - when true, skip the working-tree
                                            modification check.
```

### Handler outline

```javascript
export async function undoEdit({ commit, force = false }, projectRoot) {
    const head = await currentHistoryHead(projectRoot);
    if (!head) return { status: "refused", reason: "no-edits-to-undo" };
    if (commit && commit !== head) return { status: "refused", reason: "head-only-mode" };

    const parent = await execFileP("git", ["rev-parse", `${head}^`], { cwd: projectRoot });
    if (!parent) return { status: "refused", reason: "initial-commit" };

    // Files touched in this commit
    const filesOut = await execFileP("git", ["diff", "--name-only", parent, head], { cwd: projectRoot });
    const files = filesOut.split("\n").filter(Boolean);

    if (!force) {
        const drifted = [];
        for (const file of files) {
            const onDiskHash = await execFileP("git", ["hash-object", file], { cwd: projectRoot });
            const headBlobHash = await execFileP("git", ["rev-parse", `${head}:${file}`], { cwd: projectRoot });
            if (onDiskHash !== headBlobHash) drifted.push(file);
        }
        if (drifted.length) return { status: "refused", reason: "working-tree-modified", files: drifted };
    }

    // Write parent's blob content to disk for each file
    for (const file of files) {
        const content = await execFileP("git", ["show", `${parent}:${file}`], { cwd: projectRoot });
        writeFileSync(join(projectRoot, file), content);
    }

    // Advance the hidden branch with a new commit whose tree matches parent's tree
    const parentTree = await execFileP("git", ["rev-parse", `${parent}^{tree}`], { cwd: projectRoot });
    const message = `undo: ${files.join(", ")}`;
    const newCommit = await execFileP("git", ["commit-tree", parentTree, "-p", head, "-m", message], {
        cwd: projectRoot,
        env: { GIT_AUTHOR_NAME: "Anglesite", GIT_AUTHOR_EMAIL: "edits@anglesite.local", ... },
    });
    await execFileP("git", ["update-ref", "refs/heads/anglesite/edits", newCommit, head], { cwd: projectRoot });

    return { status: "undone", newCommit };
}
```

The handler uses `execFile` (not the shell) for every git invocation — same defensive pattern as `recordEdit`.

### Schema additions

`server/messages.mjs`'s `EDIT_FAILED_REASONS` gains four new reasons. They're only emitted by `undo_edit` but live in the same enum for consistency:

```javascript
"no-edits-to-undo",       // hidden branch is empty
"head-only-mode",         // commit arg didn't match HEAD (v1 enforces)
"initial-commit",         // can't undo back past the first edit
"working-tree-modified",  // file drifted; surfaced to UI's warn-confirm sheet
```

## Error handling

| Failure | UX |
|---|---|
| `working-tree-modified` | Warn-and-confirm sheet (modal). Confirm → re-call with `force: true`. Cancel → no-op. |
| `write-failed` (permissions, disk-full) | Row's Undo disables. Inline `.error` system message: *"Couldn't undo: <detail>"*. |
| `no-edits-to-undo` / `initial-commit` | Row's Undo disables; no message. (Shouldn't normally reach the user — UI only enables Undo on the head row.) |
| `head-only-mode` | Same as above. (Internal sanity check; v1 always sends the head SHA so this can't fire.) |
| MCP not running | Row's Undo disables transiently (bound to `MCPClient?.isReady`); re-enables when MCP reconnects. |
| Git binary missing / non-repo site | `recordEdit` still appends the `.edit` row but its Undo is disabled with help-text *"Undo requires the site to be a git repo."* `currentHeadSHA` returns nil. |

## Testing

### Plugin side (`../anglesite`)

`test/undo-edit.test.js` (new):

- Sets up a tmp git repo, runs one `apply_edit` against a fixture astro file, then `undo_edit` with no args.
- Asserts: on-disk file matches pre-edit content; `refs/heads/anglesite/edits` has a new commit on top whose tree equals the original; the new commit's parent is the edit's commit (linearized, not amended).
- Cases:
  - Clean undo (happy path).
  - Working-tree-modified refusal: edit a file externally between commit and undo, expect `working-tree-modified` reason with the file name.
  - Force-override: same as above but with `force: true`, expect clean undo + the external changes overwritten.
  - Non-git-repo: project root isn't a git repo, expect `working-tree-modified`-equivalent or `not-a-repo` reason (whichever the implementation picks; the test pins it).
  - Empty hidden branch: `undo_edit` without any prior `apply_edit`, expect `no-edits-to-undo`.
  - Initial-commit guard: only one edit on the branch with no prior commit reachable via `^`, expect `initial-commit`.
  - Head-only mode mismatch: pass a `commit` that isn't HEAD, expect `head-only-mode`.

### App side

`MCPApplyEditRouterTests` (extended):

- New test: given a fake `toolCaller` that returns a structured `apply-edit-applied` body, the router's reply carries `file`, `commit`, `result` as parsed Swift properties (not a JSON string in `message`).
- New test: malformed plugin reply (the text isn't valid JSON) falls back to the existing `message`-string behavior — backward compatibility.

`ChatModelTests` (new tests in the existing file):

- `recordEdit(reply)` appends a `.edit` message with the right metadata.
- `recordEdit` then `undoEdit(messageID)` against a mocked `UndoCommand`:
  - On `.success(newCommit)`: message's `editMetadata.undone` becomes true; `currentHeadSHA` shifts to the prior edit row (or nil if there's no prior).
  - On `.workingTreeModified(files)`: sets a `conflictPrompt` binding that the view consumes; no mutation to the message until `confirmConflict()` is called, which retries with `force: true`.
  - On `.failed(reason)`: appends an inline `.error` system message; original `.edit` row's `undone` stays false but flagged unrecoverable.
- A second `undoEdit` on an already-undone row is a no-op.

`ChatHistoryStoreTests` (extended):

- `.edit` messages round-trip via JSONL including their `editMetadata`.
- A trailing `{ kind: "undone", messageID, newCommit }` record flips the referenced message's `undone` flag on load.

`ChatViewTests` (light, optional given existing patterns):

- New `MessageRow` variant for `.edit` role renders the file + time + Undo button. Undo's `disabled` state binds to `commit == currentHeadSHA`.

### Smoke fixture

The existing `scripts/create-smoke-fixture.sh` checklist gains a step 6:

```
6. Edit a paragraph in the preview (click → type → blur). A new "Edited
   src/pages/<file>.astro · just now [Undo]" row appears in the chat.
   Click Undo → the edit reverts in the preview; the row shows "Undone";
   the chat input is unblocked.
```

## Out of scope (deferred)

- **Multi-level undo.** Per-row Undo on older edits (with conflict resolution between intervening edits) is genuinely useful but adds order-of-magnitude UI and merge complexity. v2.
- **Redo.** The hidden branch's history makes this mechanically simple, but the UI (a redo button? automatically? on the row that was undone?) needs its own design pass. v2.
- **Time-travel slider.** A scrubber UI to move to an arbitrary past state. v2.
- **Diff sheet for conflicts.** Today the warn-confirm sheet just says "the file has been modified" — it doesn't show what changed. v2.
- **Cross-session persistence beyond chat-history.jsonl.** The existing JSONL replay reconstructs the undone state correctly across app restarts. No separate `.anglesite/edit-state.json` needed.
- **Undo of an image drop with optimize variants.** This *works* in v1 because the dispatcher's commit captures both `src` and `srcset` rewrites in one commit, and the patcher's range covers the whole `<img>` tag. The orphan WebP variants in `public/images/` aren't cleaned up by undo — they're harmless extras. A v2 cleanup pass could remove them.
- **Notifications for edits made via other interfaces.** If the owner edits via CLI/Finder while the app is open, the hidden branch doesn't reflect that; chat shows nothing. Acceptable v1 behavior — chat only mirrors the Anglesite-mediated edit stream.
