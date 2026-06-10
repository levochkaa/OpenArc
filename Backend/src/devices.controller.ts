import { Body, Controller, Headers, Inject, Post } from "@nestjs/common";
import { ApiBearerAuth, ApiBody, ApiOkResponse, ApiOperation, ApiTags } from "@nestjs/swagger";
import { AuthService } from "./auth.service.js";
import { RegisterDeviceRequest } from "./schemas.js";
import { SyncService } from "./sync.service.js";
import { parseRequest } from "./validation.js";

@ApiTags("Devices")
@Controller("v1/devices")
export class DevicesController {
  constructor(
    @Inject(AuthService)
    private readonly auth: AuthService,
    @Inject(SyncService)
    private readonly sync: SyncService
  ) {}

  @Post()
  @ApiBearerAuth("bearerAuth")
  @ApiOperation({ summary: "Register a sync device" })
  @ApiBody({
    schema: {
      type: "object",
      required: ["name", "platform"],
      additionalProperties: false,
      properties: {
        name: { type: "string", minLength: 1, maxLength: 120 },
        platform: { type: "string", minLength: 1, maxLength: 60 },
        publicKey: { type: "string", maxLength: 4096 }
      }
    }
  })
  @ApiOkResponse({ description: "Registered device." })
  async registerDevice(@Body() body: unknown, @Headers("authorization") authorization?: string) {
    const request = parseRequest(RegisterDeviceRequest, body);
    const userID = await this.auth.userIDFromAuthorizationHeader(authorization);
    return this.sync.registerDevice(userID, request);
  }
}
