# Astronomy Engine

Source: https://github.com/cosinekitty/astronomy

Commit: `865d3da7d8112bbc7911238052c6af4aaf877181`

Vendored files: `source/c/astronomy.c`, `source/c/astronomy.h`, root `LICENSE` (MIT). Files are unchanged.

`BlindOracleSky.c/.h` are application adapters, not upstream files. The engine contains its own analytic ephemeris coefficients; there are no network downloads or runtime data-file requirements. Application scope is explicitly limited to 1900–2100 and tropical geocentric coordinates.
