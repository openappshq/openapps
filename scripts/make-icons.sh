#!/usr/bin/env bash
# Regenerates Sources/OpenReaction/Resources/{AppIcon.icns,MenuBarIcon*.png}
# from the SVG masters in design/assets. Outputs are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Sources/OpenReaction/Resources
swift scripts/render-icons.swift
