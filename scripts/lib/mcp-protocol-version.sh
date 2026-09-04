#!/usr/bin/env bash
# Extracts the MCP protocol version this app build expects — the single source of truth is
# `MCPClient.protocolVersion` in Sources/AnglesiteCore/AI/MCPClient.swift. Shared by
# vendor-container-image.sh (stamps Resources/container-image/vendor-manifest.json with the
# version in effect at vendor time) and check-container-resources.sh (compares that stamp
# against the current value on every build, so a protocol bump that outpaces a locally vendored
# image is caught at build time instead of surfacing as an opaque MCP-connect HTTP error).
# Source this file, then call mcp_protocol_version.

mcp_protocol_version() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local file="$root/Sources/AnglesiteCore/AI/MCPClient.swift"
    local version
    version="$(grep -m1 'public static let protocolVersion' "$file" | sed -E 's/.*"([^"]+)".*/\1/')"
    if [[ -z "$version" ]]; then
        echo "ERROR: could not extract MCPClient.protocolVersion from $file" >&2
        return 1
    fi
    echo "$version"
}
