# AppKit animation contracts

The reference is the last SwiftUI implementation at `1249546`, before the AppKit migration. The timing parameters below belong to specific state changes; ordinary model notifications and live sidebar resizing must not restart them.

| State change | Timing | Animated appearance or geometry |
| --- | --- | --- |
| Pinned sidebar visibility | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Sidebar position, page origin and width, toolbars, find overlay and content hit regions |
| Hover sidebar presentation | spring response 0.17 s, damping 0.8; reveal delay 0.07 s | Sidebar horizontal position only; the page stays put |
| Site toolbar and bookmarks bar visibility | immediate | Reserved page geometry |
| Extension panel presentation | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Reserved page geometry |
| Web-app toolbar visibility | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Toolbar and page/find geometry |
| Chrome, folder and app-tile presses | spring response 0.23 s, damping 0.72 | Existing scale, icon translation and clockwise rotation; both directions |
| Dock button press and hover | 0.13 s, timing (0.215, 0.61, 0.355, 1), scale 0.95 / 0.25 s, timing (0.25, 0.1, 0.25, 1) | Scale both ways / hover background |
| Sidebar row presses | spring response 0.2 s, damping 0.5 | Row scale to 0.985 and back, with a visible bounce |
| Chrome and bookmark hover | ease-out, 0.1 s | Hover background |
| Sidebar row hover and selection | immediate | Row background |
| Row close button, cross to minus | spring response 0.3 s, damping 0.6 | The two bars turn; the overshoot shows |
| Tabs opening and closing, pinned section expansion | 0.12 s, timing (0.25, 0.1, 0.25, 1) | Row positions and insertion/removal opacity |
| Rows placed by a drag | 0.12 s, timing (0, 0, 0.58, 1) | Row positions |
| Folder collapse / expand | 0.2 s, timing (0, 0, 0.58, 1) / 0.25 s, timing (0.25, 0.1, 0.25, 1) | Row positions |
| Folder icon | 0.25 s, timing (0.25, 0.1, 0.25, 1) | Panels swing in perspective, shades fade; tilted while collapsed |
| Floating menu | 0.1 s in, 0.07 s out, timing (0.215, 0.61, 0.355, 1); fade 0.05 s in | Scale 0.95 around the tail, opacity |
| Dock + menu trigger | on the press; a press longer than 0.3 s closes it again on release | |
| Reload and Stop | Stop after 0.5 s of loading; dissolve, ease-in-out, 0.1 s | Opacity, in place |
| Space pager selection and settling after a swipe | spring response 0.2 s, critically damped; committed before the tab switch, 0.05 s after a click or a swipe's release, whose velocity carries on; the theme fades 0.02 s after the slide starts | Horizontal page offset; a swipe moves the page by half of the scroll delta, turns it when quick (under 0.5 s) or past the middle |
| Theme cross-fade | 0.19 s, timing (0.215, 0.61, 0.355, 1) | Between Spaces |
| Library | spring response 0.2 s in; response 0.19 s out; both critically damped | Slides from the window edge and moves the page |
| Sidebar around the Library | 0.045 s linear out; 0.36 s, timing (0.15, 0.8, 0.2, 1), 0.05 s after the Library starts leaving, back | Opacity, and a scale to 0.95 about the middle of the Library's width and the window's height |
| Drag preview | none | Keeps the look and size it started with until the drop; the pointer position stays with the mouse-down grab point |
| Drop landing / cancellation | 0.12 s, timing (0.25, 0.1, 0.25, 1) | Preview travels to the final row/cell or merges into a collapsed container before the real rows are revealed |
| Current-URL action visibility | 0.15 s, timing (0, 0, 0.58, 1) / 0.12 s, same timing | Action opacity while the pointer is in the sidebar / trailing URL mask |
| Copy feedback icon | 0.4 s in; held 1.2 s; 0.3 s back | The link shrinks to 0.2 and fades in the first quarter, the check grows from 0.2 after a pause; on the way back the check leaves over 40 % and the link arrives from 11 % |
| Pinned URL caption | ease-in-out, 0.1 s | Title displacement, caption movement from below and opacity |
| Pinned section disclosure | spring response 0.3 s, damping 0.6 | Chevron rotation with its overshoot |
| Clear visibility | 0.1 s, timing (0, 0, 0.58, 1) | Opacity and divider length; Clear hover text uses ease-in-out, 0.12 s |
| Find visibility | immediate | Panel |
| Tab-switcher visibility / selected switcher card | immediate, after 0.05 s | Panel and card colors |
| Mini player hover | ease-in-out, 0.2 s to grow; ease-out, 0.17 s to shrink | Height, title and close button opacity; the player itself appears and leaves at once |
| Peek | card opens on stiffness 657.7, damping 44.37 and closes on 779.82, 49.99; the page behind uses the other one | The card grows from a strip around the pointer, wide as the page; the page dims to 0.3 and scales to 0.988 |
| Command selection scroll | ease-in-out, 0.05 s | Minimum scroll needed to reveal the row, clamped to document bounds; no forced centering |
| Tooltip visibility | at once after continuous hover: 0.43 s on buttons, 1.48 s on rows; out 0.3 s when the pointer leaves, 0.1 s otherwise; timing (0, 0, 0.58, 1) | Opacity; fades as soon as the pointer leaves; after a row's tooltip the next rows show none until the pointer has been away for 0.3 s |
| Update pill rising | spring, response 0.6, damping 0.4 | 32 pt slide and opacity on the same spring, room reserved at once |
| Update pill opening, closing | spring, response 0.33, damping 0.7; response 0.21, damping 0.9 | Height, after 0.3 s of hover; content opacity follows |
| Page loading bar | pulse 1.63 s up and down, twice; spring response 0.8 s, damping 0.92 to open; highlight 0.73 s of a 1.13 s cycle, linear; 0.33 s to close, timing (0.42, 0, 1, 1) | Opacity and width above the page; Reduce Motion shows a steady bar |

