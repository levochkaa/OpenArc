import dotenv from "dotenv";
import { z } from "zod";

dotenv.config();

const ConfigSchema = z.object({
  DATABASE_URL: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(8080),
  HOST: z.string().default("0.0.0.0"),
  APPLE_CLIENT_ID: z.string().min(1),
  JWT_SECRET: z.string().min(32),
  JWT_ISSUER: z.string().default("thebrowser-sync"),
  JWT_AUDIENCE: z.string().default("thebrowser-clients"),
  CORS_ORIGIN: z.string().optional().default(""),
  GITHUB_RELEASE_REPOSITORY: z.string().optional(),
  GITHUB_RELEASE_TOKEN: z.string().optional().default(""),
  THEBROWSER_PUBLIC_BASE_URL: z.string().url().optional(),
  THEBROWSER_UPDATE_APPCAST_ASSET: z.string().min(1).default("appcast.xml")
});

export const config = ConfigSchema.parse(process.env);
