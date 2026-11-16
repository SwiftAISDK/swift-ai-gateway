# Changelog

## 1.4.0

- Language requests use the V4 call-option shape Gateway reads; results parse usage, finish reason and response metadata; streams forward error, file, custom, approval and response-metadata parts without duplicate tool calls. Authentication, malformed-body and network errors match upstream, observability headers are sent on Vercel, `availableModels()` caches for five minutes (`metadataCacheRefreshMillis`), a custom team header wins and `GatewayTools.exaSearch` and `GatewayRealtimeAuth` are added. Image, video and speech bodies and media errors match upstream; `maxImagesPerCall` is unlimited.
  Compatibility: Source-compatible; changes are additive. Request bodies, results, warnings and errors change to match the reviewed upstream package.
