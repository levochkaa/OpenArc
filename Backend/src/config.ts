import dotenv from "dotenv";
import { z } from "zod";

dotenv.config();

const AppleClientID = z.string().trim().regex(
  /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/,
  "Apple client IDs must contain only identifier segments, without empty segments or wildcards"
);

const ConfigSchema = z.object({
  DATABASE_URL: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(8080),
  HOST: z.string().default("0.0.0.0"),
  APPLE_CLIENT_ID: AppleClientID.optional(),
  APPLE_CLIENT_IDS: z.string().transform((value) => value.split(",")).pipe(z.array(AppleClientID).min(1)).optional(),
  JWT_SECRET: z.string().min(32),
  JWT_ISSUER: z.string().default("thebrowser-sync"),
  JWT_AUDIENCE: z.string().default("thebrowser-clients"),
  CORS_ORIGIN: z.string().optional().default(""),
  GITHUB_RELEASE_REPOSITORY: z.string().optional(),
  GITHUB_RELEASE_TOKEN: z.string().optional().default(""),
  THEBROWSER_PUBLIC_BASE_URL: z.string().url().optional(),
  THEBROWSER_UPDATE_APPCAST_ASSET: z.string().min(1).default("appcast.xml")
}).superRefine((value, context) => {
  if (value.APPLE_CLIENT_IDS === undefined && value.APPLE_CLIENT_ID === undefined) {
    context.addIssue({ code: "custom", path: ["APPLE_CLIENT_ID"], message: "Configure APPLE_CLIENT_IDS or APPLE_CLIENT_ID" });
  }
}).transform((value) => ({
  ...value,
  APPLE_CLIENT_IDS: [...new Set(value.APPLE_CLIENT_IDS ?? [value.APPLE_CLIENT_ID!])]
}));

export function parseConfig(environment: Record<string, string | undefined>) {
  return ConfigSchema.parse(environment);
}

export const config = parseConfig(process.env);
