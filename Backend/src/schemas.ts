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

const LegacySyncPushRequest = z.object({
  deviceID: z.string().uuid(),
  changes: z.array(SyncChange).max(1000),
  protocolVersion: z.literal(2).optional(),
  mutationID: z.string().uuid().optional()
}).superRefine((request, context) => {
  if ((request.protocolVersion === undefined) !== (request.mutationID === undefined)) {
    context.addIssue({ code: "custom", message: "protocolVersion 2 and mutationID must be supplied together" });
  }
});

const EntityID = z.string().min(1);
const Anchors = { beforeID: EntityID.nullable().optional(), afterID: EntityID.nullable().optional() };
const SpaceCreateData = SpacePayload.omit({ rank: true }).strict();
const TabCreateData = TabPayload.omit({ rank: true }).strict();
const SpacePatchFields = SpaceCreateData.omit({ isPinnedSectionCollapsed: true }).partial()
  .extend({ isPinnedSectionCollapsed: z.boolean().optional() }).strict()
  .refine((fields) => Object.keys(fields).length > 0, "Patch requires fields");
const TabPatchFields = TabCreateData.omit({ spaceID: true, placement: true }).partial()
  .refine((fields) => Object.keys(fields).length > 0, "Patch requires fields");
const MoveIDs = z.array(EntityID).min(1).max(1000)
  .refine((ids) => new Set(ids).size === ids.length, "Move IDs must be unique");

export const SyncOperation = z.union([
  z.object({ kind: z.literal("create"), entityType: z.literal("space"), entityID: EntityID, data: SpaceCreateData, ...Anchors }).strict(),
  z.object({ kind: z.literal("create"), entityType: z.literal("tab"), entityID: EntityID, data: TabCreateData, ...Anchors }).strict(),
  z.object({ kind: z.literal("patch"), entityType: z.literal("space"), entityID: EntityID, fields: SpacePatchFields }).strict(),
  z.object({ kind: z.literal("patch"), entityType: z.literal("tab"), entityID: EntityID, fields: TabPatchFields }).strict(),
  z.object({ kind: z.literal("move"), entityType: z.literal("space"), entityIDs: MoveIDs, ...Anchors }).strict(),
  z.object({
    kind: z.literal("move"), entityType: z.literal("tab"), entityIDs: MoveIDs,
    destination: z.object({ spaceID: EntityID, placement: TabPayload.shape.placement }).strict(), ...Anchors
  }).strict(),
  z.object({ kind: z.literal("delete"), entityType: z.enum(["space", "tab"]), entityID: EntityID }).strict()
]).superRefine((operation, context) => {
  if (operation.kind === "move" && [operation.beforeID, operation.afterID].some((id) => id != null && operation.entityIDs.includes(id))) {
    context.addIssue({ code: "custom", message: "Move anchors cannot belong to the moving group" });
  }
});

const SemanticSyncPushRequest = z.object({
  deviceID: z.string().uuid(), protocolVersion: z.literal(3), mutationID: z.string().uuid(),
  operations: z.array(SyncOperation).max(1000)
}).strict();

// V4 uses distinct schemas so older immutable mutations retain their original
// parsing, defaults and receipt digests. Folder expansion stays device-local.
export const FolderPayload = z.object({
  spaceID: EntityID,
  parentFolderID: EntityID.nullable(),
  title: z.string().min(1),
  systemImageName: z.string().min(1).nullable().optional(),
  rank: z.number().finite()
}).strict();

