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

const fallbackDownloadUrl = "https://github.com/levochkaa/OpenArc/releases/latest";
const releasesApiUrl = import.meta.env.VITE_RELEASES_API_URL ?? "https://api.openarc.su/v1/releases";
const releaseDateFormatter = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  year: "numeric",
});
const ancillaryAssetNamePattern = /(^|[.\-_\s])(blockmap|checksum|checksums|debug|dsym|manifest|metadata|sha256|sha512|signature|symbols?)([.\-_\s]|$)/i;

const focusCards = [
  {
    label: "Today",
    title: "Product launch",
    meta: "12 tabs ready",
  },
  {
    label: "Command",
    title: "Search tabs, history, URLs",
    meta: "Instant jump",
  },
  {
    label: "Local",
    title: "Workspace state stays yours",
    meta: "No account required",
  },
];

const workflow = [
  {
    title: "Spaces hold the context",
    body: "Separate work, life, research, and reading without turning one window into a tab landfill.",
    accent: "green",
  },
  {
    title: "Pinned tools stay useful",
    body: "Shared app tabs live across spaces, while project-specific pinned tabs stay exactly where they belong.",
    accent: "amber",
  },
  {
    title: "Command bar leads",
    body: "Open, switch, search history, and recover pages from one fast keyboard-first flow.",
    accent: "blue",
  },
];

const capabilities = [
  "Chromium engine",
  "Chrome extensions",
  "Arc, Chrome, Safari import",
  "Passkeys and modern login",
  "Signed automatic updates",
  "Local-first session state",
];

const stats = [
  ["Mac-first", "native desktop product"],
  ["Chromium", "real browser engine"],
  ["Local-first", "workspace state on device"],
];

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
        <div className="hero-art" aria-hidden="true" />
        <nav className="topbar" aria-label="Primary">
          <a className="brand" href="#top" aria-label="OpenArc home">
            <span className="brand-mark" aria-hidden="true" />
            <span>OpenArc</span>
          </a>
          <div className="nav-pill">
            <a href="#workflow">Workflow</a>
            <a href="#engine">Engine</a>
            <a href="#releases">Releases</a>
            <a href={latestDownloadUrl}>Download</a>
          </div>
        </nav>

        <div className="hero-copy">
          <p className="kicker">Mac workspace browser</p>
          <h1 id="hero-title">
            A browser for
            <span>focused work</span>
          </h1>
          <p className="hero-text">
            OpenArc turns tabs into organized spaces, shared pinned tools,
            and fast command navigation. Chromium power, local-first control,
            and a calmer way to work on macOS.
          </p>
          <div className="hero-actions" aria-label="Download actions">
            <a className="button primary" href={latestDownloadUrl}>
              Download for macOS
            </a>
            <a className="button secondary" href="#workflow">
              Explore workflow
            </a>
          </div>
        </div>

        <div className="floating-card card-left" aria-hidden="true">
          <span>Morning brief</span>
          <strong>Open launch space</strong>
          <small>5 pinned tools</small>
        </div>
        <div className="floating-card card-right" aria-hidden="true">
          <span>Next action</span>
          <strong>Find design notes</strong>
          <small>Command bar</small>
        </div>
      </section>

      <section className="intro-band" aria-label="Product summary">
        <div className="intro-copy">
          <p className="section-label">The idea</p>
          <h2>Browser as workspace, without making the cloud the center.</h2>
        </div>
        <div className="stat-row">
          {stats.map(([value, label]) => (
            <div className="stat" key={value}>
              <strong>{value}</strong>
              <span>{label}</span>
            </div>
          ))}
        </div>
      </section>

      <section className="workflow" id="workflow">
        <div className="section-heading">
          <p className="section-label">Workflow</p>
          <h2>Built for the moment when browsing becomes work.</h2>
        </div>
        <div className="focus-row" aria-hidden="true">
          {focusCards.map((card) => (
            <article className="focus-card" key={card.title}>
              <span>{card.label}</span>
              <strong>{card.title}</strong>
              <small>{card.meta}</small>
            </article>
          ))}
        </div>
        <div className="workflow-grid">
          {workflow.map((item) => (
            <article className={`workflow-card ${item.accent}`} key={item.title}>
              <span />
              <h3>{item.title}</h3>
              <p>{item.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="engine" id="engine">
        <div className="browser-shell" aria-hidden="true">
          <div className="shell-sidebar">
            <div className="window-dots">
              <span />
              <span />
              <span />
            </div>
            <div className="space active" />
            <div className="space" />
            <div className="space" />
            <div className="space short" />
          </div>
          <div className="shell-main">
            <div className="command-strip" />
            <div className="tab-strip">
              <span />
              <span />
              <span />
            </div>
            <div className="pane-grid">
              <div className="pane large" />
              <div className="pane chart" />
              <div className="pane table" />
            </div>
          </div>
        </div>
        <div className="engine-copy">
          <p className="section-label">Inside the build</p>
          <h2>Real browser power, Mac-native shape.</h2>
          <p>
            OpenArc starts with the daily-driver fundamentals: Chromium,
            extension support, passkeys, downloads, page find, state that
            survives relaunches, and workspace structure that does not require
            a hosted account.
          </p>
        </div>
      </section>

      <section className="capabilities" aria-label="Capabilities">
        <div className="section-heading">
          <p className="section-label">Capabilities</p>
          <h2>The useful parts of a modern browser, kept close to the surface.</h2>
        </div>
        <ul className="capability-list">
          {capabilities.map((detail) => (
            <li key={detail}>{detail}</li>
          ))}
        </ul>
      </section>

      <section className="releases" id="releases" aria-labelledby="releases-title">
        <div className="section-heading">
          <p className="section-label">Release notes</p>
          <h2 id="releases-title">Every build, with previous downloads kept available.</h2>
        </div>
        <ReleaseList releases={releases} state={releasesState} />
      </section>

      <section className="download" aria-labelledby="download-title">
        <div>
          <p className="section-label">Get it</p>
          <h2 id="download-title">Download the latest macOS build.</h2>
          <p>
            Install the current stable release, keep automatic updates on, or
            switch the app to the beta channel when you want GitHub pre-release
            builds.
          </p>
        </div>
        <a className="button primary download-button" href={latestDownloadUrl}>
          Download latest
        </a>
      </section>
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
