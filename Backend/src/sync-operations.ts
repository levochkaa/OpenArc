import type pg from "pg";
import type { SpacePayload, SyncChange, SyncOperation, TabPayload } from "./schemas.js";

export type OperationEvent = {
  serverSeq: number;
  deviceID: string | null;
  entityType: "space" | "tab";
  entityID: string;
  op: "upsert" | "delete";
  data: unknown;
  createdAt: string;
};

export type OperationOutcome = {
  operationIndex: number;
  status: "applied" | "deleted" | "rejected";
  reason?: string;
};

type EntityType = "space" | "tab";
type Entity = { entityType: "space"; entityID: string; data: SpacePayload }
  | { entityType: "tab"; entityID: string; data: TabPayload };
type Container = { entityType: "space" }
  | { entityType: "tab"; spaceID: string; placement: TabPayload["placement"] };
type Anchors = { beforeID?: string | null; afterID?: string | null };
type Hooks = {
  apply: (change: SyncChange) => Promise<OperationEvent[]>;
  tombstone: (type: EntityType, id: string) => Promise<OperationEvent | undefined>;
  currentEvent: (type: EntityType, id: string) => Promise<OperationEvent | undefined>;
};

// The caller owns the account transaction lock. Read current rows before each
// operation: client metadata and ranks never replace unrelated concurrent edits.
export class SyncOperationExecutor {
  constructor(private readonly client: pg.PoolClient, private readonly userID: string, private readonly hooks: Hooks) {}

  async apply(operation: SyncOperation, operationIndex: number): Promise<{ events: OperationEvent[]; outcome: OperationOutcome }> {
    if (operation.kind === "move") return this.move(operation, operationIndex);
    const deleted = await this.hooks.tombstone(operation.entityType, operation.entityID);
    if (deleted) return { events: [deleted], outcome: { operationIndex, status: "deleted" } };
    const existing = (await this.readEntities(operation.entityType, [operation.entityID]))[0];

    if (operation.kind === "delete") {
      const events = await this.hooks.apply({ entityType: operation.entityType, entityID: operation.entityID, op: "delete" });
      if (existing) {
        const siblings = await this.readContainer(this.container(existing));
        events.push(...await this.publishOrder(siblings, new Map(siblings.map((entity) => [entity.entityID, entity]))));
      }
      return { events, outcome: { operationIndex, status: "applied" } };
    }

    if (operation.kind === "patch") {
      if (!existing) return { events: [], outcome: { operationIndex, status: "rejected", reason: "missing" } };
      const next: Entity = existing.entityType === "space" && operation.entityType === "space"
        ? { ...existing, data: { ...existing.data, ...operation.fields } }
        : existing.entityType === "tab" && operation.entityType === "tab"
          ? { ...existing, data: { ...existing.data, ...operation.fields } } : existing;
      return { events: await this.publishEntity(next, existing), outcome: { operationIndex, status: "applied" } };
    }

    if (existing) return {
      events: await this.currentEvents([existing]), outcome: { operationIndex, status: "rejected", reason: "entity_exists" }
    };
    const entity: Entity = operation.entityType === "space"
      ? { entityType: "space", entityID: operation.entityID, data: { ...operation.data, rank: 0 } }
      : { entityType: "tab", entityID: operation.entityID, data: { ...operation.data, rank: 0 } };
    const destination = this.container(entity);
    const targetFailure = await this.validateDestination(destination);
    if (targetFailure) return { events: targetFailure.events, outcome: { operationIndex, status: "rejected", reason: targetFailure.reason } };
    const siblings = await this.readContainer(destination);
    const ordered = this.insert(siblings, [entity], operation);
    return {
      events: await this.publishOrder(ordered, new Map(siblings.map((entity) => [entity.entityID, entity]))),
      outcome: { operationIndex, status: "applied" }
    };
  }

  private async move(operation: Extract<SyncOperation, { kind: "move" }>, operationIndex: number): Promise<{ events: OperationEvent[]; outcome: OperationOutcome }> {
    const found = await this.readEntities(operation.entityType, operation.entityIDs);
    const foundByID = new Map(found.map((entity) => [entity.entityID, entity]));
    const survivors = operation.entityIDs.flatMap((id) => foundByID.has(id) ? [foundByID.get(id)!] : []);
    const events: OperationEvent[] = [];
    for (const id of operation.entityIDs.filter((id) => !foundByID.has(id))) {
      const deleted = await this.hooks.tombstone(operation.entityType, id);
      if (deleted) events.push(deleted);
    }
    const destination: Container = operation.entityType === "space" ? { entityType: "space" }
      : { entityType: "tab", ...operation.destination };
    const targetFailure = await this.validateDestination(destination);
    if (targetFailure) return {
      events: [...events, ...targetFailure.events, ...await this.currentEvents(survivors)],
      outcome: { operationIndex, status: "rejected", reason: targetFailure.reason }
    };
    if (!survivors.length) return {
      events, outcome: events.length ? { operationIndex, status: "deleted" }
        : { operationIndex, status: "rejected", reason: "missing" }
    };

    const movedIDs = new Set(survivors.map((entity) => entity.entityID));
    const sourceContainers = new Map(survivors.map((entity) => {
      const container = this.container(entity);
      return [this.containerKey(container), container];
    }));
    const targetRows = await this.readContainer(destination);
    const targetOriginals = new Map([...targetRows, ...survivors].map((entity) => [entity.entityID, entity]));
    const moved = survivors.map((entity): Entity => {
      if (entity.entityType !== "tab" || destination.entityType !== "tab") return entity;
      const pinnedURLString = destination.placement !== "spacePinned" ? null
        : entity.data.placement === "spacePinned" ? entity.data.pinnedURLString ?? null : entity.data.urlString;
      return { ...entity, data: { ...entity.data, spaceID: destination.spaceID, placement: destination.placement, pinnedURLString } };
    });
    for (const [key, source] of sourceContainers) {
      if (key === this.containerKey(destination)) continue;
      const originals = await this.readContainer(source);
      events.push(...await this.publishOrder(originals.filter((entity) => !movedIDs.has(entity.entityID)),
        new Map(originals.map((entity) => [entity.entityID, entity]))));
    }
    const ordered = this.insert(targetRows.filter((entity) => !movedIDs.has(entity.entityID)), moved, operation);
    events.push(...await this.publishOrder(ordered, targetOriginals));
    // Even a no-op move acknowledges the current authoritative state, allowing
    // a client to remove its optimistic overlay without waiting for another pull.
    events.push(...await this.currentEvents(survivors));
    return { events, outcome: { operationIndex, status: "applied" } };
  }

