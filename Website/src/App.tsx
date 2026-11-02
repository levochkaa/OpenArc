import { type CSSProperties, useEffect, useMemo, useState } from "react";

type ReleaseChannel = "stable" | "beta";

type ReleaseAsset = {
  id: number;
  name: string;
  contentType: string;
  size: number | null;
  downloadCount: number | null;
  downloadURL: string;
};

type BrowserRelease = {
  id: number;
  tagName: string;
  name: string;
  channel: ReleaseChannel;
  isLatestStable: boolean;
  publishedAt: string | null;
  htmlURL: string;
  notes: string;
  assets: ReleaseAsset[];
};

type ReleasesResponse = {
  releases: BrowserRelease[];
};

type ReleasesState = "loading" | "ready" | "error";

const sourceUrl = "https://github.com/levochkaa/OpenArc";
const fallbackDownloadUrl = "https://github.com/levochkaa/OpenArc/releases/latest";
const releasesApiUrl = import.meta.env.VITE_RELEASES_API_URL ?? "https://api.openarc.su/v1/releases";
const releaseDateFormatter = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  year: "numeric",
});
const ancillaryAssetNamePattern = /(^|[.\-_\s])(blockmap|checksum|checksums|debug|dsym|manifest|metadata|sha256|sha512|signature|symbols?)([.\-_\s]|$)/i;

const spaces = [
  {
    name: "Work",
    from: "#3b2bd6",
    to: "#c23bd8",
    pinned: ["Calendar", "Mail", "Docs"],
    tabs: ["Launch plan", "Design review", "Pull requests"],
  },
  {
    name: "Home",
    from: "#f2643d",
    to: "#f7b733",
    pinned: ["Bank", "Recipes", "Music"],
    tabs: ["Flights to Lisbon", "Sofa, again", "Weekend trails"],
  },
  {
    name: "Study",
    from: "#0d8f7f",
    to: "#7ad94f",
    pinned: ["Notes", "Library", "Cards"],
    tabs: ["Linear algebra", "Swift concurrency", "Reading list"],
  },
];

const commandScenes = [
  {
    query: "split",
    rows: [
      { kind: "command", title: "Add Split View", key: "⌃⇧=" },
      { kind: "search", title: "split" },
      { kind: "tab", title: "Split View: notes from last week" },
      { kind: "command", title: "Add Top Split" },
    ],
  },
  {
    query: "pull",
    rows: [
      { kind: "search", title: "pull" },
      { kind: "tab", title: "Pull requests" },
      { kind: "page", title: "Pull request #482", detail: "github.com" },
      { kind: "page", title: "Pull-up progressions", detail: "example.com" },
    ],
  },
  {
    query: "@y lo-fi",
    rows: [
      { kind: "search", title: "lo-fi", detail: "Search YouTube" },
      { kind: "page", title: "lofi hip hop radio", detail: "youtube.com" },
      { kind: "page", title: "Lo-fi for coding", detail: "youtube.com" },
    ],
  },
];

const importItems = [
  "Spaces and pinned tabs",
  "Bookmarks",
  "Passwords",
  "History",
  "Sign-ins",
  "Extensions",
  "Site searches",
];

const agentLines = [
  ["$ openarc open github.com/pulls", ""],
  ["$ openarc snapshot -i", ""],
  ["", '- link "Merge queue" [ref=e4]'],
  ["", '- button "Review" [ref=e9]'],
  ["$ openarc click @e9", ""],
  ["$ openarc signin", ""],
  ["", "OpenArc asks you. The agent never sees the password."],
];

const details = [
  ["Chrome extensions", "Your extensions, from the Chrome Web Store, with the tabs API they expect."],
  ["Passkeys", "Touch ID, your phone or a security key."],
  ["Translation", "In place, on the page you are reading."],
  ["Peek and Little windows", "Look at a link without losing where you were."],
  ["Picture in Picture", "Video follows you across Spaces and tabs."],
  ["Your toolbar", "Hide it, or drag exactly the buttons you want onto it."],
];

function usePrefersReducedMotion() {
  const [reduced] = useState(
    () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true,
  );
  return reduced;
}

