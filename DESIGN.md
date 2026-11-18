# OpenArc design direction

This file is input for UI work. Read it before running `antislop`, which acts as the filter. Every rule below gives its reason, and any change to a rule should keep one.

## Scope

OpenArc has two kinds of surface, and they follow different rules:

- **Browser chrome.** This covers the sidebar, command bar, toolbar, Library, and settings. It stays native AppKit and takes its color from the user's Space colors and the system appearance; `docs/appkit-ui.md` describes it. It carries no brand color: the person's pages and Spaces are what they look at there.
- **Branded moments.** These are the first-run welcome, the website (openarc.su), the About window, and release pages. They share the identity below, so that the app someone opens looks like the page they downloaded it from.

## Read

Reading this as: a first-run welcome and website for people moving from a browser that is shutting down. The visual language is the site's: a flat blue field, cream rounded type, and one red action. Dial ENERGY 2 / RHYTHM 2 / MOTION 1.

Who reads it: someone who has just installed OpenArc to keep their way of browsing. They want their Spaces, pins and sign-ins back fast. The welcome sets OpenArc up, and every step can be skipped.

## Identity

- **Blue field.** Electric blue `#3139FB` covers the whole surface, with fine grain (white noise at 7% alpha). The site's hero uses it, and the welcome's first and last screens use it. Reason: it is the brand's one color, and the flat field with grain reads as printed rather than as a glowing gradient.
- **Cream paper.** `#FFFCEC` is the background of the working steps (import, look, default browser), with blue headings, as on the site's sections. Reason: these steps hold app icons, checkboxes and lists, which read best on a quiet ground. Blue stays the bookend.
- **One red action.** The primary button on every step is `#E5262B` with white text, and nothing else is red. Reason: the site's single red download button. This red is a shade deeper than the site's `#FF3333` so that white text reaches 4.52:1.
- **The arch mark (motif).** The `^` arch from the app icon and the site's top bar heads the blue screens. Keycaps drawn as cream outlines show shortcuts on the last screen. These two shapes make the screens OpenArc's and no one else's.
- **No gradients, no glow, no orbs, no endless motion.** The old welcome's drifting purple-to-pink gradient is exactly what this rule removes.

## Color

| Token | Value | Use |
| --- | --- | --- |
| `brandBlue` | `#3139FB` | blue field, headings on paper, selection ring |
| `cream` | `#FFFADD` | type on blue |
| `paper` | `#FFFCEC` | ground of the working steps |
| `ink` | `#1B1D3A` | body text on paper |
| `muted` | `#5B5B6B` | secondary text on paper |
| `actionRed` | `#E5262B` | primary button, white text |
| `tile` | `#F3EFD6` | browser tiles on paper |

Contrast: cream on blue is 6.42:1; blue on paper 6.56:1; ink on paper 15.88:1; muted on paper 6.46:1; white on actionRed 4.52:1.

The welcome keeps these colors in dark mode too. It is a branded moment, like the site, and it sets the window to the light appearance so that native checkboxes match the paper.

## Type

- SF Pro Rounded, heavy, for headlines (`--display` on the site). Reason: the brand voice; the rounded face is the app's own system font, with no font file to ship.
- SF Pro for body text and labels.
- Sentence case. No uppercase labels with letter-spacing, and no monospace for decoration.

## Shape and depth

- Radii: 14 for browser tiles and cards, 9 for buttons, 5 for keycaps. Three radii, one for each kind of thing.
- No shadows on content. The selected tile is marked by a 2 pt blue ring, not by elevation.

## Layout

- One focal point per step. Welcome: the headline. Import: the browser tiles. Look: the two sidebar pictures. Default: the question. Done: the keycaps.
- RHYTHM 2: blue bookends with centered type, and paper steps aligned to the left with actions at the bottom right.
- The primary action sits at the bottom right, answers Return, and stays red. Skip or Not now sits beside it as a quiet text button.

## Motion

MOTION 1: steps crossfade in 0.25 s, and nothing loops. With Reduce Motion on, steps switch without a fade.

## Icons

Use real app icons for browsers (from NSWorkspace). Draw the sidebar positions as small window schematics. Use no SF Symbols as decoration and no sparkles.

## Copy

Keep it plain and specific: "Import from Arc", "Use OpenArc by default", "Start browsing". Do not write "Get started", "seamless" or "powerful". Use no em dashes. Give no numbers except real counts of what was imported.
