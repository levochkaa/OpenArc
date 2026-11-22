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

const sourceUrl = "https://github.com/levochkaa/OpenArc";
const fallbackDownloadUrl = "https://github.com/levochkaa/OpenArc/releases/latest";
const releasesApiUrl = import.meta.env.VITE_RELEASES_API_URL ?? "https://api.openarc.su/v1/releases";
const releaseDateFormatter = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  year: "numeric",
});
const shownReleaseCount = 3;
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

const stayCards = [
  {
    name: "peek",
    title: "Peek",
    text: "Shift-click a link to open a card. Escape closes it, ⌘O keeps the tab.",
    label: "Shift-clicking Jupiter on Wikipedia's Saturn page opens it in a scrolling card, then Escape closes it",
  },
  {
    name: "boost",
    title: "Boosts",
    text: "Change a site's colors and fonts, and it stays that way next time.",
    label: "On GitHub, the Boost panel switches the font to Futura, inverts colors, then picks American Typewriter",
  },
  {
    name: "pip",
    title: "Picture in Picture",
    text: "Leave a playing video and it pops out. Return to put it back.",
    label: "Switching from a YouTube video to Lonely Planet pops the video to the corner, then returns it",
  },
];

/** A clip recorded from OpenArc itself. Motion stays still for people who ask for less. */
function Clip({ name, label, className = "clip" }: { name: string; label: string; className?: string }) {
  const reduced = usePrefersReducedMotion();
  return (
    <video
      className={className}
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
      })
      .catch(() => {});

    return () => {
      controller.abort();
    };
  }, []);

  // Until a stable release ships, downloads offer the newest beta.
  const latestDownloadRelease = useMemo(
    () => releases.find((release) => release.channel === "stable") ?? releases[0],
    [releases],
  );
  // The repository is private, so its GitHub pages are not a download yet.
  const latestDownloadUrl = getPrimaryMacOSAsset(latestDownloadRelease?.assets ?? [])?.downloadURL ?? fallbackDownloadUrl;
  // Betas are for people who opt in from the app; the page lists stable releases only.
  const stableReleases = useMemo(() => releases.filter((release) => release.channel === "stable"), [releases]);
  const hasReleases = stableReleases.length > 0;

  return (
    <main>
      <section className="hero" aria-labelledby="hero-title">
        <nav className="topbar" aria-label="Primary">
          <a className="logo" href="#top" aria-label="OpenArc home">
            <LogoMark />
          </a>
          <div className="topbar-links">
            {hasReleases && <a href="#releases">Releases</a>}
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
            src="/videos/hero.webp"
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
        <Clip
          name="command"
          label="Command bar opens over Linear, finds Split View, then switches to the Saturn tab in Study Space"
        />
      </section>

      <section className="feature" aria-labelledby="split-title">
        <h2 id="split-title">Set it up your way.</h2>
        <p className="sub">
          Arrange pages with <strong>Split View</strong>, color each Space, and drag only the buttons you want onto the{" "}
          <strong>toolbar</strong>.
        </p>
        <Clip name="split" label="Opening a second page beside the first in Split View" />
      </section>

      <section className="feature" aria-labelledby="stay-title">
        <h2 id="stay-title">Stay right where you are.</h2>
        <p className="sub">Preview links, restyle sites, and keep videos playing without losing your place.</p>
        <ul className="cards">
          {stayCards.map(({ name, title, text, label }) => (
            <li key={name}>
              <Clip className="card-clip" label={label} name={name} />
              <h3>{title}</h3>
              <p>{text}</p>
            </li>
          ))}
        </ul>
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

      {hasReleases && (
        <section className="releases" id="releases" aria-labelledby="releases-title">
          <div className="section-heading">
            <h2 id="releases-title">What’s new.</h2>
          </div>
          <ReleaseList releases={stableReleases} />
        </section>
      )}

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
            {hasReleases && <a href="#releases">Releases</a>}
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

function ReleaseList({ releases }: { releases: BrowserRelease[] }) {
  const [showsAll, setShowsAll] = useState(false);
  const shownReleases = showsAll ? releases : releases.slice(0, shownReleaseCount);

  return (
    <>
      <div className="release-grid">
        {shownReleases.map((release) => (
          <article className="release-card" key={release.id}>
            <div className="release-card-header">
              <div>
                <p className="release-date">{formatReleaseDate(release.publishedAt)}</p>
                <h3>{release.name}</h3>
              </div>
              {release.isLatestStable && <span className="release-channel">Latest</span>}
            </div>
            <ReleaseNotes notes={release.notes} />
          </article>
        ))}
      </div>
      {!showsAll && releases.length > shownReleaseCount && (
        <div className="release-more">
          <button className="text-link" type="button" onClick={() => setShowsAll(true)}>
            Show {releases.length - shownReleaseCount} more
          </button>
        </div>
      )}
    </>
  );
}

/** Release notes are Markdown with `##` headings, `-` lists and `code`; nothing else is rendered. */
function ReleaseNotes({ notes }: { notes: string }) {
  const blocks: { kind: "heading" | "list" | "paragraph"; lines: string[] }[] = [];
  notes.split("\n").forEach((rawLine) => {
    const line = rawLine.trim();
    const last = blocks.at(-1);
    if (!line) {
      blocks.push({ kind: "paragraph", lines: [] });
    } else if (/^#{1,6}\s/.test(line)) {
      blocks.push({ kind: "heading", lines: [line.replace(/^#+\s+/, "")] });
    } else if (/^[-*]\s/.test(line)) {
      const item = line.replace(/^[-*]\s+/, "");
      if (last?.kind === "list") {
        last.lines.push(item);
      } else {
        blocks.push({ kind: "list", lines: [item] });
      }
    } else if (last?.kind === "paragraph") {
      last.lines.push(line);
    } else {
      blocks.push({ kind: "paragraph", lines: [line] });
    }
  });
  const shownBlocks = blocks.filter((block) => block.lines.length > 0);

  if (shownBlocks.length === 0) {
    return <p className="release-notes">Fixes and improvements.</p>;
  }

  return (
    <div className="release-notes">
      {shownBlocks.map((block, index) => {
        if (block.kind === "heading") {
          return <h4 key={index}>{renderInline(block.lines[0])}</h4>;
        }
        if (block.kind === "list") {
          return (
            <ul key={index}>
              {block.lines.map((item, itemIndex) => (
                <li key={itemIndex}>{renderInline(item)}</li>
              ))}
            </ul>
          );
        }
        return <p key={index}>{renderInline(block.lines.join(" "))}</p>;
      })}
    </div>
  );
}

function renderInline(text: string) {
  return text.split(/(`[^`]+`)/).map((part, index) =>
    part.startsWith("`") && part.endsWith("`") && part.length > 1 ? <code key={index}>{part.slice(1, -1)}</code> : part,
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
