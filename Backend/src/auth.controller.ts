import { Body, Controller, Inject, Post } from "@nestjs/common";
import { ApiBody, ApiOkResponse, ApiOperation, ApiTags } from "@nestjs/swagger";
import { AuthAppleRequest } from "./schemas.js";
import { SyncService } from "./sync.service.js";
import { parseRequest } from "./validation.js";

@ApiTags("Authentication")
@Controller("v1/auth")
export class AuthController {
  constructor(@Inject(SyncService) private readonly sync: SyncService) {}

  @Post("apple")
  @ApiOperation({ summary: "Exchange an Apple identity token for a sync access token" })
  @ApiBody({
    schema: {
      type: "object",
      required: ["identityToken"],
      additionalProperties: false,
      properties: {
        identityToken: { type: "string", minLength: 1 },
        deviceName: { type: "string", minLength: 1, maxLength: 120 },
        devicePlatform: { type: "string", minLength: 1, maxLength: 60 }
      }
    }
  })
  @ApiOkResponse({ description: "Sync access token and registered device." })
  authenticateWithApple(@Body() body: unknown) {
    return this.sync.authenticateWithApple(parseRequest(AuthAppleRequest, body));
  }
}
