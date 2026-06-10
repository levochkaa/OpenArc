import { Controller, Get, Header, Inject, Param, Query, Req, Res } from "@nestjs/common";
import { ApiOperation, ApiTags } from "@nestjs/swagger";
import type { Request, Response } from "express";
import { UpdatesService } from "./updates.service.js";

@ApiTags("Updates")
@Controller()
export class UpdatesController {
  constructor(@Inject(UpdatesService) private readonly updates: UpdatesService) {}

  @Get(["appcast.xml", "updates/appcast.xml"])
  @ApiOperation({ summary: "Fetch the Sparkle appcast" })
  async appcast(@Query("channel") channel: string | undefined, @Res() reply: Response) {
    const appcast = await this.updates.sparkleAppcast(this.updates.updateChannelFromQuery(channel));
    return reply
      .setHeader("Cache-Control", "public, max-age=60")
      .setHeader("Vary", "Accept")
      .type("application/xml; charset=utf-8")
      .send(appcast);
  }

  @Get(["appcast-beta.xml", "updates/appcast-beta.xml"])
  @ApiOperation({ summary: "Fetch the beta Sparkle appcast" })
  async betaAppcast(@Res() reply: Response) {
    const appcast = await this.updates.sparkleAppcast("beta");
    return reply
      .setHeader("Cache-Control", "public, max-age=60")
      .setHeader("Vary", "Accept")
      .type("application/xml; charset=utf-8")
      .send(appcast);
  }

  @Get(["downloads/:assetName", "updates/downloads/:assetName"])
  @ApiOperation({ summary: "Download a Sparkle release asset" })
  async sparkleDownload(@Param("assetName") assetName: string, @Res() reply: Response) {
    const download = await this.updates.sparkleDownload(assetName);
    if (download.asset.size) {
      reply.setHeader("Content-Length", String(download.asset.size));
    }

    reply
      .setHeader("Cache-Control", "public, max-age=31536000, immutable")
      .setHeader("Content-Disposition", this.updates.contentDispositionForAsset(download.asset.name))
      .type(download.asset.content_type ?? "application/octet-stream");
    download.body.pipe(reply);
  }

  @Get("v1/releases")
  @Header("Access-Control-Allow-Origin", "*")
  @Header("Cache-Control", "public, max-age=60")
  @ApiOperation({ summary: "List public GitHub releases" })
  async releases(@Query() query: { channel?: string; limit?: string | number }, @Req() request: Request) {
    return this.updates.releaseIndex(query, request);
  }

  @Get("v1/releases/assets/:assetID/:assetName")
  @ApiOperation({ summary: "Download a public release asset" })
  async releaseAssetDownload(
    @Param("assetID") assetID: string,
    @Res() reply: Response
  ) {
    const download = await this.updates.releaseAssetDownload(assetID);
    if (download.asset.size) {
      reply.setHeader("Content-Length", String(download.asset.size));
    }

    reply
      .setHeader("Cache-Control", "public, max-age=31536000, immutable")
      .setHeader("Content-Disposition", this.updates.contentDispositionForAsset(download.asset.name))
      .type(download.asset.content_type ?? "application/octet-stream");
    download.body.pipe(reply);
  }
}
