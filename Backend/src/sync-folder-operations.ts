import type pg from "pg";
import type { FolderPayload, SpacePayload, SyncChangeV4, SyncOperationV4, TabPayloadV4 } from "./schemas.js";
import type { OperationOutcome } from "./sync-operations.js";

type EntityType = "space" | "tab" | "folder";
type Reference = { entityType: EntityType; entityID: string };
type Entity = { entityType: "space"; entityID: string; data: SpacePayload }
  | { entityType: "tab"; entityID: string; data: TabPayloadV4 }
  | { entityType: "folder"; entityID: string; data: FolderPayload };
type FolderEntity = Extract<Entity, { entityType: "folder" }>;
type Container = { kind: "spaces" }
  | { kind: "tabs"; spaceID: string; placement: TabPayloadV4["placement"]; pinnedFolderID: string | null };
type Anchors = { before?: Reference | null; after?: Reference | null };
type Result = { events: FolderOperationEvent[]; outcome: OperationOutcome };

export type FolderOperationEvent = {
  serverSeq: number;
  deviceID: string | null;
  entityType: EntityType;
  entityID: string;
  op: "upsert" | "delete";
  data: unknown;
  createdAt: string;
};

export type FolderOperationHooks = {
  // These writes and cascades must use the same account-locked transaction.
  apply: (change: SyncChangeV4) => Promise<FolderOperationEvent[]>;
  tombstone: (type: EntityType, id: string) => Promise<FolderOperationEvent | undefined>;
  currentEvent: (type: EntityType, id: string) => Promise<FolderOperationEvent | undefined>;
};

// V4 has one order for mixed folder/tab siblings. The service owns transaction,
// account locking, immutable mutation receipts and canonical delete cascades.
export class SyncFolderOperationExecutor {
  constructor(private readonly client: pg.PoolClient, private readonly userID: string,
    private readonly hooks: FolderOperationHooks) {}

  async apply(operation: SyncOperationV4, operationIndex: number): Promise<Result> {
    if (operation.kind === "move") return this.move(operation, operationIndex);
    const deleted = await this.hooks.tombstone(operation.entityType, operation.entityID);
    if (deleted) return { events: [deleted], outcome: { operationIndex, status: "deleted" } };
    const existing = (await this.readEntities([operation]))[0];

    if (operation.kind === "delete") {
      const events = await this.hooks.apply({ entityType: operation.entityType, entityID: operation.entityID, op: "delete" });
      if (existing) {
        const siblings = await this.readContainer(this.container(existing));
        events.push(...await this.publishOrder(siblings, this.byKey(siblings)));
      }
      return { events, outcome: { operationIndex, status: "applied" } };
    }
    if (operation.kind === "patch") {
      if (!existing) return this.rejected(operationIndex, "missing");
      const next: Entity = existing.entityType === "space" && operation.entityType === "space"
        ? { ...existing, data: { ...existing.data, ...operation.fields } }
        : existing.entityType === "tab" && operation.entityType === "tab"
          ? { ...existing, data: { ...existing.data, ...operation.fields } }
          : existing.entityType === "folder" && operation.entityType === "folder"
            ? { ...existing, data: { ...existing.data, ...operation.fields } } : existing;
      return { events: await this.publishEntity(next, existing), outcome: { operationIndex, status: "applied" } };
    }
    if (existing) return this.rejected(operationIndex, "entity_exists", await this.currentEvents([existing]));
    const entity: Entity = operation.entityType === "space"
      ? { entityType: "space", entityID: operation.entityID, data: { ...operation.data, rank: 0 } }
      : operation.entityType === "folder"
        ? { entityType: "folder", entityID: operation.entityID, data: { ...operation.data, rank: 0 } }
        : { entityType: "tab", entityID: operation.entityID, data: { ...operation.data, rank: 0 } };
    const destination = this.container(entity);
    const failure = await this.validateDestination(destination);
    if (failure) return this.rejected(operationIndex, failure.reason, failure.events);
    const siblings = await this.readContainer(destination);
    return { events: await this.publishOrder(this.insert(siblings, [entity], operation), this.byKey(siblings)),
      outcome: { operationIndex, status: "applied" } };
  }

