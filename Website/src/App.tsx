import { useEffect, useMemo, useState } from "react";

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

const facts = [
  ["Your Arc, imported in a minute.", "Import"],
  ["Chrome extensions just work.", "Extensions"],
  ["Passkeys with Touch ID or your phone.", "Passkeys"],
  ["Every command in one bar.", "⌘T"],
];

function usePrefersReducedMotion() {
  const [reduced] = useState(
    () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true,
  );
  return reduced;
}

/** A clip recorded from OpenArc itself. Motion stays still for people who ask for less. */
function Clip({ name, label }: { name: string; label: string }) {
  const reduced = usePrefersReducedMotion();
  return (
    <video
      className="clip"
      aria-label={label}
      autoPlay={!reduced}
      controls={reduced}
      loop
      muted
      playsInline
      poster={`/videos/${name}.jpg`}
      preload="metadata"
      src={`/videos/${name}.mp4`}
    />
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
          <a className="logo" href="#top" aria-label="OpenArc home">
            <LogoMark />
          </a>
          <div className="topbar-links">
            <a href="#releases">Releases</a>
            <a href={sourceUrl}>Source</a>
            <a href={latestDownloadUrl}>Download</a>
          </div>
        </nav>
        <div className="hero-copy" id="top">
          <h1 id="hero-title">
            <span className="quote-mark" aria-hidden="true">
              “
            </span>
            The browser you loved, still open.
            <span className="quote-mark" aria-hidden="true">
              ”
            </span>
          </h1>
          <p className="hero-byline">Free · Open source · For Mac</p>
          <div className="hero-actions" aria-label="Download actions">
            <a className="button" href={latestDownloadUrl}>
              Download for macOS
            </a>
          </div>
        </div>
        <svg className="stamp" viewBox="0 0 220 120" aria-hidden="true">
          <ellipse cx="110" cy="60" rx="104" ry="52" />
          <text x="110" y="56">FOR MACOS 26</text>
          <text x="110" y="76">AND LATER</text>
        </svg>
        <div className="hero-shot">
          <img
            alt="OpenArc with a Work Space open: a sidebar of tabs beside a page"
            height={860}
            src="/videos/hero.jpg"
            width={1360}
          />
        </div>
        <a className="more" href="#spaces">
          More
          <br />
          Details
        </a>
      </section>
      <div className="zigzag zigzag-top" aria-hidden="true" />

      <section className="feature" id="spaces" aria-labelledby="calm-title">
        <h2 id="calm-title">A browser that stays out of your way.</h2>
        <p className="sub">
          A <strong>sidebar</strong> instead of a tab strip, and nothing on screen but the page you came for.
        </p>
        <Clip name="sidebar" label="OpenArc hides its sidebar so the page fills the window, then brings it back" />
      </section>

      <section className="feature" aria-labelledby="spaces-title">
        <h2 id="spaces-title">A Space for every side of you.</h2>
        <p className="sub">
          Work, study and everything else in one window, each with its own pins, color and profile, using{" "}
          <strong>Spaces</strong>.
        </p>
        <Clip name="spaces" label="Switching between Work, Personal and Study Spaces, each in its own color" />
      </section>

      <section className="feature" aria-labelledby="command-title">
        <h2 id="command-title">Everything is one keystroke away.</h2>
        <p className="sub">
          Press <strong>⌘T</strong> for tabs in every Space, your history, bookmarks and every command, ranked as you
          type.
        </p>
        <Clip name="command" label="Typing split and then figma into OpenArc's command bar" />
      </section>

      <section className="feature" aria-labelledby="split-title">
        <h2 id="split-title">Set it up your way.</h2>
        <p className="sub">
          Arrange pages with <strong>Split View</strong>, color each Space, and drag only the buttons you want onto the{" "}
          <strong>toolbar</strong>.
        </p>
        <Clip name="split" label="Opening a second page beside the first in Split View" />
      </section>

      <section className="feature" aria-labelledby="import-title">
        <h2 id="import-title">Bring your Arc with you.</h2>
        <p className="sub">
          The welcome window finds <strong>Arc</strong>, <strong>Chrome</strong> and <strong>Dia</strong> and copies
          what you pick. Your other browser stays exactly as it was.
        </p>
        <ul className="checklist">
          {importItems.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </section>

      <section className="feature" id="agents" aria-labelledby="agents-title">
        <h2 id="agents-title">Lend it to an agent.</h2>
        <p className="sub">
          Agents can open, read and click through the <strong>openarc</strong> command or its MCP server, with your
          sign-ins. Passwords are typed by the browser after you agree, and never reach the agent.
        </p>
        <pre className="terminal" aria-label="An agent using the openarc command">
          {agentLines.map(([command, output]) => (
            <span className={command ? "terminal-command" : "terminal-output"} key={command + output}>
              {command || output}
              {"\n"}
            </span>
          ))}
        </pre>
      </section>

      <section className="feature feature-last" aria-labelledby="own-title">
        <h2 id="own-title">The comfort of owning it.</h2>
        <p className="sub">
          OpenArc is open source and needs no account. Your tabs, history and passwords stay on your Mac.
        </p>
        <a className="text-link" href={sourceUrl}>
          Read the source →
        </a>
      </section>

      <div className="zigzag zigzag-cream-top" aria-hidden="true" />
      <section className="facts" aria-label="What comes with it">
        <div className="facts-icons" aria-hidden="true">
          <span>✦</span>
          <span>♥</span>
          <span>☺</span>
        </div>
        <div className="facts-grid">
          {facts.map(([text, tag]) => (
            <figure key={tag}>
              <p>{text}</p>
              <figcaption>{tag}</figcaption>
            </figure>
          ))}
        </div>
      </section>

      <section className="releases" id="releases" aria-labelledby="releases-title">
        <div className="section-heading">
          <h2 id="releases-title">Every build, and every download.</h2>
        </div>
        <ReleaseList releases={releases} state={releasesState} />
      </section>

      <footer className="site-footer">
        <div className="zigzag zigzag-blue-top" aria-hidden="true" />
        <section className="download" aria-labelledby="download-title">
          <h2 id="download-title">
            Make yourself at <em>home</em> again.
          </h2>
          <a className="button" href={latestDownloadUrl}>
            Download latest
          </a>
        </section>
        <div className="footer-row">
          <LogoMark />
          <div className="footer-links">
            <a href="/privacy/">Privacy policy</a>
            <a href="/terms/">Terms</a>
            <a href="#releases">Releases</a>
            <a href={sourceUrl}>GitHub</a>
          </div>
          <span>Not affiliated with The Browser Company</span>
        </div>
      </footer>
    </main>
  );
}

function LogoMark() {
  return (
    <svg className="logo-mark" viewBox="0 0 40 36" aria-hidden="true">
      <path d="M20 3c4 0 6 3 7.5 7l7.5 18c1 2.5-.5 5-3 5-2 0-3-1.2-4-3.4L20 12l-8 17.6c-1 2.2-2 3.4-4 3.4-2.5 0-4-2.5-3-5l7.5-18C14 6 16 3 20 3Z" />
    </svg>
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
