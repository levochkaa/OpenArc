import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";

const releasesApiUrl = "https://api.openarc.su/v1/releases";

const releaseResponse = {
  releases: [
    {
      id: 101,
      tagName: "v1.4.0",
      name: "OpenArc 1.4",
      channel: "stable",
      isLatestStable: true,
      publishedAt: "2026-05-20T12:00:00.000Z",
      htmlURL: "https://github.com/levochkaa/OpenArc/releases/tag/v1.4.0",
      notes: "Workspace polish and signed update fixes.\n\n## Tabs\n\n- Typed `localhost:3000` opens.",
      assets: [
        {
          id: 200,
          name: "OpenArc-1.4.0.sha256",
          contentType: "text/plain",
          size: 96,
          downloadCount: 4,
          downloadURL: "https://api.openarc.su/downloads/OpenArc-1.4.0.sha256",
        },
        {
          id: 201,
          name: "OpenArc-1.4.0.dmg",
          contentType: "application/x-apple-diskimage",
          size: 125_829_120,
          downloadCount: 42,
          downloadURL: "https://api.openarc.su/downloads/OpenArc-1.4.0.dmg",
        },
      ],
    },
    {
      id: 102,
      tagName: "v1.5.0-beta.1",
      name: "OpenArc 1.5 Beta 1",
      channel: "beta",
      isLatestStable: false,
      publishedAt: "2026-05-25T12:00:00.000Z",
      htmlURL: "https://github.com/levochkaa/OpenArc/releases/tag/v1.5.0-beta.1",
      notes: "",
      assets: [],
    },
  ],
};

function mockFetchResponse(body: unknown, ok = true) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok,
    status: ok ? 200 : 500,
    json: () => Promise.resolve(body),
  });

  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