  private async move(operation: Extract<SyncOperationV4, { kind: "move" }>, operationIndex: number): Promise<Result> {
    const found = this.byKey(await this.readEntities(operation.items));
    const survivors = operation.items.flatMap((item) => found.has(this.key(item)) ? [found.get(this.key(item))!] : []);
    const events: FolderOperationEvent[] = [];
    for (const item of operation.items.filter((item) => !found.has(this.key(item)))) {
      const deleted = await this.hooks.tombstone(item.entityType, item.entityID);
      if (deleted) events.push(deleted);
    }
    const destination: Container = operation.destination;
    if (survivors.some((entity) => destination.kind === "spaces" ? entity.entityType !== "space"
      : entity.entityType === "space" || (entity.entityType === "folder" && destination.placement !== "spacePinned"))) {
      return this.rejected(operationIndex, "invalid_destination", [...events, ...await this.currentEvents(survivors)]);
    }
    const failure = await this.validateDestination(destination);
    if (failure) return this.rejected(operationIndex, failure.reason,
      [...events, ...failure.events, ...await this.currentEvents(survivors)]);
    if (!survivors.length) return events.length ? { events, outcome: { operationIndex, status: "deleted" } }
      : this.rejected(operationIndex, "missing");

    const roots = survivors.filter((entity): entity is FolderEntity => entity.entityType === "folder");
    const subtree = await this.readFolderSubtrees(roots.map((entity) => entity.entityID));
    const subtreeIDs = new Set(subtree.map((entity) => entity.entityID));
    // Explicit selection of a parent and its child is ambiguous. Carrying the
    // parent's current subtree is one intent; reject the whole mixed operation.
    if (survivors.some((entity) => entity.entityType === "folder"
      ? entity.data.parentFolderID != null && subtreeIDs.has(entity.data.parentFolderID)
      : entity.entityType === "tab" && entity.data.placement === "spacePinned"
        && entity.data.pinnedFolderID != null && subtreeIDs.has(entity.data.pinnedFolderID))) {
      return this.rejected(operationIndex, "overlapping_items", [...events, ...await this.currentEvents(survivors)]);
    }
    if (destination.kind === "tabs" && destination.pinnedFolderID != null && subtreeIDs.has(destination.pinnedFolderID)) {
      return this.rejected(operationIndex, "cycle", [...events, ...await this.currentEvents(survivors)]);
    }
    const descendants = this.parentFirst(subtree, roots.map((entity) => entity.entityID));
    if (descendants.length !== subtree.length) {
      return this.rejected(operationIndex, "cycle", [...events, ...await this.currentEvents(survivors)]);
    }

    const movedKeys = new Set(survivors.map((entity) => this.key(entity)));
    const sources = new Map(survivors.map((entity) => {
      const container = this.container(entity);
      return [this.containerKey(container), container];
    }));
    const targetRows = await this.readContainer(destination);
    const originals = this.byKey([...targetRows, ...survivors]);
    const moved = survivors.map((entity) => this.movedEntity(entity, destination));
    // Every destination, overlap and cycle check precedes the first write.
    for (const [key, source] of sources) {
      if (key === this.containerKey(destination)) continue;
      const rows = await this.readContainer(source);
      events.push(...await this.publishOrder(rows.filter((entity) => !movedKeys.has(this.key(entity))), this.byKey(rows)));
    }
    events.push(...await this.publishOrder(
      this.insert(targetRows.filter((entity) => !movedKeys.has(this.key(entity))), moved, operation), originals
    ));
    if (destination.kind === "tabs") {
      // Root folders have already moved. Publish parents before children, then
      // tabs, so canonical parent validation never observes a stale space ID.
      const rootIDs = new Set(roots.map((entity) => entity.entityID));
      for (const folder of descendants) {
        if (rootIDs.has(folder.entityID) || folder.data.spaceID === destination.spaceID) continue;
        events.push(...await this.publishEntity({ ...folder, data: { ...folder.data, spaceID: destination.spaceID } }));
      }
      for (const tab of await this.readFolderTabs([...subtreeIDs])) {
        if (tab.data.spaceID === destination.spaceID) continue;
        events.push(...await this.publishEntity({ ...tab, data: { ...tab.data, spaceID: destination.spaceID } }));
      }
    }
    events.push(...await this.currentEvents(survivors));
    return { events, outcome: { operationIndex, status: "applied" } };
  }

