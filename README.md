# Official application packages and signed UI feed

## Complete first-party application: 1.1.1

Source: https://github.com/QifengKuang/DeltaResolveAccelerator/commit/939c090745c25c501f203cbec775597a772140e8

Download [DeltaResolveApplication-1.1.1-win-x64.zip](packages/1.1.1/DeltaResolveApplication-1.1.1-win-x64.zip), [SHA256SUMS.txt](packages/1.1.1/SHA256SUMS.txt) and [application-manifest.json](packages/1.1.1/application-manifest.json). This bundle includes all twelve backend modules. It contains no SDK, runtime, credentials, personal settings or diagnostics. It is not a standalone installer and is not consumed by the legacy UI updater.

## Legacy signed UI-only feed: 1.1.0

The existing stable/delta-ui-manifest.json and signature remain unchanged. This feed only updates the UI and cannot distribute the 1.1.1 backend recovery fix. Use the complete package and its deployment instructions for that fix.
