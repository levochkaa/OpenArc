import { Injectable } from "@nestjs/common";
import type { Request } from "express";
import { Readable } from "node:stream";
import type { ReadableStream as NodeReadableStream } from "node:stream/web";
import { config } from "./config.js";
import { httpError } from "./http.js";

type GitHubReleaseAsset = {
  id: number;
  name: string;
  url: string;
  browser_download_url?: string;
  content_type?: string;
  size?: number;
  download_count?: number;
};

type GitHubRelease = {
  id: number;
  tag_name: string;
  name?: string | null;
  body?: string | null;
  html_url: string;
  draft: boolean;
  prerelease: boolean;
  created_at: string;
  published_at?: string | null;
  assets: GitHubReleaseAsset[];
};

type SerializedReleaseAsset = {
  id: number;
  name: string;
  contentType: string;
  size: number | null;
  downloadCount: number | null;
  downloadURL: string;
};

type SerializedRelease = {
  id: number;
  tagName: string;
  name: string;
  channel: ReleaseChannel;
  isLatestStable: boolean;
  publishedAt: string | null;
  htmlURL: string;
  notes: string;
  assets: SerializedReleaseAsset[];
};

export type ReleaseChannel = "stable" | "beta";
type ReleaseIndexChannel = ReleaseChannel | "all";

export type DownloadResponse = {
  asset: GitHubReleaseAsset;
  body: Readable;
};

@Injectable()
export class UpdatesService {
  async sparkleAppcast(channel: ReleaseChannel): Promise<string> {
    const release = await this.fetchLatestGitHubRelease(channel);
    const asset = this.findReleaseAsset(release, config.THEBROWSER_UPDATE_APPCAST_ASSET);
    const response = await this.fetchGitHubAsset(asset, "application/octet-stream");
    return response.text();
  }

  async sparkleDownload(assetName: string): Promise<DownloadResponse> {
    const asset = await this.findReleaseAssetByName(assetName);
    return this.downloadAsset(asset);
  }

  async releaseAssetDownload(assetID: string): Promise<DownloadResponse> {
    const asset = await this.fetchGitHubReleaseAsset(assetID);
    return this.downloadAsset(asset);
  }

  async releaseIndex(
    query: { channel?: string; limit?: string | number },
    request: Request
  ): Promise<{ releases: SerializedRelease[] }> {
    const channel = this.parseReleaseIndexChannel(query.channel ?? "all");
    const limit = this.parseReleaseLimit(query.limit);
    const releases = this.publicGitHubReleases(await this.fetchGitHubReleases());
    const latestStableReleaseID = releases.find((release) => !release.prerelease)?.id;
    const filteredReleases = releases
      .filter((release) => channel === "all" || this.releaseChannel(release) === channel)
      .slice(0, limit)
      .map((release) => this.serializeRelease(release, this.publicBaseURL(request), latestStableReleaseID));

    return { releases: filteredReleases };
  }

  updateChannelFromQuery(channel: string | undefined): ReleaseChannel {
    return this.parseReleaseChannel(channel ?? "stable");
  }

  contentDispositionForAsset(assetName: string): string {
    return `attachment; filename="${assetName.replaceAll('"', "")}"`;
  }

  private async downloadAsset(asset: GitHubReleaseAsset): Promise<DownloadResponse> {
    const response = await this.fetchGitHubAsset(asset, "application/octet-stream");
    if (!response.body) {
      throw httpError(502, "GitHub returned an empty release asset body");
    }

    return {
      asset,
      body: Readable.fromWeb(response.body as unknown as NodeReadableStream<Uint8Array>)
    };
  }

  private async fetchLatestGitHubRelease(channel: ReleaseChannel = "stable"): Promise<GitHubRelease> {
    const releases = this.publicGitHubReleases(await this.fetchGitHubReleases());
    const release = releases.find((candidate) => this.releaseChannel(candidate) === channel);
    if (!release) {
      throw httpError(404, `No ${channel} release was found`);
    }

    return release;
  }

  private async fetchGitHubReleases(): Promise<GitHubRelease[]> {
    const repository = config.GITHUB_RELEASE_REPOSITORY;
    if (!repository) {
      throw httpError(503, "GITHUB_RELEASE_REPOSITORY is not configured");
    }

    const response = await fetch(`https://api.github.com/repos/${repository}/releases?per_page=100`, {
      headers: this.githubHeaders("application/vnd.github+json")
    });

    if (!response.ok) {
      throw httpError(response.status, `GitHub releases lookup failed with ${response.status}`);
    }

    return (await response.json()) as GitHubRelease[];
  }

  private async findReleaseAssetByName(assetName: string): Promise<GitHubReleaseAsset> {
    const releases = this.publicGitHubReleases(await this.fetchGitHubReleases());
    for (const release of releases) {
      const asset = release.assets.find((candidate) => candidate.name === assetName);
      if (asset) {
        return asset;
      }
    }

    throw httpError(404, `Release asset '${assetName}' was not found`);
  }

