import { ConflictException, ForbiddenException, Inject, Injectable } from "@nestjs/common";
import { createHash } from "node:crypto";
import type pg from "pg";
import { AuthService } from "./auth.service.js";
import { DatabaseService } from "./database.service.js";
import type {
  AuthAppleRequest,
  RegisterDeviceRequest,
  SyncChange,
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

type SerializedSyncEvent = {
  serverSeq: number;
  deviceID: string | null;
  entityType: "space" | "tab";
  entityID: string;
  op: "upsert" | "delete";
  data: unknown;
  createdAt: string;
};

type QueryFunction = (text: string, params?: unknown[]) => Promise<Pick<pg.QueryResult, "rowCount">>;
type SyncResponse = {
  cursor: number;
  events: SerializedSyncEvent[];
  protocolVersion?: 2;
  mutationID?: string;
};

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
      const digest = body.mutationID ? createHash("sha256")
        .update(JSON.stringify(canonicalValue({ protocolVersion: body.protocolVersion, changes: body.changes })))
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

      const events: SerializedSyncEvent[] = [];
      // Snapshot diffs list deleted spaces before surviving tabs. Apply moves
      // first so deleting the old space does not also delete a moved-out tab.
      // Explicit deletes still dominate every upsert of the same ID in a batch.
      const orderedChanges = [
        ...body.changes.filter((change) => change.op === "upsert"),
        ...body.changes.filter((change) => change.op === "delete")
      ];
      for (const change of orderedChanges) {
        events.push(...await this.applyChange(client, userID, body.deviceID, change));
      }

      await client.query("UPDATE devices SET last_seen_at = now() WHERE id = $1", [body.deviceID]);
      const cursorResult = await client.query(
        "SELECT COALESCE(MAX(server_seq), 0) AS cursor FROM sync_events WHERE user_id = $1", [userID]
      );
      // An acknowledgement is not a pull: events may include old authoritative
      // deletes. Clients must advance their pull cursor only after reading pull.
      const response: SyncResponse = {
        cursor: Number(cursorResult.rows[0].cursor),
        events: events.sort((a, b) => a.serverSeq - b.serverSeq),
        ...(body.mutationID ? { protocolVersion: 2 as const, mutationID: body.mutationID } : {})
      };
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
    await this.assertDeviceBelongsToUser((text, params) => this.database.query(text, params), userID, body.deviceID);

    const result = await this.database.query(
      `
        SELECT server_seq, device_id, entity_type, entity_id, op, payload, created_at
        FROM sync_events
        WHERE user_id = $1 AND server_seq > $2
        ORDER BY server_seq ASC
        LIMIT $3
      `,
      [userID, body.cursor, body.limit]
    );

    const events = result.rows.map((row) => this.serializeSyncEvent(row));
    const cursor = events.length > 0 ? events[events.length - 1].serverSeq : body.cursor;
    await this.database.query("UPDATE devices SET last_seen_at = now() WHERE id = $1", [body.deviceID]);

    return { protocolVersion: 2, cursor, events };
  }

  private async assertDeviceBelongsToUser(query: QueryFunction, userID: string, deviceID: string): Promise<void> {
    const result = await query("SELECT 1 FROM devices WHERE id = $1 AND user_id = $2", [deviceID, userID]);
    if (!result.rowCount) {
      throw new ForbiddenException("Device does not belong to user");
    }
  }

  private async applyChange(
    client: pg.PoolClient,
    userID: string,
    deviceID: string,
    change: SyncChange
  ): Promise<SerializedSyncEvent[]> {
    if (change.op === "delete") {
      return this.deleteEntity(client, userID, deviceID, change.entityType, change.entityID);
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

    if (!change.data) {
      throw new Error("Tab upsert requires data");
    }

    // Favorites are global. Their historical space ID is metadata, not a
    // lifetime owner; an explicit tab tombstone was already checked above.
    if (change.data.placement !== "app" && await this.tombstoneEvent(client, userID, "space", change.data.spaceID)) {
      // A tab moved out before the space deletion survives. A stale snapshot
      // must neither move it back into the deleted space nor delete it there.
      const survivor = await client.query(
        "SELECT 1 FROM tabs WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL AND space_id <> $3",
        [userID, change.entityID, change.data.spaceID]
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
    if (change.data.placement === "spacePinned") {
      if (change.data.pinnedURLString !== undefined) {
        pinnedURLString = change.data.pinnedURLString;
      } else {
        const existing = await client.query(
          "SELECT pinned_url_string FROM tabs WHERE user_id = $1 AND id = $2",
          [userID, change.entityID]
        );
        pinnedURLString = existing.rows.length ? existing.rows[0].pinned_url_string as string | null : change.data.urlString;
      }
    }

    await client.query(
      `
        INSERT INTO tabs (
          id, user_id, space_id, placement, rank, url_string, title, user_title_override,
          favicon_url_string, last_activity_at, deleted_at, updated_at, revision, updated_by_device_id, pinned_url_string
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, now(), 1, $11, $12)
        ON CONFLICT (user_id, id)
        DO UPDATE SET
          space_id = EXCLUDED.space_id,
          placement = EXCLUDED.placement,
          rank = EXCLUDED.rank,
          url_string = EXCLUDED.url_string,
          pinned_url_string = EXCLUDED.pinned_url_string,
          title = EXCLUDED.title,
          user_title_override = EXCLUDED.user_title_override,
          favicon_url_string = EXCLUDED.favicon_url_string,
          last_activity_at = EXCLUDED.last_activity_at,
          deleted_at = NULL,
          updated_at = now(),
          revision = tabs.revision + 1,
          updated_by_device_id = EXCLUDED.updated_by_device_id
      `,
      [
        change.entityID,
        userID,
        change.data.spaceID,
        change.data.placement,
        change.data.rank,
        change.data.urlString,
        change.data.title ?? null,
        change.data.userTitleOverride ?? null,
        change.data.faviconURLString ?? null,
        change.data.lastActivityAt ?? null,
        deviceID,
        pinnedURLString
      ]
    );

    return [await this.insertSyncEvent(client, userID, deviceID, "tab", change.entityID, "upsert", {
      id: change.entityID,
      ...change.data,
      pinnedURLString
    })];
  }

  private async tombstoneEvent(
    client: pg.PoolClient, userID: string, entityType: "space" | "tab", entityID: string
  ): Promise<SerializedSyncEvent | undefined> {
    const result = await client.query(
      `SELECT e.server_seq, e.device_id, e.entity_type, e.entity_id, e.op, e.payload, e.created_at
       FROM sync_tombstones t JOIN sync_events e ON e.server_seq = t.server_seq
       WHERE t.user_id = $1 AND t.entity_type = $2 AND t.entity_id = $3`,
      [userID, entityType, entityID]
    );
    return result.rows[0] ? this.serializeSyncEvent(result.rows[0]) : undefined;
  }

  private async deleteEntity(
    client: pg.PoolClient, userID: string, deviceID: string,
    entityType: "space" | "tab", entityID: string
  ): Promise<SerializedSyncEvent[]> {
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
    }
    const previous = await this.tombstoneEvent(client, userID, entityType, entityID);
    if (previous) return [...events, previous];

    // Table name is chosen from the validated entity type, never user SQL.
    const table = entityType === "space" ? "spaces" : "tabs";
    await client.query(
      `UPDATE ${table} SET deleted_at = now(), updated_at = now(),
       revision = revision + 1, updated_by_device_id = $3 WHERE user_id = $1 AND id = $2`,
      [userID, entityID, deviceID]
    );
    const event = await this.insertSyncEvent(client, userID, deviceID, entityType, entityID, "delete", { id: entityID });
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
    entityType: "space" | "tab",
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
      entityType: row.entity_type as "space" | "tab",
      entityID: row.entity_id as string,
      op: row.op as "upsert" | "delete",
      data: row.payload as unknown,
      createdAt: (row.created_at as Date).toISOString()
    };
  }
}
