# Complete application 1.1.1

Source: https://github.com/QifengKuang/DeltaResolveAccelerator/commit/939c090745c25c501f203cbec775597a772140e8

This archive contains the UI, launcher, configuration, icon and all twelve first-party backend scripts, together with build provenance. See application-manifest.json and SHA256SUMS.txt. It excludes PowerShell, the MNA SDK, device credentials, user settings and diagnostics; obtain runtime dependencies and a separately authorized device key before use.

This is not a package for the legacy UI-only automatic updater or a standalone fresh-install executable. Use the complete build/deployment documentation from the source repository. Existing installations must receive the matching backend as well as the UI while the accelerator is stopped.

Validation: source and installed backend comparison; offline regression; installation checks; complete bundle checks. Two live connect/probe/stop/reconnect cycles passed on the original computer on 2026-09-19. No forced reboot was performed.
