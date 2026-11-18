# Chromium fork overrides

`Chromium/chromium_src` contains Brave-style upstream WebUI overrides for the
project-local Chromium checkout.

Each file is a full copy of a CEF 156.0.31+ge603d97 / Chromium 156.0.8078.100
source with OpenArc's changes. `cef/patch/patches` holds CEF's own patches with
OpenArc's changes folded in, applied before CEF's project generation.

`./script/cef_remote_build.sh build` applies them on the Linux build host
([docs/cef-build.md](../docs/cef-build.md)). On a Mac checkout, run
`./script/chromium_source.sh apply-overrides`, or `package` to apply them before
GN project generation and the CEF build. Override the Chromium checkout with
`OPENARC_CHROMIUM_CHECKOUT` when intentionally moving the Chromium base.

For an override at `Chromium/chromium_src/path/to/file.ts`, the script copies the
upstream file to `path/to/file-chromium.ts` before replacing `path/to/file.ts`.
That lets the override import upstream code with `./file-chromium.js`.
