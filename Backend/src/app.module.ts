import { Module } from "@nestjs/common";
import { AuthController } from "./auth.controller.js";
import { AuthService } from "./auth.service.js";
import { DatabaseService } from "./database.service.js";
import { DevicesController } from "./devices.controller.js";
import { OpenAPIYAMLController } from "./openapi-yaml.controller.js";
import { SyncController } from "./sync.controller.js";
import { SyncService } from "./sync.service.js";
import { SystemController } from "./system.controller.js";
import { UpdatesController } from "./updates.controller.js";
import { UpdatesService } from "./updates.service.js";

@Module({
  controllers: [
    SystemController,
    OpenAPIYAMLController,
    AuthController,
    DevicesController,
    SyncController,
    UpdatesController
  ],
  providers: [AuthService, DatabaseService, SyncService, UpdatesService]
})
export class AppModule {}
