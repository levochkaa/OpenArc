import { Controller, Get, Res } from "@nestjs/common";
import { ApiExcludeEndpoint } from "@nestjs/swagger";
import type { Response } from "express";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const openAPIYAMLPath = join(dirname(fileURLToPath(import.meta.url)), "../openapi.yaml");

@Controller()
export class OpenAPIYAMLController {
  @Get("openapi.yaml")
  @ApiExcludeEndpoint()
  async openAPIYAML(@Res() reply: Response) {
    const yaml = await readFile(openAPIYAMLPath, "utf8");
    return reply.type("application/yaml; charset=utf-8").send(yaml);
  }
}
