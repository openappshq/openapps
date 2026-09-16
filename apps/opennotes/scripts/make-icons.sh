#!/usr/bin/env bash
# Regenerates Sources/OpenNotes/Resources/{AppIcon.icns,MenuBarIcon*.png} from the
# SVG masters in design/assets. Outputs are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Sources/OpenNotes/Resources
swift scripts/render-icons.swift
