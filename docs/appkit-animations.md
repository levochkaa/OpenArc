# AppKit animation contracts

The reference is the last SwiftUI implementation at `1249546`, before the AppKit migration. The timing parameters below belong to specific state changes; ordinary model notifications and live sidebar resizing must not restart them.

| State change | Timing | Animated appearance or geometry |
| --- | --- | --- |
| Pinned sidebar visibility | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Sidebar position, page origin and width, toolbars, find overlay and content hit regions |
| Hover sidebar presentation | spring response 0.18 s, damping 0.8; reveal delay 0.5 s | Sidebar horizontal position only; floating background, corners, vertical inset and height are prepared offscreen first. Promotion to a pinned sidebar uses the pinned timing |
| Bookmarks/site toolbar visibility and extension panel presentation | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Reserved page geometry; bars move/fade from above, extension panel from the trailing edge |
| Web-app toolbar visibility | 0.08 s, timing (0.25, 0.46, 0.45, 0.94) | Toolbar and page/find geometry |
| Chrome, folder, app-tile and space-button presses | spring response 0.18 s, damping 0.72 | Existing scale, icon translation and rotation; both pressing and releasing |
| Sidebar row presses | spring response 0.2 s, damping 0.5 | Row scale to 0.985 and back, with a visible bounce |
| Chrome and bookmark hover | ease-out, 0.1 s | Hover background |
| App-tab reorder, pinned/temporary tab identities, pinned section/folder expansion | 0.12 s, timing (0, 0, 0.58, 1) | Row positions; insertion/removal opacity over 0.1 s |
| Space pager selection | 0.19 s, timing (0.215, 0.61, 0.355, 1) | Horizontal page offset and the theme cross-fade |
| Space pager settling after a swipe | spring response 0.25 s, critically damped | Horizontal page offset; direct pointer/trackpad movement remains immediate, with the theme following the finger |
| Drag-preview size | spring response 0.20 s, damping 0.86 | Tile/row dimensions around the mouse-down grab point; pointer position remains immediate |
| Drop landing / cancellation | spring response 0.28 s, damping 0.82 | Preview travels to the final row/cell or merges into a collapsed container before the real rows are revealed |
| Current-URL action visibility | ease-in-out, 0.12 s | Action opacity and trailing URL mask |
| Copy feedback icon | spring response 0.22 s, damping 0.68 | Link/checkmark replacement, opacity and scale from/to 0.58; reset still occurs after 1 s |
| Pinned URL caption | ease-out, 0.16 s | Title displacement, caption movement from below and opacity |
| Pinned section disclosure | ease-in-out, 0.14 s | Chevron rotation when collapsed changes |
| Clear visibility | ease-in-out, 0.18 s | Opacity and divider length; Clear hover text uses ease-in-out, 0.12 s |
| Find and tab-switcher visibility / selected switcher card | ease-out, 0.12 s | Panel opacity / selected card colors |
| Command selection scroll | ease-out, 0.12 s | Minimum scroll needed to reveal the row, clamped to document bounds; no forced centering |
| Tooltip identity/visibility | ease-out, 0.15 s | Opacity; existing 1 s activation delay and 0.3 s cooldown remain in the tooltip coordinator |
| Update toast | ease-in-out, 0.18 s | Opacity and reserved sidebar-footer height |
| Page loading bar | pulse 1.63 s, twice; spring response 0.8 s, damping 0.92 to open; highlight 0.73 s of a 1.13 s cycle, linear; 0.33 s to close, timing (0.42, 0, 1, 1) | Opacity and width above the page; Reduce Motion shows a steady bar |

These timings are chosen on purpose:

- Drop landing keeps its 0.28 s spring: it travels farther than a row move.
- Find, the tab switcher and command scrolling keep 0.12 s ease-out; the timings are tuned with their keyboard flows.
- The drag preview keeps its 0.2 s size spring; the preview changes size, not border and corner style.
- The command bar appears and leaves at once.

`BrowserNativeAnimation` supplies the cubic easing and damped spring timing on the main run loop. The spring's response is its period parameter, not a fixed completion duration. Animation work respects Reduce Motion. Each owner retains its animation, cancels superseded work, and starts from the current displayed value.

Window frames advance as one batch before descendants lay out. This matters for native scroll views and the CEF host: assigning final AppKit frames and animating only backing layers can make their content lay out at the destination before the sidebar arrives. Sidebar width remains fixed while hiding; resizing updates immediately. `BrowserNativeFrameTransitions` also prevents repeated layout passes with identical targets from snapping row/pager animations to their ends.

Cmd+F uses the page rectangle in the normal and web-app roots. It follows the viewport below both toolbars and bookmarks, and stays outside extension-side-panel space.

The live window verifier samples intermediate sidebar/page geometry and checks find positioning while toggling bookmarks. The general verifier uses an actual New Tab mouse click, checks the last suggestion against the viewport bottom, and exercises keyboard, focus, and dismissal. Unit tests cover animation retargeting, timing endpoints/overshoot, button release before menu actions, title truncation beside the close button, and the rendered alignment of New Tab against its plus symbol in an offscreen, never-ordered window. See [appkit-ui.md](appkit-ui.md) for the commands.
