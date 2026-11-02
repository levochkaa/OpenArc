# Agent access

`openarc` lets a shell or an AI agent drive a running OpenArc with the person's sign-ins. It is off until Settings > Let agents control OpenArc is on, which opens a Unix socket that only this user can reach (`~/Library/Application Support/OpenArc/agent.sock`) and links the command into `~/.local/bin`. Nothing listens on the network.

    openarc open https://example.com
    openarc snapshot -i
    openarc click @e3
    openarc fill @e5 "text"
    openarc screenshot page.png
    openarc close <tab>

Spaces and layout: `openarc spaces`, `openarc space new Work --color '#5B5BF0' --icon briefcase.fill`, `openarc space select Work`, `openarc pin`, `openarc split <url>`, `openarc commandbar <text>`. The website's videos were recorded this way, with the window in the background and no pointer or keyboard input.

`openarc help` lists everything, and `openarc skill` prints a guide for agents.

## MCP

Run `openarc mcp` as a stdio server. For Claude Code:

    claude mcp add openarc -- ~/.local/bin/openarc mcp

## Passwords

`openarc logins` returns site and username only. `openarc signin` shows the person a prompt, then the browser fills the saved password into the page's main frame. The agent never receives it. Scripts through `eval` stay refused on that page until it navigates, and `open` and `navigate` refuse `javascript:` addresses.

Limits: a program that can already read this user's files can also talk to the socket, so the setting trusts everything the user runs. Incognito windows are out of reach. A tab must be on screen for a screenshot to be reliable.

## Protocol

One JSON object per line: `{"id":1,"method":"snapshot","params":{"interactive":true}}`, answered by `{"id":1,"result":...}` or `{"id":1,"error":"..."}`. See `BrowserAgentService.handle`.
