#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORK="$(mktemp -d)"
trap 'rm -rf "$TEST_WORK"' EXIT
cd "$ROOT"
"${XTOOL_HOST_SWIFTC:-swiftc}" -swift-version 6 -o "$TEST_WORK/project-checks" \
  Sources/XToolMobileCore/MobileBuildBackend.swift \
  Sources/XToolMobileCore/MobileProject.swift \
  Sources/XToolMobileCore/PreparedToolchain.swift \
  Sources/XToolMobileCore/MobileSwiftSDKConfiguration.swift \
  Sources/XToolMobileCore/MobileAppProject.swift \
  Sources/XToolMobileCore/MobileAppStarter.swift \
  Sources/XToolMobileCore/MobileProjectBuilder.swift \
  Sources/XToolMobileCore/MobileBuildLogRecovery.swift \
  Sources/XToolMobileCore/MobileModuleCache.swift \
  Sources/XToolMobileCore/MobileWorkspaceTools.swift \
  Sources/XToolMobileCore/MobileIPAPackager.swift \
  Tests/MobileProjectTests/ProjectPipelineChecks.swift
"$TEST_WORK/project-checks"
python3 -m unittest discover -s Tests/MobileProjectTests -p 'test_*.py'
