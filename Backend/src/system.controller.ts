import { Controller, Get } from "@nestjs/common";
import { ApiOkResponse, ApiOperation, ApiTags } from "@nestjs/swagger";

@ApiTags("System")
@Controller()
export class SystemController {
  @Get("health")
  @ApiOperation({ summary: "Check service health" })
  @ApiOkResponse({
    schema: {
      type: "object",
      required: ["ok"],
      additionalProperties: false,
      properties: {
        ok: { type: "boolean" }
      }
    }
  })
  health(): { ok: true } {
    return { ok: true };
  }
}
