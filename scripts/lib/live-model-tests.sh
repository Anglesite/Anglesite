#!/usr/bin/env bash
# Single source of truth for the test suites that issue *live* on-device
# FoundationModels turns (`SystemLanguageModel.default` + `LanguageModelSession`),
# consumed by scripts/swift-test.sh to decide whether a `--filter` run needs the
# machine-scoped test lock (#1594).
#
# Why a hand-maintained list rather than a grep: 28 files under Tests/ import
# FoundationModels for its types, but only the suites below actually call the
# model — and it's live inference, not the import, that contends on the
# system-wide inference queue. Names are the `<target>.<suite>` prefixes SwiftPM's
# `swift test --filter` regex is matched against (`<target>.<suite>/<test>`).
#
# Inclusion rule: a suite belongs here if any of its tests gates on
# `SystemLanguageModel.default.availability` and then talks to the model. To
# find candidates: `grep -rlE 'SystemLanguageModel|LanguageModelSession' Tests/`.
export LIVE_MODEL_TEST_SUITES=(
  AnglesiteCoreTests.FoundationModelAssistantTests            # Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift
  AnglesiteCoreTests.GenerableTypesTests                      # Tests/AnglesiteCoreTests/GenerableTypesTests.swift
  AnglesiteCoreTests.FoundationModelAssistantToolWiringTests  # Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
)