const TabFieldsV4 = TabPayload.extend({ pinnedFolderID: EntityID.nullable() }).strict();
const validateTabFolder = (
  data: { placement: "temporary" | "spacePinned" | "app"; pinnedFolderID: string | null },
  context: z.RefinementCtx
) => {
  if (data.placement !== "spacePinned" && data.pinnedFolderID !== null) {
    context.addIssue({ code: "custom", path: ["pinnedFolderID"], message: "Only pinned tabs can belong to a folder" });
  }
};
export const TabPayloadV4 = TabFieldsV4.superRefine(validateTabFolder);
const TabCreateDataV4 = TabFieldsV4.omit({ rank: true }).superRefine(validateTabFolder);
const FolderCreateData = FolderPayload.omit({ rank: true });
const FolderPatchFields = FolderPayload.pick({ title: true, systemImageName: true }).partial()
  .refine((fields) => Object.keys(fields).length > 0, "Patch requires fields");

export const SyncChangeV4 = z.discriminatedUnion("entityType", [
  z.object({
    entityType: z.literal("space"), entityID: EntityID,
    op: z.enum(["upsert", "delete"]), data: SpacePayload.optional()
  }).strict(),
  z.object({
    entityType: z.literal("tab"), entityID: EntityID,
    op: z.enum(["upsert", "delete"]), data: TabPayloadV4.optional()
  }).strict(),
  z.object({
    entityType: z.literal("folder"), entityID: EntityID,
    op: z.enum(["upsert", "delete"]), data: FolderPayload.optional()
  }).strict()
]).superRefine((change, context) => {
  if (change.op === "upsert" && !change.data) {
    context.addIssue({ code: "custom", path: ["data"], message: "Upsert requires entity data" });
  }
});

export const SyncEntityReferenceV4 = z.object({
  entityType: z.enum(["space", "tab", "folder"]), entityID: EntityID
}).strict();
const TypedAnchors = {
  before: SyncEntityReferenceV4.nullable().optional(),
  after: SyncEntityReferenceV4.nullable().optional()
};
const entityReferenceKey = (reference: z.infer<typeof SyncEntityReferenceV4>) =>
  `${reference.entityType}:${reference.entityID}`;
const MoveItemsV4 = z.array(SyncEntityReferenceV4).min(1).max(1000)
  .refine((items) => new Set(items.map(entityReferenceKey)).size === items.length, "Move items must be unique");
export const SyncDestinationV4 = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("spaces") }).strict(),
  z.object({
    kind: z.literal("tabs"), spaceID: EntityID,
    placement: TabPayload.shape.placement, pinnedFolderID: EntityID.nullable()
  }).strict()
]).superRefine((destination, context) => {
  if (destination.kind === "tabs") validateTabFolder(destination, context);
});

export const SyncOperationV4 = z.union([
  z.object({
    kind: z.literal("create"), entityType: z.literal("space"), entityID: EntityID,
    data: SpaceCreateData, ...TypedAnchors
  }).strict(),
  z.object({
    kind: z.literal("create"), entityType: z.literal("tab"), entityID: EntityID,
    data: TabCreateDataV4, ...TypedAnchors
  }).strict(),
  z.object({
    kind: z.literal("create"), entityType: z.literal("folder"), entityID: EntityID,
    data: FolderCreateData, ...TypedAnchors
  }).strict(),
  z.object({ kind: z.literal("patch"), entityType: z.literal("space"), entityID: EntityID, fields: SpacePatchFields }).strict(),
  z.object({ kind: z.literal("patch"), entityType: z.literal("tab"), entityID: EntityID, fields: TabPatchFields }).strict(),
  z.object({ kind: z.literal("patch"), entityType: z.literal("folder"), entityID: EntityID, fields: FolderPatchFields }).strict(),
  z.object({ kind: z.literal("move"), items: MoveItemsV4, destination: SyncDestinationV4, ...TypedAnchors }).strict(),
  z.object({ kind: z.literal("delete"), entityType: z.enum(["space", "tab", "folder"]), entityID: EntityID }).strict()
]).superRefine((operation, context) => {
  if (operation.kind !== "move") return;
  const keys = new Set(operation.items.map(entityReferenceKey));
  if ([operation.before, operation.after].some((anchor) => anchor != null && keys.has(entityReferenceKey(anchor)))) {
    context.addIssue({ code: "custom", message: "Move anchors cannot belong to the moving group" });
  }
  const destination = operation.destination;
  if (destination.kind === "spaces") {
    if (operation.items.some((item) => item.entityType !== "space")) {
      context.addIssue({ code: "custom", path: ["items"], message: "Only spaces belong to the spaces list" });
    }
  } else if (operation.items.some((item) => item.entityType === "space"
    || (item.entityType === "folder" && destination.placement !== "spacePinned"))) {
    context.addIssue({ code: "custom", path: ["items"], message: "Folders require a pinned destination; spaces cannot move into tab lists" });
  }
});