  private movedEntity(entity: Entity, destination: Container): Entity {
    if (entity.entityType === "space" || destination.kind === "spaces") return entity;
    if (entity.entityType === "folder") return { ...entity, data: {
      ...entity.data, spaceID: destination.spaceID, parentFolderID: destination.pinnedFolderID
    } };
    const pinnedURLString = destination.placement !== "spacePinned" ? null
      : entity.data.placement === "spacePinned" ? entity.data.pinnedURLString ?? null : entity.data.urlString;
    return { ...entity, data: { ...entity.data, spaceID: destination.spaceID, placement: destination.placement,
      pinnedFolderID: destination.pinnedFolderID, pinnedURLString } };
  }

  private async validateDestination(container: Container): Promise<{ reason: string; events: FolderOperationEvent[] } | undefined> {
    if (container.kind === "spaces") return undefined;
    if (container.placement !== "spacePinned" && container.pinnedFolderID != null) {
      return { reason: "invalid_destination", events: [] };
    }
    if (container.placement === "app") return undefined;
    const spaceDeleted = await this.hooks.tombstone("space", container.spaceID);
    if (spaceDeleted) return { reason: "target_deleted", events: [spaceDeleted] };
    if (!(await this.readEntities([{ entityType: "space", entityID: container.spaceID }])).length) {
      return { reason: "target_missing", events: [] };
    }
    const seen = new Set<string>();
    let parent = container.pinnedFolderID;
    while (parent != null) {
      if (seen.has(parent)) return { reason: "cycle", events: [] };
      seen.add(parent);
      const deleted = await this.hooks.tombstone("folder", parent);
      if (deleted) return { reason: "target_deleted", events: [deleted] };
      const folder = (await this.readEntities([{ entityType: "folder", entityID: parent }]))[0];
      if (!folder || folder.entityType !== "folder") return { reason: "target_missing", events: [] };
      if (folder.data.spaceID !== container.spaceID) {
        return { reason: "target_wrong_space", events: await this.currentEvents([folder]) };
      }
      parent = folder.data.parentFolderID;
    }
    return undefined;
  }

  private parentFirst(folders: FolderEntity[], rootIDs: string[]): FolderEntity[] {
    const byID = new Map(folders.map((folder) => [folder.entityID, folder]));
    const children = new Map<string, FolderEntity[]>();
    for (const folder of folders) {
      if (folder.data.parentFolderID == null) continue;
      const siblings = children.get(folder.data.parentFolderID) ?? [];
      siblings.push(folder);
      children.set(folder.data.parentFolderID, siblings);
    }
    const result: FolderEntity[] = [], seen = new Set<string>();
    const queue = rootIDs.flatMap((id) => byID.has(id) ? [byID.get(id)!] : []);
    for (let index = 0; index < queue.length; index += 1) {
      const folder = queue[index];
      if (seen.has(folder.entityID)) continue;
      seen.add(folder.entityID);
      result.push(folder);
      for (const child of children.get(folder.entityID) ?? []) queue.push(child);
    }
    return result;
  }