  private insert(siblings: Entity[], group: Entity[], anchors: Anchors): Entity[] {
    const before = anchors.beforeID == null ? -1 : siblings.findIndex((entity) => entity.entityID === anchors.beforeID);
    const after = anchors.afterID == null ? -1 : siblings.findIndex((entity) => entity.entityID === anchors.afterID);
    const index = before >= 0 ? before : after >= 0 ? after + 1 : siblings.length;
    return [...siblings.slice(0, index), ...group, ...siblings.slice(index)];
  }

  private async validateDestination(container: Container): Promise<{ reason: string; events: OperationEvent[] } | undefined> {
    // Global Favorites do not depend on their historical space's lifetime.
    if (container.entityType === "space" || container.placement === "app") return undefined;
    const deleted = await this.hooks.tombstone("space", container.spaceID);
    if (deleted) return { reason: "target_deleted", events: [deleted] };
    if (!(await this.readEntities("space", [container.spaceID])).length) return { reason: "target_missing", events: [] };
    return undefined;
  }

  private async publishOrder(ordered: Entity[], originals: Map<string, Entity>): Promise<OperationEvent[]> {
    const events: OperationEvent[] = [];
    for (const [rank, entity] of ordered.entries()) {
      const updated = { ...entity, data: { ...entity.data, rank } } as Entity;
      const previous = originals.get(entity.entityID);
      if (previous && JSON.stringify(previous.data) === JSON.stringify(updated.data)) continue;
      events.push(...await this.publishEntity(updated));
    }
    return events;
  }

  private async publishEntity(entity: Entity, previous?: Entity): Promise<OperationEvent[]> {
    if (previous && JSON.stringify(previous.data) === JSON.stringify(entity.data)) return this.currentEvents([entity]);
    const change: SyncChange = entity.entityType === "space"
      ? { entityType: "space", entityID: entity.entityID, op: "upsert", data: entity.data }
      : { entityType: "tab", entityID: entity.entityID, op: "upsert", data: entity.data };
    return this.hooks.apply(change);
  }

  private async currentEvents(entities: Entity[]): Promise<OperationEvent[]> {
    const events: OperationEvent[] = [];
    for (const entity of entities) {
      const current = await this.hooks.currentEvent(entity.entityType, entity.entityID);
      if (current) events.push(current);
    }
    return events;
  }

  private container(entity: Entity): Container {
    return entity.entityType === "space" ? { entityType: "space" }
      : { entityType: "tab", spaceID: entity.data.spaceID, placement: entity.data.placement };
  }

  private containerKey(container: Container): string {
    return container.entityType === "space" ? "spaces"
      : JSON.stringify([container.placement, container.placement === "app" ? null : container.spaceID]);
  }

  private async readEntities(type: EntityType, ids: string[]): Promise<Entity[]> {
    const result = await this.client.query(
      `SELECT * FROM ${type === "space" ? "spaces" : "tabs"} WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL`,
      [this.userID, ids]
    );
    return result.rows.map((row) => this.entity(type, row));
  }

  private async readContainer(container: Container): Promise<Entity[]> {
    const params: unknown[] = [this.userID];
    let predicate = "";
    if (container.entityType === "tab") {
      params.push(container.placement);
      predicate = " AND placement = $2";
      if (container.placement !== "app") { params.push(container.spaceID); predicate += " AND space_id = $3"; }
    }
    const result = await this.client.query(
      `SELECT * FROM ${container.entityType === "space" ? "spaces" : "tabs"} WHERE user_id = $1 AND deleted_at IS NULL${predicate} ORDER BY rank, id`, params
    );
    return result.rows.map((row) => this.entity(container.entityType, row));
  }

  private entity(type: EntityType, row: pg.QueryResultRow): Entity {
    if (type === "space") return { entityType: "space", entityID: row.id as string, data: {
      title: row.title as string, systemImageName: row.system_image_name as string, rank: row.rank as number,
      isPinnedSectionCollapsed: row.is_pinned_section_collapsed as boolean, selectedTabID: row.selected_tab_id as string | null
    } };
    return { entityType: "tab", entityID: row.id as string, data: {
      spaceID: row.space_id as string, placement: row.placement as TabPayload["placement"], rank: row.rank as number,
      urlString: row.url_string as string, pinnedURLString: row.pinned_url_string as string | null,
      title: row.title as string | null, userTitleOverride: row.user_title_override as string | null,
      faviconURLString: row.favicon_url_string as string | null,
      lastActivityAt: row.last_activity_at instanceof Date ? row.last_activity_at.toISOString() : null
    } };
  }
}
