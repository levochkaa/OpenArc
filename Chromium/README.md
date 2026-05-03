# Chromium fork overrides

`Chromium/chromium_src` contains Brave-style upstream WebUI overrides for the
project-local Chromium checkout.

The project-local checkout defaults to CEF branch `7778` and Chromium
`refs/tags/148.0.7778.96`. Override the Chromium checkout with
`THEBROWSER_CHROMIUM_CHECKOUT` when intentionally moving the Chromium base.

Run `./script/chromium_source.sh apply-overrides` after checkout, or use
`./script/chromium_source.sh package Debug Release` to apply the overrides before
GN project generation and CEF build.

For an override at `Chromium/chromium_src/path/to/file.ts`, the script copies the
upstream file to `path/to/file-chromium.ts` before replacing `path/to/file.ts`.
That lets the override import upstream code with `./file-chromium.js`.
