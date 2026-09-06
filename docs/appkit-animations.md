# AppKit animation contracts

The reference is the last SwiftUI implementation at `03d6aee`, before the AppKit migration. The timing parameters below belong to specific state changes; ordinary model notifications and live sidebar resizing must not restart them.

| State change | Timing | Animated appearance or geometry |
| --- | --- | --- |
| Pinned sidebar visibility | ease-in-out, 0.18 s | Sidebar position, page origin and width, toolbars, find overlay and content hit regions |
| Hover sidebar presentation | ease-in-out, 0.18 s; reveal delay 0.5 s | Sidebar horizontal position only; floating background, corners, vertical inset and height are prepared offscreen first |
| Bookmarks/site toolbar visibility and extension panel presentation | ease-in-out, 0.18 s | Reserved page geometry; bars move/fade from above, extension panel from the trailing edge |
| Web-app toolbar visibility | ease-in-out, 0.18 s | Toolbar and page/find geometry |
| Chrome, sidebar row, folder, app-tile and space-button presses | spring response 0.18 s, damping 0.72 | Existing scale, icon translation and rotation; both pressing and releasing |
| Chrome and bookmark hover | ease-out, 0.14 s | Hover background |
| App-tab reorder, pinned/temporary tab identities, pinned section/folder expansion | spring response 0.28 s, damping 0.82 | Row positions and insertion/removal opacity |
| Space pager selection / settling | ease-in-out, 0.18 s | Horizontal page offset; direct pointer/trackpad movement remains immediate |
| Drag-preview size | spring response 0.20 s, damping 0.86 | Tile/row dimensions; pointer position remains immediate |
| Current-URL action visibility | ease-in-out, 0.12 s | Action opacity and trailing URL mask |
| Copy feedback icon | spring response 0.22 s, damping 0.68 | Link/checkmark replacement, opacity and scale from/to 0.58; reset still occurs after 1 s |
| Pinned URL caption | ease-out, 0.16 s | Title displacement, caption movement from below and opacity |
| Pinned section disclosure | ease-in-out, 0.14 s | Chevron rotation when collapsed changes |
| Clear visibility | ease-in-out, 0.18 s | Opacity and divider length; Clear hover text uses ease-in-out, 0.12 s |
| Find and tab-switcher visibility / selected switcher card | ease-out, 0.12 s | Panel opacity / selected card colors |
| Command selection scroll | ease-out, 0.12 s | Minimum scroll needed to reveal the row, clamped to document bounds; no forced centering |
| Tooltip identity/visibility | ease-out, 0.14 s | Opacity; existing 1 s activation delay and 0.3 s cooldown remain in the tooltip coordinator |
| Update toast | ease-in-out, 0.18 s | Opacity and reserved sidebar-footer height |

`BrowserNativeAnimation` supplies the cubic easing and damped spring timing on the main run loop. The spring's response is its period parameter, not a fixed completion duration. Animation work respects Reduce Motion. Each owner retains its animation, cancels superseded work, and starts from the current displayed value.

Window frames advance as one batch before descendants lay out. This matters for native scroll views and the CEF host: assigning final AppKit frames and animating only backing layers can make their content lay out at the destination before the sidebar arrives. Sidebar width remains fixed while hiding; resizing updates immediately. `BrowserNativeFrameTransitions` also prevents repeated layout passes with identical targets from snapping row/pager animations to their ends.

Cmd+F uses the page rectangle in the normal and web-app roots. It follows the viewport below both toolbars and bookmarks, and stays outside extension-side-panel space.

The live window verifier samples intermediate sidebar/page geometry and checks find positioning while toggling bookmarks. The general verifier uses an actual New Tab mouse click, checks the last suggestion against the viewport bottom, and exercises keyboard, focus, and dismissal. Unit tests cover animation retargeting, timing endpoints/overshoot, button release before menu actions, title truncation beside the close button, and the rendered alignment of New Tab against its plus symbol in an offscreen, never-ordered window. See [appkit-ui.md](appkit-ui.md) for the commands.