  private insert(siblings: Entity[], group: Entity[], anchors: Anchors): Entity[] {
    const before = anchors.before == null ? -1 : siblings.findIndex((entity) => this.key(entity) === this.key(anchors.before!));
    const after = anchors.after == null ? -1 : siblings.findIndex((entity) => this.key(entity) === this.key(anchors.after!));
    const index = before >= 0 ? before : after >= 0 ? after + 1 : siblings.length;
    return [...siblings.slice(0, index), ...group, ...siblings.slice(index)];
  }

  private async publishOrder(ordered: Entity[], originals: Map<string, Entity>): Promise<FolderOperationEvent[]> {
    const events: FolderOperationEvent[] = [];
    for (const [rank, entity] of ordered.entries()) {
      const updated = { ...entity, data: { ...entity.data, rank } } as Entity;
      const previous = originals.get(this.key(entity));
      if (previous && JSON.stringify(previous.data) === JSON.stringify(updated.data)) continue;
      events.push(...await this.publishEntity(updated));
    }
    return events;
  }

  private async publishEntity(entity: Entity, previous?: Entity): Promise<FolderOperationEvent[]> {
    if (previous && JSON.stringify(previous.data) === JSON.stringify(entity.data)) return this.currentEvents([entity]);
    switch (entity.entityType) {
      case "space": return this.hooks.apply({ entityType: "space", entityID: entity.entityID, op: "upsert", data: entity.data });
      case "folder": return this.hooks.apply({ entityType: "folder", entityID: entity.entityID, op: "upsert", data: entity.data });
      case "tab": return this.hooks.apply({ entityType: "tab", entityID: entity.entityID, op: "upsert", data: entity.data });
    }
  }

  private async currentEvents(entities: Reference[]): Promise<FolderOperationEvent[]> {
    const events: FolderOperationEvent[] = [];
    for (const entity of entities) {
      const event = await this.hooks.currentEvent(entity.entityType, entity.entityID);
      if (event) events.push(event);
    }
    return events;
  }

  private rejected(operationIndex: number, reason: string, events: FolderOperationEvent[] = []): Result {
    return { events, outcome: { operationIndex, status: "rejected", reason } };
  }

  private key(entity: Reference): string { return JSON.stringify([entity.entityType, entity.entityID]); }
  private byKey(entities: Entity[]): Map<string, Entity> { return new Map(entities.map((entity) => [this.key(entity), entity])); }

  private container(entity: Entity): Container {
    if (entity.entityType === "space") return { kind: "spaces" };
    if (entity.entityType === "folder") return { kind: "tabs", spaceID: entity.data.spaceID,
      placement: "spacePinned", pinnedFolderID: entity.data.parentFolderID };
    return { kind: "tabs", spaceID: entity.data.spaceID, placement: entity.data.placement,
      pinnedFolderID: entity.data.placement === "spacePinned" ? entity.data.pinnedFolderID : null };
  }

  private containerKey(container: Container): string {
    return container.kind === "spaces" ? "spaces" : JSON.stringify([
      container.placement, container.placement === "app" ? null : container.spaceID, container.pinnedFolderID
    ]);
  }

  private async readEntities(references: Reference[]): Promise<Entity[]> {
    const entities: Entity[] = [];
    for (const type of ["space", "tab", "folder"] as const) {
      const ids = references.filter((reference) => reference.entityType === type).map((reference) => reference.entityID);
      if (!ids.length) continue;
      const table = type === "space" ? "spaces" : type === "tab" ? "tabs" : "folders";
      const result = await this.client.query(
        `SELECT * FROM ${table} WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL`, [this.userID, ids]
      );
      entities.push(...result.rows.map((row) => this.entity(type, row)));
    }
    return entities;
  }