function BrowserMock() {
  const reduced = usePrefersReducedMotion();
  const [index, setIndex] = useState(0);
  const [held, setHeld] = useState(false);

  useEffect(() => {
    if (reduced || held) {
      return;
    }
    const timer = window.setInterval(() => setIndex((value) => (value + 1) % spaces.length), 3600);
    return () => window.clearInterval(timer);
  }, [reduced, held]);

  const space = spaces[index];
  return (
    <div
      className="mock"
      style={{ "--from": space.from, "--to": space.to } as CSSProperties}
      role="img"
      aria-label="OpenArc's window, with a sidebar of tabs that changes color with each Space"
    >
      <aside className="mock-sidebar">
        <div className="mock-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div className="mock-address">example.com</div>
        <div className="mock-space-name">{space.name}</div>
        <ul className="mock-pinned">
          {space.pinned.map((title) => (
            <li key={title}>
              <b />
              {title}
            </li>
          ))}
        </ul>
        <div className="mock-divider" />
        <div className="mock-new">+ New Tab</div>
        <ul className="mock-tabs">
          {space.tabs.map((title, position) => (
            <li className={position === 0 ? "selected" : undefined} key={title}>
              <b />
              {title}
            </li>
          ))}
        </ul>
        <div className="mock-dots">
          {spaces.map((item, position) => (
            <button
              aria-label={`Show the ${item.name} Space`}
              className={position === index ? "on" : undefined}
              key={item.name}
              onClick={() => {
                setHeld(true);
                setIndex(position);
              }}
              type="button"
            />
          ))}
        </div>
      </aside>
      <div className="mock-page" aria-hidden="true">
        <h3>{space.tabs[0]}</h3>
        <p />
        <p />
        <p className="short" />
        <div className="mock-page-cards">
          <span />
          <span />
          <span />
        </div>
      </div>
    </div>
  );
}

function CommandDemo() {
  const reduced = usePrefersReducedMotion();
  const [scene, setScene] = useState(0);
  const [typed, setTyped] = useState(reduced ? commandScenes[0].query.length : 0);

  useEffect(() => {
    if (reduced) {
      return;
    }
    const query = commandScenes[scene].query;
    const delay = typed < query.length ? 110 : 2600;
    const timer = window.setTimeout(() => {
      if (typed < query.length) {
        setTyped(typed + 1);
      } else {
        setScene((scene + 1) % commandScenes.length);
        setTyped(0);
      }
    }, delay);
    return () => window.clearTimeout(timer);
  }, [reduced, scene, typed]);

  const current = commandScenes[scene];
  const done = typed >= current.query.length;
  return (
    <div className="command" aria-hidden="true">
      <div className="command-field">
        <span className="command-glass" />
        {current.query.slice(0, typed)}
        <span className="command-caret" />
      </div>
      <ul className={done ? "command-rows shown" : "command-rows"}>
        {current.rows.map((row, position) => (
          <li className={position === 0 ? "selected" : undefined} key={row.title + position}>
            <span className={`command-icon ${row.kind}`} />
            <span className="command-title">{row.title}</span>
            {"detail" in row && row.detail ? <span className="command-detail">{row.detail}</span> : null}
            {"key" in row && row.key ? <kbd>{row.key}</kbd> : null}
            {row.kind === "tab" ? <span className="command-switch">Switch to Tab →</span> : null}
          </li>
        ))}
      </ul>
    </div>
  );
}

