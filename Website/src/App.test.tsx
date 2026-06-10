import { render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";

const releasesApiUrl = "https://updates.thebrowser.app/v1/releases";

const releaseResponse = {
  releases: [
    {
      id: 101,
      tagName: "v1.4.0",
      name: "TheBrowser 1.4",
      channel: "stable",
      isLatestStable: true,
      publishedAt: "2026-05-20T12:00:00.000Z",
      htmlURL: "https://github.com/levochkaa/TheBrowser/releases/tag/v1.4.0",
      notes: "Workspace polish and signed update fixes.",
      assets: [
        {
          id: 201,
          name: "TheBrowser-1.4.0.dmg",
          contentType: "application/x-apple-diskimage",
          size: 125_829_120,
          downloadCount: 42,
          downloadURL: "https://updates.thebrowser.app/downloads/TheBrowser-1.4.0.dmg",
        },
      ],
    },
    {
      id: 102,
      tagName: "v1.5.0-beta.1",
      name: "TheBrowser 1.5 Beta 1",
      channel: "beta",
      isLatestStable: false,
      publishedAt: "2026-05-25T12:00:00.000Z",
      htmlURL: "https://github.com/levochkaa/TheBrowser/releases/tag/v1.5.0-beta.1",
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

  it("renders the landing hero while release notes are loading", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));

    render(<App />);

    expect(screen.getByRole("heading", { name: /a browser for\s*focused work/i })).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: /primary/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
      "href",
      "https://github.com/levochkaa/TheBrowser/releases/latest",
    );
    expect(screen.getByText("Loading release notes...")).toBeInTheDocument();
  });

  it("loads release notes and points landing download actions at the latest stable asset", async () => {
    const fetchMock = mockFetchResponse(releaseResponse);

    render(<App />);

    expect(fetchMock).toHaveBeenCalledWith(releasesApiUrl, expect.objectContaining({ signal: expect.any(AbortSignal) }));

    const releaseHeading = await screen.findByRole("heading", { name: "TheBrowser 1.4" });
    const releaseCard = releaseHeading.closest("article");
    expect(releaseCard).not.toBeNull();

    expect(within(releaseCard!).getByText("Latest stable")).toBeInTheDocument();
    expect(within(releaseCard!).getByText("v1.4.0")).toBeInTheDocument();
    expect(within(releaseCard!).getByText("Workspace polish and signed update fixes.")).toBeInTheDocument();
    expect(within(releaseCard!).getByRole("link", { name: /TheBrowser-1\.4\.0\.dmg\s*120\.0 MB/i })).toHaveAttribute(
      "href",
      "https://updates.thebrowser.app/downloads/TheBrowser-1.4.0.dmg",
    );

    await waitFor(() => {
      expect(screen.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
        "href",
        "https://updates.thebrowser.app/downloads/TheBrowser-1.4.0.dmg",
      );
    });
    expect(screen.getByRole("link", { name: /download latest/i })).toHaveAttribute(
      "href",
      "https://updates.thebrowser.app/downloads/TheBrowser-1.4.0.dmg",
    );

    const betaHeading = screen.getByRole("heading", { name: "TheBrowser 1.5 Beta 1" });
    const betaCard = betaHeading.closest("article");
    expect(betaCard).not.toBeNull();
    expect(within(betaCard!).getByText("Beta")).toBeInTheDocument();
    expect(within(betaCard!).getByText("No release notes were published for this build.")).toBeInTheDocument();
    expect(within(betaCard!).getByRole("link", { name: /open release on github\s*assets unavailable/i })).toHaveAttribute(
      "href",
      "https://github.com/levochkaa/TheBrowser/releases/tag/v1.5.0-beta.1",
    );
  });

  it("shows the empty releases state", async () => {
    mockFetchResponse({ releases: [] });

    render(<App />);

    expect(await screen.findByText("No releases have been published yet.")).toBeInTheDocument();
  });

  it("falls back to GitHub releases when the releases API fails", async () => {
    mockFetchResponse({}, false);

    render(<App />);

    expect(await screen.findByText("Release notes are temporarily unavailable.")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /open github releases/i })).toHaveAttribute(
      "href",
      "https://github.com/levochkaa/TheBrowser/releases/latest",
    );
  });
});