export const SyncPushRequestV4 = z.object({
  deviceID: z.string().uuid(), protocolVersion: z.literal(4), mutationID: z.string().uuid(),
  operations: z.array(SyncOperationV4).max(1000)
}).strict();

// Expiry has its own envelope: it must never degrade into an unconditional
// legacy delete, and existing immutable v2/v3/v4 parsing stays unchanged.
export const SyncExpiryOperation = z.object({
  kind: z.literal("expire"), entityType: z.literal("tab"), entityID: EntityID,
  expectedServerSeq: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  inactiveForSeconds: z.union([z.literal(43200), z.literal(86400), z.literal(259200), z.literal(604800), z.literal(2592000)])
}).strict();
export const SyncPushRequestV5 = z.object({
  deviceID: z.string().uuid(), protocolVersion: z.literal(5), mutationID: z.string().uuid(),
  operations: z.array(SyncExpiryOperation).max(100)
}).strict();

export const SyncPushRequest = z.union([SyncPushRequestV5, SyncPushRequestV4, SemanticSyncPushRequest, LegacySyncPushRequest]);

const LegacySyncPullRequest = z.object({
  deviceID: z.string().uuid(),
  cursor: z.number().int().nonnegative().default(0),
  limit: z.number().int().positive().max(1000).default(500)
});
export const SyncPullRequestV4 = LegacySyncPullRequest.extend({ protocolVersion: z.literal(4) }).strict();
export const SyncPullRequestV5 = LegacySyncPullRequest.extend({ protocolVersion: z.literal(5) }).strict();
// Do not let a malformed explicit versioned request fall back to the legacy parser,
// which intentionally strips unknown fields for existing clients.
export const SyncPullRequest = z.union([
  SyncPullRequestV5,
  SyncPullRequestV4,
  LegacySyncPullRequest.extend({ protocolVersion: z.undefined().optional() })
]);

export type AuthAppleRequest = z.infer<typeof AuthAppleRequest>;
export type RegisterDeviceRequest = z.infer<typeof RegisterDeviceRequest>;
export type SyncChange = z.infer<typeof SyncChange>;
export type SyncOperation = z.infer<typeof SyncOperation>;
export type SyncChangeV4 = z.infer<typeof SyncChangeV4>;
export type SyncOperationV4 = z.infer<typeof SyncOperationV4>;
export type SyncEntityReferenceV4 = z.infer<typeof SyncEntityReferenceV4>;
export type SyncDestinationV4 = z.infer<typeof SyncDestinationV4>;
export type SyncPushRequestV4 = z.infer<typeof SyncPushRequestV4>;
export type SyncExpiryOperation = z.infer<typeof SyncExpiryOperation>;
export type SyncPushRequestV5 = z.infer<typeof SyncPushRequestV5>;
export type SyncPullRequestV4 = z.infer<typeof SyncPullRequestV4>;
export type SyncPullRequestV5 = z.infer<typeof SyncPullRequestV5>;
export type FolderPayload = z.infer<typeof FolderPayload>;
export type TabPayloadV4 = z.infer<typeof TabPayloadV4>;
export type SpacePayload = z.infer<typeof SpacePayload>;
export type TabPayload = z.infer<typeof TabPayload>;
export type SyncPushRequest = z.infer<typeof SyncPushRequest>;
export type SyncPullRequest = z.infer<typeof SyncPullRequest>;
