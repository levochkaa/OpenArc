import { ConflictException, ForbiddenException, Inject, Injectable } from "@nestjs/common";
import { createHash } from "node:crypto";
import type pg from "pg";
import { AuthService } from "./auth.service.js";
import { DatabaseService } from "./database.service.js";
import { SyncOperationExecutor, type OperationEvent, type OperationOutcome } from "./sync-operations.js";
import { SyncFolderOperationExecutor, type FolderOperationEvent } from "./sync-folder-operations.js";
import type {
  AuthAppleRequest,
  RegisterDeviceRequest,
  SyncChange,
  SyncChangeV4,
  SyncExpiryOperation,
  SyncOperation,
  SyncPullRequest,
  SyncPushRequest
} from "./schemas.js";

type SerializedDevice = {
  id: string;
  name: string;
  platform: string;
  publicKey?: string;
  lastSeenAt: string;
};

type SerializedSyncEvent = FolderOperationEvent;
type EntityType = SerializedSyncEvent["entityType"];

type QueryFunction = (text: string, params?: unknown[]) => Promise<Pick<pg.QueryResult, "rowCount">>;
type SyncResponse = {
  cursor: number;
  events: SerializedSyncEvent[];
  protocolVersion?: 2 | 3 | 4 | 5;
  mutationID?: string;
  supportedPushVersions?: number[];
  outcomes?: OperationOutcome[];
};

type AutoArchivePayload = {
  archivedAt: string;
  sourceServerSeq: number;
  tab: Record<string, unknown>;
};

const expiryResponseLimit = 4 * 1024 * 1024;

class ExpiryResponseBudget {
  private bytes = 2; // Array brackets.
  private readonly sequences = new Set<number>();
  // At most 100 small outcomes plus the response envelope fit well below this.
  private readonly eventLimit = expiryResponseLimit - 64 * 1024;

  canDelete(entityID: string, deviceID: string, payload: unknown): boolean {
    const bytes = Buffer.byteLength(JSON.stringify({ entityType: "tab", entityID, deviceID, op: "delete", data: payload }), "utf8");
    // Include the actual unbounded identity/payload strings, then reserve fixed
    // serverSeq/createdAt metadata before the irreversible operation in this tx.
    return this.bytes + bytes + 512 + 1 <= this.eventLimit;
  }

  include(events: SerializedSyncEvent[]): boolean {
    const unseen = [...new Map(events.filter((event) => !this.sequences.has(event.serverSeq))
      .map((event) => [event.serverSeq, event])).values()];
    const bytes = unseen.reduce((total, event) => total + Buffer.byteLength(JSON.stringify(event), "utf8") + 1, 0);
    if (this.bytes + bytes > this.eventLimit) return false;
    this.bytes += bytes;
    for (const event of unseen) this.sequences.add(event.serverSeq);
    return true;
  }
}

function canonicalValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).filter(([, value]) => value !== undefined)
      .sort(([first], [second]) => first < second ? -1 : first > second ? 1 : 0)
      .map(([key, value]) => [key, canonicalValue(value)]));
  }
  return value;
}

@Injectable()
export class SyncService {
  constructor(
    @Inject(AuthService)
    private readonly auth: AuthService,
    @Inject(DatabaseService)
    private readonly database: DatabaseService
  ) {}

