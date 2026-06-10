import "reflect-metadata";
import type { INestApplication, NestApplicationOptions } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";
import { DocumentBuilder, SwaggerModule } from "@nestjs/swagger";
import compression from "compression";
import { AppModule } from "./app.module.js";
import { config } from "./config.js";

export async function buildApp(options: NestApplicationOptions = {}): Promise<INestApplication> {
  const app = await NestFactory.create(AppModule, {
    ...options,
    logger: options.logger === false ? false : options.logger
  });

  app.use(
    compression({
      threshold: 1024
    })
  );

  if (config.CORS_ORIGIN) {
    app.enableCors({
      origin: config.CORS_ORIGIN
    });
  }

  registerSwagger(app);
  await app.init();

  return app;
}

function registerSwagger(app: INestApplication): void {
  const openAPIConfig = new DocumentBuilder()
    .setTitle("TheBrowser Sync API")
    .setDescription("Backend API for TheBrowser authentication, device registration, sync, and app updates.")
    .setVersion("0.1.0")
    .addServer(config.THEBROWSER_PUBLIC_BASE_URL ?? "/")
    .addTag("System")
    .addTag("Authentication")
    .addTag("Devices")
    .addTag("Sync")
    .addTag("Updates")
    .addBearerAuth(
      {
        type: "http",
        scheme: "bearer",
        bearerFormat: "JWT"
      },
      "bearerAuth"
    )
    .build();

  const document = SwaggerModule.createDocument(app, openAPIConfig);
  document.openapi = "3.1.0";
  SwaggerModule.setup("docs", app, document, {
    jsonDocumentUrl: "/openapi.json",
    swaggerOptions: {
      deepLinking: true,
      docExpansion: "list"
    }
  });
}
