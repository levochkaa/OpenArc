# Agent access

`openarc` lets a shell or an AI agent drive a running OpenArc with the person's sign-ins. It is on by default and turns off in Settings > Let agents control OpenArc. While on, OpenArc opens a Unix socket that only this user can reach (`~/Library/Application Support/OpenArc/agent.sock`) and links the command into `~/.local/bin`. Nothing listens on the network.

    openarc open https://example.com
    openarc snapshot -i
    openarc click @e3
    openarc fill @e5 "text"
    openarc screenshot page.png
    openarc close <tab>

Spaces and layout: `openarc spaces`, `openarc space new Work --color '#5B5BF0' --icon briefcase.fill`, `openarc space select Work`, `openarc pin`, `openarc split <url>`, `openarc commandbar <text>`. The website's videos were recorded this way, with the window in the background and no pointer or keyboard input.

Open your own tab with `openarc open <url> --background`, so the page the person is looking at stays on screen, and pass `--tab <id>` to later commands. A tab in the background draws nothing, so a click there is sent as the page's own pointer and mouse events from a script rather than through the engine's input; hover and typing go through the engine as usual.

Reading a page: `snapshot -i` lists what can be acted on, `snapshot <@ref|selector>` one part of the page, and `snapshot -i --diff` only the lines that changed since the last snapshot with the same options. Same-site frames show under their frame; cross-site frames run in another process and are left out. `screenshot --annotate` draws each ref's box and name on the picture, `screenshot --element <target>` takes one element, `pdf [path]` prints the page.

Forms: `fill`, `choose <target> <option>` for list boxes, `check` and `uncheck`, `upload <target> <file>`, `hover`, `dblclick`. Layout checks: `viewport 390 844 --mobile`, then `viewport --reset`.

The person's own data, read-only: `history [words]` searches the pages they visited (the latest when no words are given), `notes [words]` and `note <id>` read their notes, `downloads` lists the browser's downloads. `download <url> [path]` fetches an address with the cookies the tab's profile has for it. `profiles` lists the profiles with open windows; `--profile <id>` sends any command to that profile's window.

`openarc help` lists everything, and `openarc skill` prints a guide for agents. `openarc skill install` adds a short `openarc` skill to every coding agent it finds (`~/.agents`, `~/.claude`, `~/.codex`, `~/.cursor`, `~/.config/opencode`), or to `--path <skills folder>`; it points the agent at `openarc skill`, so the guide stays as new as the browser.

## MCP

Run `openarc mcp` as a stdio server. For Claude Code:

    claude mcp add openarc -- ~/.local/bin/openarc mcp

Every command has a tool (`browser_snapshot`, `browser_click`, `browser_history`, `browser_notes`, `browser_download` and so on). Each takes an optional `profile` from `browser_profiles`.

## Passwords

`openarc logins` returns site and username only. `openarc signin` shows the person a prompt, then the browser fills the saved password into the page's main frame. The agent never receives it. Scripts through `eval` stay refused on that page until it navigates, and `open` and `navigate` refuse `javascript:` addresses.

Limits: a program that can already read this user's files can also talk to the socket, so the setting trusts everything the user runs; that includes the history, notes and cookies above. Incognito windows are out of reach, their history and notes too. A tab must be on screen for a screenshot to be reliable.

## Protocol

One JSON object per line: `{"id":1,"method":"snapshot","params":{"interactive":true}}`, answered by `{"id":1,"result":...}` or `{"id":1,"error":"..."}`. See `BrowserAgentService.handle`.