describe("App", () => {
  beforeEach(() => {
    vi.stubGlobal("fetch", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders the landing hero while releases are loading", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));

    render(<App />);

    expect(screen.getByRole("heading", { name: /the browser you loved, still open/i })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: /primary/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
      "href",
      "https://github.com/levochkaa/OpenArc/releases/latest",
    );
    expect(screen.queryByRole("heading", { name: /what’s new/i })).not.toBeInTheDocument();
  });

  it("links the iPhone and iPad app on the App Store from the hero, the top bar and the footer", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));

    render(<App />);

    const appStoreUrl = "https://apps.apple.com/app/openarc/id6832347016";
    expect(screen.getByRole("link", { name: /openarc for iphone and ipad is out now/i })).toHaveAttribute(
      "href",
      appStoreUrl,
    );
    const nav = screen.getByRole("navigation", { name: /primary/i });
    expect(within(nav).getByRole("link", { name: "App Store" })).toHaveAttribute("href", appStoreUrl);
    const footer = screen.getByRole("contentinfo");
    expect(within(footer).getByRole("link", { name: "App Store" })).toHaveAttribute("href", appStoreUrl);
  });

  it("shows Peek, Boosts and Picture in Picture as cards with their own clips", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));

    render(<App />);

    const section = screen.getByRole("heading", { name: /stay right where you are/i }).closest("section");
    expect(section).not.toBeNull();
    const cards = within(section as HTMLElement).getAllByRole("listitem");
    expect(cards.map((card) => within(card).getByRole("heading").textContent)).toEqual([
      "Peek",
      "Boosts",
      "Picture in Picture",
    ]);
    expect(cards.map((card) => card.querySelector("video")?.getAttribute("src"))).toEqual([
      "/videos/peek.mp4",
      "/videos/boost.mp4",
      "/videos/pip.mp4",
    ]);
  });

  it("downloads the newest beta and hides the release list until a stable release ships", async () => {
    mockFetchResponse({
      releases: [
        {
          ...releaseResponse.releases[1],
          id: 3,
          assets: [
            {
              id: 300,
              name: "OpenArc-0.3.0-3.zip",
              contentType: "application/zip",
              size: 120_000_000,
              downloadCount: 1,
              downloadURL: "https://api.openarc.su/downloads/OpenArc-0.3.0-3.zip",
            },
          ],
        },
        { ...releaseResponse.releases[1], id: 2 },
      ],
    });

    render(<App />);

    await waitFor(() => {
      expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
        "href",
        "https://api.openarc.su/downloads/OpenArc-0.3.0-3.zip",
      );
    });
    expect(screen.queryByRole("heading", { name: /what’s new/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Releases" })).not.toBeInTheDocument();
  });

  it("lists stable releases without betas or downloads and points download actions at the latest stable", async () => {
    const fetchMock = mockFetchResponse(releaseResponse);
    const installerDownloadURL = "https://api.openarc.su/downloads/OpenArc-1.4.0.dmg";

    render(<App />);

    expect(fetchMock).toHaveBeenCalledWith(releasesApiUrl, expect.objectContaining({ signal: expect.any(AbortSignal) }));

    const releaseCard = (await screen.findByRole("heading", { name: "OpenArc 1.4" })).closest("article");
    expect(releaseCard).not.toBeNull();
    expect(within(releaseCard!).getByText("Latest")).toBeInTheDocument();
    expect(within(releaseCard!).getByText("Workspace polish and signed update fixes.")).toBeInTheDocument();
    expect(within(releaseCard!).getByRole("heading", { name: "Tabs" })).toBeInTheDocument();
    expect(within(releaseCard!).getByRole("listitem")).toHaveTextContent("Typed localhost:3000 opens.");
    expect(within(releaseCard!).queryByRole("link")).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "OpenArc 1.5 Beta 1" })).not.toBeInTheDocument();

    expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute("href", installerDownloadURL);
    expect(within(screen.getByRole("navigation", { name: /primary/i })).getByRole("link", { name: "Download" })).toHaveAttribute(
      "href",
      installerDownloadURL,
    );
    expect(screen.getByRole("link", { name: /download latest/i })).toHaveAttribute("href", installerDownloadURL);
  });

  it("shows the newest three stable releases and the rest behind a button", async () => {
    const stable = releaseResponse.releases[0];
    mockFetchResponse({
      releases: [1, 2, 3, 4, 5].map((minor, index) => ({
        ...stable,
        id: minor,
        name: `OpenArc 1.${6 - minor}`,
        isLatestStable: index === 0,
      })),
    });

    render(<App />);

    expect(await screen.findByRole("heading", { name: "OpenArc 1.5" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "OpenArc 1.3" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "OpenArc 1.2" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Show 2 more" }));

    expect(screen.getByRole("heading", { name: "OpenArc 1.1" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /more/i })).not.toBeInTheDocument();
  });

  it("points primary download actions at the DMG asset when a non-DMG asset is listed first", async () => {
    mockFetchResponse({
      releases: [
        {
          ...releaseResponse.releases[0],
          assets: [
            {
              id: 202,
              name: "OpenArc-1.4.0-symbols.zip",
              contentType: "application/zip",
              size: 8_388_608,
              downloadCount: 7,
              downloadURL: "https://api.openarc.su/downloads/OpenArc-1.4.0-symbols.zip",
            },
            {
              id: 203,
              name: "OpenArc-1.4.0.dmg",
              contentType: "application/x-apple-diskimage",
              size: 125_829_120,
              downloadCount: 42,
              downloadURL: "https://api.openarc.su/downloads/OpenArc-1.4.0.dmg",
            },
          ],
        },
      ],
    });

    render(<App />);

    await waitFor(() => {
      expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
        "href",
        "https://api.openarc.su/downloads/OpenArc-1.4.0.dmg",
      );
    });
    expect(screen.getByRole("link", { name: /download latest/i })).toHaveAttribute(
      "href",
      "https://api.openarc.su/downloads/OpenArc-1.4.0.dmg",
    );
  });

  it("keeps the download working when the releases API fails", async () => {
    mockFetchResponse({}, false);

    render(<App />);

    await waitFor(() => {
      expect(screen.getByRole("link", { name: /download latest/i })).toHaveAttribute(
        "href",
        "https://github.com/levochkaa/OpenArc/releases/latest",
      );
    });
    expect(screen.queryByRole("heading", { name: /what’s new/i })).not.toBeInTheDocument();
  });
});