function App() {
  const [releases, setReleases] = useState<BrowserRelease[]>([]);
  const [releasesState, setReleasesState] = useState<ReleasesState>("loading");

  useEffect(() => {
    const controller = new AbortController();

    fetch(releasesApiUrl, { signal: controller.signal })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Release lookup failed with ${response.status}`);
        }

        return response.json() as Promise<ReleasesResponse>;
      })
      .then((payload) => {
        setReleases(payload.releases);
        setReleasesState("ready");
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === "AbortError") {
          return;
        }

        setReleasesState("error");
      });

    return () => {
      controller.abort();
    };
  }, []);

  const latestStableRelease = useMemo(
    () => releases.find((release) => release.isLatestStable) ?? releases.find((release) => release.channel === "stable"),
    [releases],
  );
  const latestDownloadUrl = getPrimaryMacOSAsset(latestStableRelease?.assets ?? [])?.downloadURL ?? fallbackDownloadUrl;

  return (
    <main>
      <section className="hero" aria-labelledby="hero-title">
        <nav className="topbar" aria-label="Primary">
          <a className="brand" href="#top" aria-label="OpenArc home">
            <span className="brand-mark" aria-hidden="true" />
            <span>OpenArc</span>
          </a>
          <div className="nav-pill">
            <a href="#spaces">Tour</a>
            <a href="#agents">Agents</a>
            <a href="#releases">Releases</a>
            <a href={latestDownloadUrl}>Download</a>
          </div>
        </nav>
        <div className="hero-copy" id="top">
          <h1 id="hero-title">The browser you loved, still open.</h1>
          <p className="hero-text">
            A free, open-source browser for Mac with the sidebar, Spaces and command bar you already know. Bring your
            whole Arc across in a minute and keep going.
          </p>
          <div className="hero-actions" aria-label="Download actions">
            <a className="button primary" href={latestDownloadUrl}>
              Download for macOS
            </a>
            <a className="button ghost" href={sourceUrl}>
              Read the source
            </a>
          </div>
        </div>
        <BrowserMock />
      </section>

      <section className="band band-paper" id="spaces" aria-labelledby="spaces-title">
        <div className="band-text">
          <h2 id="spaces-title">Your internet, in rooms.</h2>
          <p>
            A Space for work and another for everything else, each with its own color, its own pins and its own
            profile if you want. Tabs tidy themselves up when you stop needing them, and nothing you pinned goes
            anywhere.
          </p>
        </div>
        <ul className="sticker-row" aria-label="What a Space keeps">
          <li className="sticker sticker-violet">Pinned tabs</li>
          <li className="sticker sticker-coral">Folders</li>
          <li className="sticker sticker-green">Favorites</li>
          <li className="sticker sticker-sun">Auto-archive</li>
        </ul>
      </section>

      <section className="band band-ink" aria-labelledby="command-title">
        <div className="band-text">
          <h2 id="command-title">One bar. Everything.</h2>
          <p>
            Press ⌘T and type. Open tabs in every Space, your whole history, bookmarks, site searches and every command
            in the browser, ranked as you type and forgiving of typos.
          </p>
        </div>
        <CommandDemo />
      </section>

      <section className="band band-coral" aria-labelledby="split-title">
        <div className="band-text">
          <h2 id="split-title">Two pages. One window.</h2>
          <p>Split a tab with ⌃⇧=, up to four panes, and drag anything into place. Hover a pane and it leans in.</p>
        </div>
        <div className="split" aria-hidden="true">
          <div>
            <b />
            <p />
            <p />
            <p className="short" />
          </div>
          <div>
            <b />
            <p />
            <p className="short" />
          </div>
          <div>
            <b />
            <p />
            <p />
          </div>
        </div>
      </section>

      <section className="band band-paper" aria-labelledby="import-title">
        <div className="band-text">
          <h2 id="import-title">Move in over lunch.</h2>
          <p>
            The welcome window finds Arc, Chrome and Dia on your Mac and copies what you pick. Your other browser stays
            exactly as it was, and everything stays on your Mac.
          </p>
        </div>
        <ul className="checklist">
          {importItems.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </section>

      <section className="band band-ink" id="agents" aria-labelledby="agents-title">
        <div className="band-text">
          <h2 id="agents-title">Lend your browser to an agent.</h2>
          <p>
            Turn it on in Settings and agents can open, read and click through the <code>openarc</code> command or its
            MCP server, with your real sign-ins. Passwords are typed by the browser after you agree, so they never
            reach the agent. Nothing listens on the network.
          </p>
        </div>
        <pre className="terminal" aria-label="An agent using the openarc command">
          {agentLines.map(([command, output]) => (
            <span className={command ? "terminal-command" : "terminal-output"} key={command + output}>
              {command || output}
              {"\n"}
            </span>
          ))}
        </pre>
      </section>

      <section className="band band-paper" aria-labelledby="details-title">
        <div className="band-text">
          <h2 id="details-title">And the rest of a real browser.</h2>
          <p>Chromium underneath, a native Mac app on top, and no account to make.</p>
        </div>
        <dl className="details">
          {details.map(([term, description]) => (
            <div key={term}>
              <dt>{term}</dt>
              <dd>{description}</dd>
            </div>
          ))}
        </dl>
      </section>

      <section className="releases" id="releases" aria-labelledby="releases-title">
        <div className="section-heading">
          <h2 id="releases-title">Every build, and every download.</h2>
        </div>
        <ReleaseList releases={releases} state={releasesState} />
      </section>

      <section className="download" aria-labelledby="download-title">
        <div>
          <h2 id="download-title">Open it.</h2>
          <p>Free and MIT-licensed, for macOS. You can read every line.</p>
        </div>
        <a className="button primary download-button" href={latestDownloadUrl}>
          Download latest
        </a>
      </section>

      <footer className="site-footer">
        <a href="/privacy/">Privacy</a>
        <a href="/terms/">Terms</a>
        <a href={sourceUrl}>GitHub</a>
        <span>OpenArc is an independent project, not affiliated with The Browser Company.</span>
      </footer>
    </main>
  );
}

function ReleaseList({ releases, state }: { releases: BrowserRelease[]; state: ReleasesState }) {
  if (state === "loading") {
    return <p className="release-status">Loading release notes...</p>;
  }

  if (state === "error") {
    return (
      <div className="release-status">
        <p>Release notes are temporarily unavailable.</p>
        <a href={fallbackDownloadUrl}>Open GitHub releases</a>
      </div>
    );
  }

  if (releases.length === 0) {
    return <p className="release-status">No releases have been published yet.</p>;
  }

  return (
    <div className="release-grid">
      {releases.map((release) => (
        <article className="release-card" key={release.id}>
          <div className="release-card-header">
            <div>
              <p className="release-date">{formatReleaseDate(release.publishedAt)}</p>
              <h3>{release.name}</h3>
            </div>
            <span className={`release-channel ${release.channel}`}>
              {release.channel === "beta" ? "Beta" : release.isLatestStable ? "Latest stable" : "Stable"}
            </span>
          </div>

          <p className="release-tag">{release.tagName}</p>
          <p className="release-notes">{release.notes.trim() || "No release notes were published for this build."}</p>

          <div className="release-assets" aria-label={`${release.name} downloads`}>
            {release.assets.length > 0 ? (
              release.assets.map((asset) => (
                <a href={asset.downloadURL} key={asset.id}>
                  <span>{asset.name}</span>
                  <small>{formatAssetSize(asset.size)}</small>
                </a>
              ))
            ) : (
              <a href={release.htmlURL}>
                <span>Open release on GitHub</span>
                <small>Assets unavailable</small>
              </a>
            )}
          </div>
        </article>
      ))}
    </div>
  );
}

function formatReleaseDate(value: string | null) {
  if (!value) {
    return "Unpublished";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Unpublished";
  }

  return releaseDateFormatter.format(date);
}

function formatAssetSize(size: number | null) {
  if (!size) {
    return "Download";
  }

  if (size < 1024 * 1024) {
    return `${Math.max(1, Math.round(size / 1024))} KB`;
  }

  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

function getPrimaryMacOSAsset(assets: ReleaseAsset[]) {
  let primaryAsset: ReleaseAsset | undefined;
  let primaryAssetScore = 0;

  assets.forEach((asset) => {
    const score = macOSAssetScore(asset);
    if (score > primaryAssetScore) {
      primaryAsset = asset;
      primaryAssetScore = score;
    }
  });

  return primaryAsset ?? assets[0];
}

function macOSAssetScore(asset: ReleaseAsset) {
  const assetName = asset.name.toLowerCase();
  const contentType = asset.contentType.toLowerCase();

  if (ancillaryAssetNamePattern.test(assetName)) {
    return 0;
  }

  if (assetName.endsWith(".dmg") || contentType === "application/x-apple-diskimage") {
    return 40;
  }

  if (assetName.endsWith(".pkg") || assetName.endsWith(".mpkg")) {
    return 30;
  }

  if (assetName.endsWith(".zip") || contentType === "application/zip") {
    return 20;
  }

  if (/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|txz|tbz2)$/.test(assetName)) {
    return 10;
  }

  return 0;
}

export default App;
