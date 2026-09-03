# POSSE Syndication Implementation Plan

**Status:** historical

**Goal:** Cross-post explicitly opted-in entries to Mastodon/Bluesky after deploy and write the
returned URLs back to canonical source as published `u-syndication` metadata.

- [x] Add site-scoped non-secret configuration and secret-store account keys.
- [x] Add deterministic bounded post-copy construction.
- [x] Implement injectable Mastodon and Bluesky API clients with stable idempotency identifiers.
- [x] Add the per-site crash-repair ledger and actor-serialized command orchestration.
- [x] Wire POSSE into `DeployModel` as an independent best-effort post-deploy task.
- [x] Extend strict template schemas and render `u-syndication` links.
- [x] Cover request shape, character bounds, end-to-end write-back, idempotency, and repair in tests.
- [x] Run focused Swift tests, an Astro production render, and the full macOS app build. The
  aggregate Swift suite reached and passed the POSSE tests, then stalled in the existing shared
  test harness; focused affected suites all pass.
