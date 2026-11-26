Closes #<!-- issue number this PR resolves, e.g. "123". Use a GitHub closing keyword (Closes/Fixes/Resolves) so the issue auto-closes on merge — a bare mention in prose does not link or close it. For more than one issue, repeat the keyword before each number, e.g. "Closes #123, closes #456" — a single keyword before a comma-separated list only closes the first. Delete this line only if the PR has no issue to close. -->

## Summary

<!-- The opener: 1–3 human-curated sentences — the shortest text that tells a reviewer what this PR is for and whether it deserves more of their attention. A screenshot is welcome for UI changes. Keep it outside the <details> block below. -->

<details>
<summary><!-- Agent-written PR? Name the model (and effort level, if any), e.g. "Claude Opus 5.5 Medium". Hand-written PR? Use "Details", or delete this block if the opener says it all. --></summary>

<!-- The full write-up: problem, approach, design notes, trade-offs. Leave a blank line after <summary> so GitHub renders the Markdown in here. -->

</details>

## Paired PR check

- [ ] This change is **self-contained** to `Anglesite/Anglesite`.
- [ ] This change **needs a paired PR** in [`Anglesite/anglesite-skills`](https://github.com/Anglesite/anglesite-skills) (MCP sidecar server). Link it here: <!-- e.g. Anglesite/anglesite-skills#123 -->

> Cross-cutting work (extending MCP messages) lands as paired PRs. The sidecar PR ships first in a tagged release; the app PR consumes it and re-vendors the container image. Template changes are app-only (`Resources/Template/`). See `CLAUDE.md` ▸ "Two-repo coordination".

## Test plan

- [ ] `swift test --package-path .`
- [ ] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
- [ ] Manual smoke (if UI-touching): <!-- describe -->
