// Request shapes the black-box tests send. The server's own validation is
// in `src/requests.rs`; these types only help the test code type-check.

type Placement = "temporary" | "spacePinned" | "app";
type EntityType = "space" | "tab" | "folder";

export type SpacePayload = {
  title: string; systemImageName: string; rank: number;
  isPinnedSectionCollapsed?: boolean; selectedTabID?: string | null;
};

export type TabPayload = {
  spaceID: string; placement: Placement; rank: number; urlString: string;
  pinnedURLString?: string | null; title?: string | null; userTitleOverride?: string | null;
  faviconURLString?: string | null; lastActivityAt?: string | null;
};

export type SyncChange =
  | { entityType: "space"; entityID: string; op: "upsert" | "delete"; data?: SpacePayload }
  | { entityType: "tab"; entityID: string; op: "upsert" | "delete"; data?: TabPayload };

type Anchors = { beforeID?: string | null; afterID?: string | null };
type SpaceCreateData = Omit<SpacePayload, "rank">;
type TabCreateData = Omit<TabPayload, "rank">;

export type SyncOperation =
  | ({ kind: "create"; entityType: "space"; entityID: string; data: SpaceCreateData } & Anchors)
  | ({ kind: "create"; entityType: "tab"; entityID: string; data: TabCreateData } & Anchors)
  | { kind: "patch"; entityType: "space"; entityID: string; fields: Partial<Omit<SpaceCreateData, never>> }
  | { kind: "patch"; entityType: "tab"; entityID: string; fields: Partial<Omit<TabCreateData, "spaceID" | "placement">> }
  | ({ kind: "move"; entityType: "space"; entityIDs: string[] } & Anchors)
  | ({ kind: "move"; entityType: "tab"; entityIDs: string[]; destination: { spaceID: string; placement: Placement } } & Anchors)
  | { kind: "delete"; entityType: "space" | "tab"; entityID: string };

export type SyncEntityReferenceV4 = { entityType: EntityType; entityID: string };
type TypedAnchors = { before?: SyncEntityReferenceV4 | null; after?: SyncEntityReferenceV4 | null };
export type SyncDestinationV4 = { kind: "spaces" }
  | { kind: "tabs"; spaceID: string; placement: Placement; pinnedFolderID: string | null };
type FolderCreateData = { spaceID: string; parentFolderID: string | null; title: string; systemImageName?: string | null };

export type SyncOperationV4 =
  | ({ kind: "create"; entityType: "space"; entityID: string; data: SpaceCreateData } & TypedAnchors)
  | ({ kind: "create"; entityType: "tab"; entityID: string; data: TabCreateData & { pinnedFolderID: string | null } } & TypedAnchors)
  | ({ kind: "create"; entityType: "folder"; entityID: string; data: FolderCreateData } & TypedAnchors)
  | { kind: "patch"; entityType: "space"; entityID: string; fields: Partial<SpaceCreateData> }
  | { kind: "patch"; entityType: "tab"; entityID: string; fields: Partial<Omit<TabCreateData, "spaceID" | "placement">> }
  | { kind: "patch"; entityType: "folder"; entityID: string; fields: { title?: string; systemImageName?: string | null } }
  | ({ kind: "move"; items: SyncEntityReferenceV4[]; destination: SyncDestinationV4 } & TypedAnchors)
  | { kind: "delete"; entityType: EntityType; entityID: string };

export type SyncExpiryOperation = {
  kind: "expire"; entityType: "tab"; entityID: string; expectedServerSeq: number;
  inactiveForSeconds: 43200 | 86400 | 259200 | 604800 | 2592000;
};