  private async readContainer(container: Container): Promise<Entity[]> {
    if (container.kind === "spaces") {
      const result = await this.client.query("SELECT * FROM spaces WHERE user_id = $1 AND deleted_at IS NULL ORDER BY rank, id", [this.userID]);
      return result.rows.map((row) => this.entity("space", row));
    }
    const params: unknown[] = [this.userID, container.placement];
    let predicate = " AND placement = $2";
    if (container.placement !== "app") {
      params.push(container.spaceID);
      predicate += " AND space_id = $3";
    }
    if (container.placement === "spacePinned") {
      params.push(container.pinnedFolderID);
      predicate += " AND pinned_folder_id IS NOT DISTINCT FROM $4::text";
    }
    const tabs = await this.client.query(`SELECT * FROM tabs WHERE user_id = $1 AND deleted_at IS NULL${predicate}`, params);
    const entities = tabs.rows.map((row) => this.entity("tab", row));
    if (container.placement === "spacePinned") {
      const folders = await this.client.query(
        `SELECT * FROM folders WHERE user_id = $1 AND space_id = $2 AND deleted_at IS NULL
         AND parent_folder_id IS NOT DISTINCT FROM $3::text`, [this.userID, container.spaceID, container.pinnedFolderID]
      );
      entities.push(...folders.rows.map((row) => this.entity("folder", row)));
    }
    return entities.sort((a, b) => a.data.rank - b.data.rank || (this.key(a) < this.key(b) ? -1 : this.key(a) > this.key(b) ? 1 : 0));
  }

  private async readFolderSubtrees(rootIDs: string[]): Promise<FolderEntity[]> {
    if (!rootIDs.length) return [];
    // UNION (not UNION ALL) also terminates if preexisting data contains a cycle.
    const result = await this.client.query(
      `WITH RECURSIVE subtree AS (
         SELECT * FROM folders WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL
         UNION
         SELECT child.* FROM folders child JOIN subtree parent ON child.parent_folder_id = parent.id
         WHERE child.user_id = $1 AND child.deleted_at IS NULL
       ) SELECT * FROM subtree`, [this.userID, rootIDs]
    );
    return result.rows.map((row) => this.entity("folder", row) as FolderEntity);
  }

  private async readFolderTabs(folderIDs: string[]): Promise<Extract<Entity, { entityType: "tab" }>[]> {
    if (!folderIDs.length) return [];
    const result = await this.client.query(
      `SELECT * FROM tabs WHERE user_id = $1 AND placement = 'spacePinned'
       AND pinned_folder_id = ANY($2::text[]) AND deleted_at IS NULL ORDER BY id`, [this.userID, folderIDs]
    );
    return result.rows.map((row) => this.entity("tab", row) as Extract<Entity, { entityType: "tab" }>);
  }

  private entity(type: EntityType, row: pg.QueryResultRow): Entity {
    if (type === "space") return { entityType: "space", entityID: row.id as string, data: {
      title: row.title as string, systemImageName: row.system_image_name as string, rank: row.rank as number,
      isPinnedSectionCollapsed: row.is_pinned_section_collapsed as boolean, selectedTabID: row.selected_tab_id as string | null
    } };
    if (type === "folder") return { entityType: "folder", entityID: row.id as string, data: {
      spaceID: row.space_id as string, parentFolderID: row.parent_folder_id as string | null,
      title: row.title as string, systemImageName: row.system_image_name as string | null, rank: row.rank as number
    } };
    return { entityType: "tab", entityID: row.id as string, data: {
      spaceID: row.space_id as string, placement: row.placement as TabPayloadV4["placement"], rank: row.rank as number,
      pinnedFolderID: row.pinned_folder_id as string | null,
      urlString: row.url_string as string, pinnedURLString: row.pinned_url_string as string | null,
      title: row.title as string | null, userTitleOverride: row.user_title_override as string | null,
      faviconURLString: row.favicon_url_string as string | null,
      lastActivityAt: row.last_activity_at instanceof Date ? row.last_activity_at.toISOString() : null
    } };
  }
}
