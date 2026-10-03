import { Body, Controller, Headers, Inject, Post } from "@nestjs/common";
import { ApiBearerAuth, ApiBody, ApiCreatedResponse, ApiOperation, ApiTags } from "@nestjs/swagger";
import { AuthService } from "./auth.service.js";
import { SyncPullRequest, SyncPushRequest } from "./schemas.js";
import { SyncService } from "./sync.service.js";
import { parseRequest } from "./validation.js";

@ApiTags("Sync")
@Controller("v1/sync")
export class SyncController {
  constructor(
    @Inject(AuthService)
    private readonly auth: AuthService,
    @Inject(SyncService)
    private readonly sync: SyncService
  ) {}

  @Post("push")
  @ApiBearerAuth("bearerAuth")
  @ApiOperation({ summary: "Push local sync changes" })
  @ApiBody({
    schema: {
      oneOf: [{
        type: "object",
        required: ["deviceID", "changes"],
        additionalProperties: false,
        properties: {
          deviceID: { type: "string", format: "uuid" },
          protocolVersion: { type: "integer", enum: [2], description: "Supply together with mutationID for durable idempotent uploads." },
          mutationID: { type: "string", format: "uuid" },
          changes: { type: "array", maxItems: 1000, items: { type: "object" } }
        }
      }, {
        type: "object", required: ["deviceID", "protocolVersion", "mutationID", "operations"], additionalProperties: false,
        properties: {
          deviceID: { type: "string", format: "uuid" }, protocolVersion: { type: "integer", enum: [3, 4] },
          mutationID: { type: "string", format: "uuid" },
          operations: { type: "array", maxItems: 1000, items: { type: "object" },
            description: "Version 3 space/tab intents or version 4 mixed folder/tab intents. See /openapi.yaml for typed operation schemas." }
        }
      }]
    }
  })
  @ApiCreatedResponse({ description: "Sync cursor and accepted remote events." })
  async push(@Body() body: unknown, @Headers("authorization") authorization?: string) {
    const request = parseRequest(SyncPushRequest, body);
    const userID = await this.auth.userIDFromAuthorizationHeader(authorization);
    return this.sync.push(userID, request);
  }

  @Post("pull")
  @ApiBearerAuth("bearerAuth")
  @ApiOperation({ summary: "Pull remote sync changes" })
  @ApiBody({
    schema: {
      type: "object",
      required: ["deviceID"],
      additionalProperties: false,
      properties: {
        deviceID: { type: "string", format: "uuid" },
        protocolVersion: { type: "integer", enum: [4], description: "Opt in to folder events. The first version 4 pull after device registration or a legacy pull requires cursor 0." },
        cursor: { type: "integer", minimum: 0, default: 0 },
        limit: { type: "integer", minimum: 1, maximum: 1000, default: 500 }
      }
    }
  })
  @ApiCreatedResponse({ description: "Sync cursor and remote events after the requested cursor." })
  async pull(@Body() body: unknown, @Headers("authorization") authorization?: string) {
    const request = parseRequest(SyncPullRequest, body);
    const userID = await this.auth.userIDFromAuthorizationHeader(authorization);
    return this.sync.pull(userID, request);
  }
}
