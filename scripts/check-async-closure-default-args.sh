#!/usr/bin/env bash
# Rejects an `async` closure parameter whose default value is a function or value reference
# (#1990): `gitCommitBatch: @Sendable (URL, [String], String) async -> String? = Inbox.processGitCommitBatch`.
#
# Swift 6.3.3 (Xcode 26.6, the toolchain CI's build-test lane runs) compiles that default into a
# `shared` implicit closure that is re-emitted in every client module omitting the argument, and
# the two copies do not agree on the async context size (defining module: 168 B of code needing a
# 64-byte context; client copy: 132 B needing 32). ld coalesces the function symbol and its async
# function pointer record independently, so a client can end up running the library's code with
# its own 32-byte record: the thunk overruns its context and later frees the wrong pointer —
# "freed pointer was not the last allocation", the build-test abort that blocked PR #1976. Whether
# the overrun hits live memory depends on where the context lands in the task allocator's slab,
# so the same call passes in one process and aborts in another. Swift 6.4 emits the same divergent
# pair; only link order has kept it from aborting there so far.
#
# The safe shape is an optional parameter resolved in the body, where the conversion is a private,
# single-copy closure:
#
#     gitCommitBatch: (@Sendable (URL, [String], String) async -> String?)? = nil
#     ...
#     let gitCommitBatch = gitCommitBatch ?? InboxSubmissionCommitter.processGitCommitBatch
#
# Scope: lines under Sources/ that declare a parameter whose type contains `async ->` and whose
# default is a dotted or bare identifier. `= nil` and closure literals (`= { … }`) are not flagged:
# a literal that itself awaits something is re-emitted the same way, but the trivial literals in
# this tree (`{ _ in }`, `{ [] }`, `{}`) have nothing to spill and no evidence of divergence yet.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

violations=()
while IFS=: read -r file line _; do
  violations+=("$file:$line")
done < <(git grep -n -E 'async -> [^=]*= *[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)* *[,)]?$' -- 'Sources/*.swift' | grep -v -E '= *nil *[,)]?$' || true)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "error: ${#violations[@]} async closure parameter(s) default to a function/value reference under Sources/:" >&2
  for v in "${violations[@]}"; do
    echo "  $v" >&2
  done
  echo >&2
  echo "Make the parameter optional (= nil) and resolve it in the body with \`??\` instead — see the" >&2
  echo "header of scripts/check-async-closure-default-args.sh (#1990) for why the default-argument form" >&2
  echo "aborts under Swift 6.3.3." >&2
  exit 1
fi

echo "ok: no async closure parameter defaults to a function/value reference under Sources/"
