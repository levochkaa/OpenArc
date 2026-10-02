import { z } from "zod";

export const AuthAppleRequest = z.object({
  identityToken: z.string().min(1),
  deviceName: z.string().min(1).max(120).default("Mac"),
  devicePlatform: z.string().min(1).max(60).default("macOS")
});

export const RegisterDeviceRequest = z.object({
  name: z.string().min(1).max(120),
  platform: z.string().min(1).max(60),
  publicKey: z.string().max(4096).optional()
});

export const SpacePayload = z.object({
  title: z.string().min(1),
  systemImageName: z.string().min(1),
  rank: z.number().finite(),
  isPinnedSectionCollapsed: z.boolean().default(false),
  selectedTabID: z.string().nullable().optional()
});

export const TabPayload = z.object({
  spaceID: z.string().min(1),
  placement: z.enum(["temporary", "spacePinned", "app"]),
  rank: z.number().finite(),
  urlString: z.string().min(1),
  pinnedURLString: z.string().min(1).nullable().optional(),
  title: z.string().nullable().optional(),
  userTitleOverride: z.string().nullable().optional(),
  faviconURLString: z.string().nullable().optional(),
  lastActivityAt: z.string().datetime().nullable().optional()
});

export const SyncChange = z.discriminatedUnion("entityType", [
  z.object({
    entityType: z.literal("space"),
    entityID: z.string().min(1),
    op: z.enum(["upsert", "delete"]),
    data: SpacePayload.optional()
  }),
  z.object({
    entityType: z.literal("tab"),
    entityID: z.string().min(1),
    op: z.enum(["upsert", "delete"]),
    data: TabPayload.optional()
  })
]).superRefine((change, context) => {
  if (change.op === "upsert" && !change.data) {
    context.addIssue({ code: "custom", path: ["data"], message: "Upsert requires entity data" });
  }
});

export const SyncPushRequest = z.object({
  deviceID: z.string().uuid(),
  changes: z.array(SyncChange).max(1000),
  protocolVersion: z.literal(2).optional(),
  mutationID: z.string().uuid().optional()
}).superRefine((request, context) => {
  if ((request.protocolVersion === undefined) !== (request.mutationID === undefined)) {
    context.addIssue({ code: "custom", message: "protocolVersion 2 and mutationID must be supplied together" });
  }
});

export const SyncPullRequest = z.object({
  deviceID: z.string().uuid(),
  cursor: z.number().int().nonnegative().default(0),
  limit: z.number().int().positive().max(1000).default(500)
});

export type AuthAppleRequest = z.infer<typeof AuthAppleRequest>;
export type RegisterDeviceRequest = z.infer<typeof RegisterDeviceRequest>;
export type SyncChange = z.infer<typeof SyncChange>;
export type SyncPushRequest = z.infer<typeof SyncPushRequest>;
export type SyncPullRequest = z.infer<typeof SyncPullRequest>;
