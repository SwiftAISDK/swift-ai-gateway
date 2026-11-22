# Changelog

## 1.5.0

- Add native Extraction V4, route-aware Realtime Live sessions and typed access-policy denial details. Existing turn-based sessions and their token workflow remain available. Reviewed npm: @ai-sdk/gateway 4.0.146 to 4.0.152. Offline validation passed: node Scripts/test-packages.mjs (56 packages, 3672 owning tests and 1760 compatibility tests), generation, tooling, isolation, and version selection. See Docs/Archive/WeeklyUpstreamAudit20261122.md for retained gaps. Paid provider calls were skipped.
  Compatibility: Additive factories and metadata. Requires SwiftAI Core 1.7.0 for source-compatible structured errors and correct retry handling.