These timings are chosen on purpose:

- The command bar appears and leaves at once.

`BrowserNativeAnimation` supplies the cubic easing and damped spring timing on the main run loop. The spring's response is its period parameter, not a fixed completion duration. Animation work respects Reduce Motion. Each owner retains its animation, cancels superseded work, and starts from the current displayed value.

Rows, the Space pager, the page, the sidebar, the Library and the bars move on the render server with `BrowserNativeFrameTransitions.slide`: the frame is final at once and an additive `position` animation carries the distance, so a busy main thread cannot stall them and a move made during another adds to it. The page resizes once: it stays large enough to leave no gap while it moves and takes its final size at the end. A view leaving its superview keeps its frame until the end (`slideOut`), because AppKit stops showing a view above its siblings once its frame is outside. A view whose frame lies outside a clip stops drawing its text, so a Space page on its way out stays inside the clip until the slide ends, shown at its place by a fixed additive offset. Other geometry advances as one batch on the main run loop before descendants lay out. Sidebar width remains fixed while hiding; resizing updates immediately. `BrowserNativeFrameTransitions` also prevents repeated layout passes with identical targets from snapping row/pager animations to their ends.

Cmd+F uses the page rectangle in the normal and web-app roots. It follows the viewport below both toolbars and bookmarks, and stays outside extension-side-panel space.

The live window verifier samples intermediate sidebar/page geometry and checks find positioning while toggling bookmarks. The general verifier uses an actual New Tab mouse click, checks the last suggestion against the viewport bottom, and exercises keyboard, focus, and dismissal. Unit tests cover animation retargeting, timing endpoints/overshoot, button release before menu actions, title truncation beside the close button, and the rendered alignment of New Tab against its plus symbol in an offscreen, never-ordered window. See [appkit-ui.md](appkit-ui.md) for the commands.