  async authenticateWithApple(body: AuthAppleRequest): Promise<{
    accessToken: string;
    tokenType: "Bearer";
    expiresIn: number;
    user: { id: string; email: string | null };
    device: SerializedDevice;
  }> {
    const identity = await this.auth.verifyAppleIdentityToken(body.identityToken);
    const client = await this.database.connect();

    try {
      await client.query("BEGIN");
      const user = await client.query(
        `
          INSERT INTO app_users (apple_subject, email, updated_at)
          VALUES ($1, $2, now())
          ON CONFLICT (apple_subject)
          DO UPDATE SET email = COALESCE(EXCLUDED.email, app_users.email), updated_at = now()
          RETURNING id, email
        `,
        [identity.appleSubject, identity.email ?? null]
      );

      const userID = user.rows[0].id as string;
      const device = await client.query(
        `
          INSERT INTO devices (user_id, name, platform)
          VALUES ($1, $2, $3)
          RETURNING id, name, platform, last_seen_at
        `,
        [userID, body.deviceName, body.devicePlatform]
      );
      await client.query("COMMIT");

      return {
        accessToken: await this.auth.issueAccessToken(userID),
        tokenType: "Bearer",
        expiresIn: 60 * 60 * 24 * 30,
        user: {
          id: userID,
          email: user.rows[0].email as string | null
        },
        device: this.serializeDevice(device.rows[0])
      };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async registerDevice(userID: string, body: RegisterDeviceRequest): Promise<{ device: SerializedDevice }> {
    const result = await this.database.query(
      `
        INSERT INTO devices (user_id, name, platform, public_key)
        VALUES ($1, $2, $3, $4)
        RETURNING id, name, platform, public_key, last_seen_at, created_at
      `,
      [userID, body.name, body.platform, body.publicKey ?? null]
    );

    return { device: this.serializeDevice(result.rows[0]) };
  }

  async push(userID: string, body: SyncPushRequest): Promise<SyncResponse> {
    const client = await this.database.connect();

    try {
      await client.query("BEGIN");
      await this.assertDeviceBelongsToUser((text, params) => client.query(text, params), userID, body.deviceID);
      // Sequence allocation must follow commit order within an account. Without
      // this lock a later transaction can commit first and a pull skips the
      // earlier uncommitted events forever. It also serializes tombstone checks.
      await client.query("SELECT id FROM app_users WHERE id = $1 FOR UPDATE", [userID]);

      // Parsed payloads have defaults applied and unknown fields stripped. Sort
      // object keys, preserve change order, and exclude the replaceable device ID.
      const payload = body.protocolVersion === 3 || body.protocolVersion === 4 || body.protocolVersion === 5
        ? { protocolVersion: body.protocolVersion, operations: body.operations }
        : { protocolVersion: body.protocolVersion, changes: body.changes };
      const digest = body.mutationID ? createHash("sha256")
        .update(JSON.stringify(canonicalValue(payload)))
        .digest("hex") : undefined;
      if (body.mutationID) {
        const receipt = await client.query(
          "SELECT payload_digest, response FROM sync_mutation_receipts WHERE user_id = $1 AND mutation_id = $2",
          [userID, body.mutationID]
        );
        if (receipt.rowCount) {
          if (receipt.rows[0].payload_digest !== digest) {
            throw new ConflictException("Mutation ID was already used for different content");
          }
          await client.query("COMMIT");
          return receipt.rows[0].response as SyncResponse;
        }
      }

      // Legacy writers cannot create folders. Snapshot only Space IDs once
      // under the account lock, then invalidate after a Space cascade.
      const legacyFolderSpaces = new Set<string>();
      if (body.protocolVersion !== 4 && body.protocolVersion !== 5) {
        const folders = await client.query(
          "SELECT DISTINCT space_id FROM folders WHERE user_id = $1 AND deleted_at IS NULL", [userID]
        );
        for (const row of folders.rows) legacyFolderSpaces.add(row.space_id as string);
      }
      const events: SerializedSyncEvent[] = [];
      const outcomes: OperationOutcome[] = [];
      if (body.protocolVersion === 5) {
        const budget = new ExpiryResponseBudget();
        for (const [index, operation] of body.operations.entries()) {
          const result = await this.expireTab(client, userID, body.deviceID, operation, index, budget);
          events.push(...result.events);
          outcomes.push(result.outcome);
        }
      } else if (body.protocolVersion === 4) {
        const executor = new SyncFolderOperationExecutor(client, userID, {
          apply: (change) => this.applyChange(client, userID, body.deviceID, change, 4),
          tombstone: (type, id) => this.tombstoneEvent(client, userID, type, id),
          currentEvent: (type, id) => this.currentEvent(client, userID, type, id)
        });
        for (const [index, operation] of body.operations.entries()) {
          const result = await executor.apply(operation, index);
          events.push(...result.events);
          outcomes.push(result.outcome);
        }
      } else if (body.protocolVersion === 3) {
        const executor = new SyncOperationExecutor(client, userID, {
          apply: async (change) => this.legacyEvents(await this.applyChange(
            client, userID, body.deviceID, change, 3, legacyFolderSpaces
          )),
          tombstone: async (type, id) => {
            const event = await this.tombstoneEvent(client, userID, type, id);
            return event ? this.legacyEvents([event])[0] : undefined;
          },
          currentEvent: async (type, id) => {
            const event = await this.currentEvent(client, userID, type, id);
            return event ? this.legacyEvents([event])[0] : undefined;
          }
        });
        for (const [index, operation] of body.operations.entries()) {
          if (this.legacyOperationRequiresUpgrade(operation, legacyFolderSpaces)) {
            const ids = operation.kind === "move" ? operation.entityIDs
              : "entityID" in operation ? [operation.entityID] : [];
            for (const id of ids) {
              const current = await this.currentEvent(client, userID, "tab", id);
              if (current) events.push(current);
            }
            outcomes.push({ operationIndex: index, status: "rejected", reason: "upgrade_required" });
            continue;
          }
          const result = await executor.apply(operation, index);
          events.push(...result.events);
          outcomes.push(result.outcome);
        }
      } else {
        // Legacy snapshot diffs put deleted spaces before surviving moved tabs.
        const orderedChanges = [
          ...body.changes.filter((change) => change.op === "upsert"),
          ...body.changes.filter((change) => change.op === "delete")
        ];
        for (const change of orderedChanges) {
          events.push(...await this.applyChange(client, userID, body.deviceID, change, 2, legacyFolderSpaces));
        }
      }

      await client.query("UPDATE devices SET last_seen_at = now() WHERE id = $1", [body.deviceID]);
      const cursorResult = await client.query(
        "SELECT COALESCE(MAX(server_seq), 0) AS cursor FROM sync_events WHERE user_id = $1", [userID]
      );
      // An acknowledgement is not a pull: events may include old authoritative
      // deletes. Clients must advance their pull cursor only after reading pull.
      const visibleEvents = body.protocolVersion === 4 || body.protocolVersion === 5
        ? events.map((event) => this.v4Event(event)) : this.legacyEvents(events);
      const response: SyncResponse = {
        cursor: Number(cursorResult.rows[0].cursor),
        events: (body.protocolVersion === 3 || body.protocolVersion === 4 || body.protocolVersion === 5
          ? [...new Map(visibleEvents.map((event) => [event.serverSeq, event])).values()] : visibleEvents)
          .sort((a, b) => a.serverSeq - b.serverSeq),
        ...(body.mutationID ? { protocolVersion: body.protocolVersion, mutationID: body.mutationID } : {}),
        ...(body.protocolVersion === 3 || body.protocolVersion === 4 || body.protocolVersion === 5 ? { outcomes } : {})
      };
      if (body.protocolVersion === 5 && Buffer.byteLength(JSON.stringify(response), "utf8") > expiryResponseLimit) {
        throw new Error("Expiry response exceeded its reserved budget");
      }
      if (body.mutationID) {
        await client.query(
          "INSERT INTO sync_mutation_receipts (user_id, mutation_id, payload_digest, response) VALUES ($1, $2, $3, $4)",
          [userID, body.mutationID, digest, JSON.stringify(response)]
        );
      }
      await client.query("COMMIT");
      return response;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async pull(userID: string, body: SyncPullRequest): Promise<SyncResponse> {
    const client = await this.database.connect();
    try {
      await client.query("BEGIN");
      const device = await client.query(
        "SELECT folder_sync_enabled, expiry_sync_enabled FROM devices WHERE id = $1 AND user_id = $2 FOR UPDATE", [body.deviceID, userID]
      );
      if (!device.rowCount) throw new ForbiddenException("Device does not belong to user");
      const isV4 = body.protocolVersion === 4;
      const isV5 = body.protocolVersion === 5;
      const includesFolders = isV4 || isV5;
      if (isV5 && !device.rows[0].expiry_sync_enabled && body.cursor !== 0) {
        throw new ConflictException("Protocol 5 bootstrap requires cursor 0");
      }
      if (isV4 && !device.rows[0].folder_sync_enabled && body.cursor !== 0) {
        throw new ConflictException("Protocol 4 bootstrap requires cursor 0");
      }
      const result = await client.query(
        `
          SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
          FROM sync_events
          WHERE user_id = $1 AND server_seq > $2 AND ($4 OR entity_type <> 'folder')
          ORDER BY server_seq ASC
          LIMIT $3
        `,
        [userID, body.cursor, body.limit, includesFolders]
      );

      const rawEvents = result.rows.map((row) => this.serializeSyncEvent(row));
      const events = includesFolders ? rawEvents.map((event) => this.v4Event(event)) : this.legacyEvents(rawEvents);
      const cursor = events.length > 0 ? events[events.length - 1].serverSeq : body.cursor;
      await client.query("UPDATE devices SET last_seen_at = now(), folder_sync_enabled = $2, expiry_sync_enabled = $3 WHERE id = $1",
        [body.deviceID, includesFolders, isV5]);
      await client.query("COMMIT");
      return { protocolVersion: isV5 ? 5 : isV4 ? 4 : 2, supportedPushVersions: [2, 3, 4, 5], cursor, events };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  private async assertDeviceBelongsToUser(query: QueryFunction, userID: string, deviceID: string): Promise<void> {
    const result = await query("SELECT 1 FROM devices WHERE id = $1 AND user_id = $2", [deviceID, userID]);
    if (!result.rowCount) {
      throw new ForbiddenException("Device does not belong to user");
    }
  }

  private legacyOperationRequiresUpgrade(operation: SyncOperation, folderSpaces: ReadonlySet<string>): boolean {
    if (operation.entityType !== "tab") return false;
    const destination = operation.kind === "create" ? operation.data
      : operation.kind === "move" ? operation.destination : undefined;
    return destination?.placement === "spacePinned" && folderSpaces.has(destination.spaceID);
  }

  private async currentEvent(client: pg.PoolClient, userID: string, type: EntityType, id: string): Promise<SerializedSyncEvent | undefined> {
    const result = await client.query(
      `SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
       FROM sync_events WHERE user_id = $1 AND entity_type = $2 AND entity_id = $3
       ORDER BY server_seq DESC LIMIT 1`, [userID, type, id]
    );
    return result.rows[0] ? this.serializeSyncEvent(result.rows[0]) : undefined;
  }

  private legacyEvents(events: SerializedSyncEvent[]): OperationEvent[] {
    return events.flatMap((event): OperationEvent[] => {
      if (event.entityType === "folder") return [];
      const result: OperationEvent = { ...event, entityType: event.entityType };
      if (event.entityType === "tab" && event.op === "upsert" && event.data && typeof event.data === "object") {
        const data = { ...event.data } as Record<string, unknown>;
        delete data.pinnedFolderID;
        result.data = data;
      }
      return [result];
    });
  }

  private v4Event(event: SerializedSyncEvent): SerializedSyncEvent {
    if (event.entityType !== "tab" || event.op !== "upsert" || !event.data || typeof event.data !== "object") return event;
    const data = event.data as Record<string, unknown>;
    return { ...event, data: { ...data, pinnedFolderID: data.pinnedFolderID ?? null } };
  }

  private async applyChange(
    client: pg.PoolClient,
    userID: string,
    deviceID: string,
    change: SyncChange | SyncChangeV4,
    protocolVersion: 2 | 3 | 4 = 2,
    legacyFolderSpaces?: Set<string>
  ): Promise<SerializedSyncEvent[]> {
    if (change.op === "delete") {
      const events = await this.deleteEntity(client, userID, deviceID, change.entityType, change.entityID);
      if (change.entityType === "space") legacyFolderSpaces?.delete(change.entityID);
      return events;
    }

    const deleted = await this.tombstoneEvent(client, userID, change.entityType, change.entityID);
    if (deleted) return [deleted];

    if (change.entityType === "space") {
      if (!change.data) {
        throw new Error("Space upsert requires data");
      }

      await client.query(
        `
          INSERT INTO spaces (
            id, user_id, title, system_image_name, rank, is_pinned_section_collapsed,
            selected_tab_id, deleted_at, updated_at, revision, updated_by_device_id
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, now(), 1, $8)
          ON CONFLICT (user_id, id)
          DO UPDATE SET
            title = EXCLUDED.title,
            system_image_name = EXCLUDED.system_image_name,
            rank = EXCLUDED.rank,
            is_pinned_section_collapsed = EXCLUDED.is_pinned_section_collapsed,
            selected_tab_id = EXCLUDED.selected_tab_id,
            deleted_at = NULL,
            updated_at = now(),
            revision = spaces.revision + 1,
            updated_by_device_id = EXCLUDED.updated_by_device_id
        `,
        [
          change.entityID,
          userID,
          change.data.title,
          change.data.systemImageName,
          change.data.rank,
          change.data.isPinnedSectionCollapsed,
          change.data.selectedTabID ?? null,
          deviceID
        ]
      );
      return [await this.insertSyncEvent(client, userID, deviceID, "space", change.entityID, "upsert", {
        id: change.entityID,
        ...change.data
      })];
    }

    if (change.entityType === "folder") {
      if (!change.data) throw new Error("Folder upsert requires data");
      await client.query(
        `INSERT INTO folders (id, user_id, space_id, parent_folder_id, title, system_image_name, rank,
          deleted_at, updated_at, revision, updated_by_device_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, now(), 1, $8)
         ON CONFLICT (user_id, id) DO UPDATE SET space_id = EXCLUDED.space_id,
          parent_folder_id = EXCLUDED.parent_folder_id, title = EXCLUDED.title,
          system_image_name = EXCLUDED.system_image_name, rank = EXCLUDED.rank,
          deleted_at = NULL, updated_at = now(), revision = folders.revision + 1,
          updated_by_device_id = EXCLUDED.updated_by_device_id`,
        [change.entityID, userID, change.data.spaceID, change.data.parentFolderID, change.data.title,
          change.data.systemImageName ?? null, change.data.rank, deviceID]
      );
      return [await this.insertSyncEvent(client, userID, deviceID, "folder", change.entityID, "upsert", {
        id: change.entityID, ...change.data, systemImageName: change.data.systemImageName ?? null
      })];
    }

    if (!change.data) {
      throw new Error("Tab upsert requires data");
    }

    // V4's executor supplies canonical membership and home for every existing
    // row. Only a new create may omit home, which defaults to its current URL.
    const existingResult = protocolVersion === 4 ? undefined : await client.query(
      "SELECT space_id, placement, rank, pinned_url_string, pinned_folder_id FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL",
      [userID, change.entityID]
    );
    const existing = existingResult?.rows[0];
    const data = { ...change.data };
    if (protocolVersion !== 4) {
      const sourceHasFolders = existing?.placement === "spacePinned"
        && legacyFolderSpaces?.has(existing.space_id as string);
      const targetHasFolders = data.placement === "spacePinned"
        && legacyFolderSpaces?.has(data.spaceID);
      if (protocolVersion === 2 && existing && (sourceHasFolders || targetHasFolders)) {
        // A v2 snapshot has no structural intent. Keep the current tree while
        // accepting page metadata, even if a stale snapshot claims another list.
        data.spaceID = existing.space_id as string;
        data.placement = existing.placement as typeof data.placement;
        data.rank = existing.rank as number;
        data.pinnedURLString = existing.pinned_url_string as string | null;
      } else if (existing && sourceHasFolders && data.placement === "spacePinned" && data.spaceID === existing.space_id) {
        // v3 normalizes the entire flattened pinned list after metadata/deletes.
        // Preserve mixed folder/tab sibling ranks for those incidental writes.
        data.rank = existing.rank as number;
      } else if (!existing && targetHasFolders) {
        const maximum = await client.query(
          `SELECT COALESCE(MAX(rank), -1) + 1 AS rank FROM (
            SELECT rank FROM tabs WHERE user_id = $1 AND space_id = $2 AND placement = 'spacePinned'
              AND pinned_folder_id IS NULL AND deleted_at IS NULL
            UNION ALL SELECT rank FROM folders WHERE user_id = $1 AND space_id = $2
              AND parent_folder_id IS NULL AND deleted_at IS NULL
           ) siblings`, [userID, data.spaceID]
        );
        data.rank = Number(maximum.rows[0].rank);
      }
    }

    const pinnedFolderID = data.placement !== "spacePinned" ? null
      : protocolVersion === 4 && "pinnedFolderID" in data ? data.pinnedFolderID
        : existing?.space_id === data.spaceID && existing?.placement === "spacePinned"
          ? existing.pinned_folder_id as string | null : null;

    // Favorites are global. Their historical space ID is metadata, not a
    // lifetime owner; an explicit tab tombstone was already checked above.
    if (data.placement !== "app" && await this.tombstoneEvent(client, userID, "space", data.spaceID)) {
      // A tab moved out before the space deletion survives. A stale snapshot
      // must neither move it back into the deleted space nor delete it there.
      const survivor = await client.query(
        "SELECT 1 FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL AND (space_id <> $3 OR placement = 'app')",
        [userID, change.entityID, data.spaceID]
      );
      if (survivor.rowCount) {
        const latest = await client.query(
          `SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
           FROM sync_events WHERE user_id = $1 AND entity_type = 'tab' AND entity_id = $2
           ORDER BY server_seq DESC LIMIT 1`, [userID, change.entityID]
        );
        return latest.rows.map((row) => this.serializeSyncEvent(row));
      }
      return this.deleteEntity(client, userID, deviceID, "tab", change.entityID);
    }

    let pinnedURLString: string | null = null;
    if (data.placement === "spacePinned") {
      if (data.pinnedURLString !== undefined) {
        pinnedURLString = data.pinnedURLString;
      } else {
        pinnedURLString = existing ? existing.pinned_url_string as string | null : data.urlString;
      }
    }

    const saved = await client.query<{ last_activity_at: string | null }>(
      `
        INSERT INTO tabs (
          id, user_id, space_id, placement, rank, url_string, title, user_title_override,
          favicon_url_string, last_activity_at, deleted_at, updated_at, revision, updated_by_device_id, pinned_url_string, pinned_folder_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, now(), 1, $11, $12, $13)
        ON CONFLICT (user_id, id)
        DO UPDATE SET
          space_id = EXCLUDED.space_id,
          placement = EXCLUDED.placement,
          rank = EXCLUDED.rank,
          url_string = EXCLUDED.url_string,
          pinned_url_string = EXCLUDED.pinned_url_string,
          pinned_folder_id = EXCLUDED.pinned_folder_id,
          title = EXCLUDED.title,
          user_title_override = EXCLUDED.user_title_override,
          favicon_url_string = EXCLUDED.favicon_url_string,
          last_activity_at = GREATEST(tabs.last_activity_at, EXCLUDED.last_activity_at),
          deleted_at = NULL,
          updated_at = now(),
          revision = tabs.revision + 1,
          updated_by_device_id = EXCLUDED.updated_by_device_id
        RETURNING to_char(last_activity_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS last_activity_at
      `,
      [
        change.entityID,
        userID,
        data.spaceID,
        data.placement,
        data.rank,
        data.urlString,
        data.title ?? null,
        data.userTitleOverride ?? null,
        data.faviconURLString ?? null,
        data.lastActivityAt ?? null,
        deviceID,
        pinnedURLString,
        pinnedFolderID
      ]
    );

    return [await this.insertSyncEvent(client, userID, deviceID, "tab", change.entityID, "upsert", {
      id: change.entityID,
      ...data,
      // Encode the committed maximum without passing through JavaScript Date,
      // whose millisecond precision would discard PostgreSQL microseconds.
      lastActivityAt: saved.rows[0].last_activity_at,
      pinnedURLString,
      pinnedFolderID
    })];
  }

  private async tombstoneEvent(
    client: pg.PoolClient, userID: string, entityType: EntityType, entityID: string
  ): Promise<SerializedSyncEvent | undefined> {
    const result = await client.query(
      `SELECT e.server_seq, e.device_id, e.entity_type, e.entity_id, e.op, e.payload, e.created_at
       FROM sync_tombstones t JOIN sync_events e ON e.server_seq = t.server_seq
       WHERE t.user_id = $1 AND t.entity_type = $2 AND t.entity_id = $3`,
      [userID, entityType, entityID]
    );
    return result.rows[0] ? this.serializeSyncEvent(result.rows[0]) : undefined;
  }

  private async expireTab(
    client: pg.PoolClient, userID: string, deviceID: string, operation: SyncExpiryOperation, operationIndex: number,
    budget: ExpiryResponseBudget
  ): Promise<{ events: SerializedSyncEvent[]; outcome: OperationOutcome }> {
    const response = (events: SerializedSyncEvent[], status: OperationOutcome["status"], reason?: string) => {
      const canonical = events.map((event) => this.v4Event(event));
      return budget.include(canonical)
        ? { events: canonical, outcome: { operationIndex, status, ...(reason ? { reason } : {}) } }
        : { events: [], outcome: { operationIndex, status: "rejected" as const, reason: "response_limit" } };
    };
    const deleted = await this.tombstoneEvent(client, userID, "tab", operation.entityID);
    if (deleted) return response([deleted], "deleted");
    const current = await this.currentEvent(client, userID, "tab", operation.entityID);
    const rejected = (reason: string) => response(current ? [current] : [], "rejected", reason);
    // The account lock covers the observed sequence, eligibility, recovery data,
    // tombstone and receipt. Client wall clocks do not choose the cutoff.
    const result = await client.query<{
      placement: string; known_activity: boolean; expired: boolean | null; archived_at: string;
    }>(`SELECT placement, last_activity_at IS NOT NULL AND isfinite(last_activity_at) AS known_activity,
      last_activity_at <= now() - ($3::double precision * interval '1 second') AS expired,
      to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS archived_at
      FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL`,
    [userID, operation.entityID, operation.inactiveForSeconds]);
    const tab = result.rows[0];
    if (!tab) return rejected("missing");
    if (current?.op !== "upsert" || current.serverSeq !== operation.expectedServerSeq) return rejected("state_changed");
    if (tab.placement !== "temporary") return rejected("not_temporary");
    if (!tab.known_activity) return rejected("activity_unknown");
    if (!tab.expired) return rejected("not_expired");
    const data = this.v4Event(current).data;
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("Invalid canonical tab event");
    const autoArchive: AutoArchivePayload = {
      archivedAt: tab.archived_at, sourceServerSeq: current.serverSeq, tab: data as Record<string, unknown>
    };
    if (!budget.canDelete(operation.entityID, deviceID, { id: operation.entityID, autoArchive })) {
      return { events: [], outcome: { operationIndex, status: "rejected", reason: "response_limit" } };
    }
    // Rank gaps are valid. Renumbering peers here would invalidate another
    // candidate's observed sequence inside the same conditional expiry batch.
    const events = await this.deleteEntity(client, userID, deviceID, "tab", operation.entityID, autoArchive);
    if (!budget.include(events)) throw new Error("Expiry event exceeded its reserved budget");
    return { events, outcome: { operationIndex, status: "applied" } };
  }

  private async deleteEntity(
    client: pg.PoolClient, userID: string, deviceID: string,
    entityType: EntityType, entityID: string, autoArchive?: AutoArchivePayload
  ): Promise<SerializedSyncEvent[]> {
    if (autoArchive && entityType !== "tab") throw new Error("Only tab expiry can carry archive recovery data");
    const events: SerializedSyncEvent[] = [];
    if (entityType === "space") {
      // Include children in the event stream, even for clients that already
      // consumed the parent deletion before reconnecting with an old snapshot.
      const children = await client.query(
        "SELECT id FROM tabs WHERE user_id = $1 AND space_id = $2 AND placement <> 'app' AND deleted_at IS NULL ORDER BY id",
        [userID, entityID]
      );
      for (const child of children.rows) {
        events.push(...await this.deleteEntity(client, userID, deviceID, "tab", child.id as string));
      }
      const folders = await client.query(
        "SELECT id FROM folders WHERE user_id = $1 AND space_id = $2 AND deleted_at IS NULL ORDER BY id", [userID, entityID]
      );
      for (const folder of folders.rows) {
        events.push(...await this.deleteEntity(client, userID, deviceID, "folder", folder.id as string));
      }
    } else if (entityType === "folder") {
      const children = await client.query(
        "SELECT id FROM folders WHERE user_id = $1 AND parent_folder_id = $2 AND deleted_at IS NULL ORDER BY id", [userID, entityID]
      );
      for (const child of children.rows) {
        events.push(...await this.deleteEntity(client, userID, deviceID, "folder", child.id as string));
      }
      const tabs = await client.query(
        "SELECT id FROM tabs WHERE user_id = $1 AND pinned_folder_id = $2 AND deleted_at IS NULL ORDER BY id", [userID, entityID]
      );
      for (const tab of tabs.rows) {
        events.push(...await this.deleteEntity(client, userID, deviceID, "tab", tab.id as string));
      }
    }
    const previous = await this.tombstoneEvent(client, userID, entityType, entityID);
    if (previous) return [...events, previous];

    // Table name is chosen from the validated entity type, never user SQL.
    const table = entityType === "space" ? "spaces" : entityType === "folder" ? "folders" : "tabs";
    await client.query(
      `UPDATE ${table} SET deleted_at = now(), updated_at = now(),
       revision = revision + 1, updated_by_device_id = $3 WHERE user_id = $1 AND id = $2`,
      [userID, entityID, deviceID]
    );
    const event = await this.insertSyncEvent(client, userID, deviceID, entityType, entityID, "delete", {
      id: entityID, ...(autoArchive ? { autoArchive } : {})
    });
    await client.query(
      "INSERT INTO sync_tombstones (user_id, entity_type, entity_id, server_seq) VALUES ($1, $2, $3, $4)",
      [userID, entityType, entityID, event.serverSeq]
    );
    return [...events, event];
  }

  private async insertSyncEvent(
    client: pg.PoolClient,
    userID: string,
    deviceID: string,
    entityType: EntityType,
    entityID: string,
    op: "upsert" | "delete",
    payload: unknown
  ): Promise<SerializedSyncEvent> {
    const result = await client.query(
      `
        INSERT INTO sync_events (user_id, device_id, entity_type, entity_id, op, payload)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING server_seq, device_id, entity_type, entity_id, op, payload, created_at
      `,
      [userID, deviceID, entityType, entityID, op, JSON.stringify(payload)]
    );

    return this.serializeSyncEvent(result.rows[0]);
  }

  private serializeDevice(row: pg.QueryResultRow): SerializedDevice {
    return {
      id: row.id as string,
      name: row.name as string,
      platform: row.platform as string,
      publicKey: (row.public_key as string | null) ?? undefined,
      lastSeenAt: (row.last_seen_at as Date).toISOString()
    };
  }

  private serializeSyncEvent(row: pg.QueryResultRow): SerializedSyncEvent {
    return {
      serverSeq: Number(row.server_seq),
      deviceID: row.device_id as string | null,
      entityType: row.entity_type as EntityType,
      entityID: row.entity_id as string,
      op: row.op as "upsert" | "delete",
      data: row.payload as unknown,
      createdAt: (row.created_at as Date).toISOString()
    };
  }
}