  private async fetchGitHubReleaseAsset(assetID: string): Promise<GitHubReleaseAsset> {
    if (!/^\d+$/.test(assetID)) {
      throw httpError(400, "Invalid release asset id");
    }

    const repository = config.GITHUB_RELEASE_REPOSITORY;
    if (!repository) {
      throw httpError(503, "GITHUB_RELEASE_REPOSITORY is not configured");
    }

    const response = await fetch(`https://api.github.com/repos/${repository}/releases/assets/${assetID}`, {
      headers: this.githubHeaders("application/vnd.github+json")
    });

    if (!response.ok) {
      throw httpError(response.status, `GitHub release asset lookup failed with ${response.status}`);
    }

    return (await response.json()) as GitHubReleaseAsset;
  }

  private findReleaseAsset(release: GitHubRelease, assetName: string): GitHubReleaseAsset {
    const asset = release.assets.find((candidate) => candidate.name === assetName);
    if (!asset) {
      throw httpError(404, `Release asset '${assetName}' was not found in ${release.tag_name}`);
    }

    return asset;
  }

  private publicGitHubReleases(releases: GitHubRelease[]): GitHubRelease[] {
    return releases
      .filter((release) => !release.draft)
      .sort((lhs, rhs) => this.releaseSortDate(rhs).getTime() - this.releaseSortDate(lhs).getTime());
  }

  private releaseSortDate(release: GitHubRelease): Date {
    return new Date(release.published_at ?? release.created_at);
  }

  private releaseChannel(release: GitHubRelease): ReleaseChannel {
    return release.prerelease ? "beta" : "stable";
  }

  private parseReleaseChannel(value: string): ReleaseChannel {
    if (value === "stable" || value === "beta") {
      return value;
    }

    throw httpError(400, "Release channel must be stable or beta");
  }

  private parseReleaseIndexChannel(value: string): ReleaseIndexChannel {
    if (value === "all") {
      return value;
    }

    return this.parseReleaseChannel(value);
  }

  private parseReleaseLimit(value: string | number | undefined): number {
    if (value == null || value === "") {
      return 20;
    }

    const limit = Number(value);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw httpError(400, "Release limit must be an integer from 1 to 100");
    }

    return limit;
  }

  private serializeRelease(release: GitHubRelease, baseURL: string, latestStableReleaseID?: number): SerializedRelease {
    return {
      id: release.id,
      tagName: release.tag_name,
      name: release.name?.trim() || release.tag_name,
      channel: this.releaseChannel(release),
      isLatestStable: release.id === latestStableReleaseID,
      publishedAt: (release.published_at ?? release.created_at) || null,
      htmlURL: release.html_url,
      notes: release.body ?? "",
      assets: release.assets
        .filter((asset) => this.isUserDownloadableReleaseAsset(asset))
        .map((asset) => this.serializeReleaseAsset(asset, baseURL))
    };
  }

  private serializeReleaseAsset(asset: GitHubReleaseAsset, baseURL: string): SerializedReleaseAsset {
    const path = `/v1/releases/assets/${asset.id}/${encodeURIComponent(asset.name)}`;
    return {
      id: asset.id,
      name: asset.name,
      contentType: asset.content_type ?? "application/octet-stream",
      size: asset.size ?? null,
      downloadCount: asset.download_count ?? null,
      downloadURL: new URL(path, baseURL).href
    };
  }

  private isUserDownloadableReleaseAsset(asset: GitHubReleaseAsset): boolean {
    const name = asset.name.toLowerCase();
    return !name.endsWith(".xml") && !name.endsWith(".md") && !name.endsWith(".delta");
  }

  private async fetchGitHubAsset(asset: GitHubReleaseAsset, accept: string): Promise<Response> {
    const response = await fetch(asset.url, {
      headers: this.githubHeaders(accept),
      redirect: "follow"
    });

    if (!response.ok) {
      throw httpError(response.status, `GitHub asset download failed with ${response.status}`);
    }

    return response;
  }

  private publicBaseURL(request: Request): string {
    if (config.THEBROWSER_PUBLIC_BASE_URL) {
      return config.THEBROWSER_PUBLIC_BASE_URL;
    }

    const forwardedProto = this.firstHeaderValue(request.headers["x-forwarded-proto"]);
    const forwardedHost = this.firstHeaderValue(request.headers["x-forwarded-host"]);
    const host = forwardedHost ?? request.headers.host ?? `${config.HOST}:${config.PORT}`;
    const protocol =
      forwardedProto ?? (host.startsWith("localhost") || host.startsWith("127.0.0.1") ? "http" : "https");
    return `${protocol}://${host}`;
  }

  private firstHeaderValue(value: string | string[] | undefined): string | undefined {
    return Array.isArray(value) ? value[0]?.split(",")[0]?.trim() : value?.split(",")[0]?.trim();
  }

  private githubHeaders(accept: string): Record<string, string> {
    const headers: Record<string, string> = {
      Accept: accept,
      "User-Agent": "TheBrowser Update Server",
      "X-GitHub-Api-Version": "2026-03-10"
    };

    if (config.GITHUB_RELEASE_TOKEN) {
      headers.Authorization = `Bearer ${config.GITHUB_RELEASE_TOKEN}`;
    }

    return headers;
  }
}
