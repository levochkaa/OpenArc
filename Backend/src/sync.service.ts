import { ForbiddenException, Inject, Injectable } from "@nestjs/common";
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

  async push(userID: string, body: SyncPushRequest): Promise<{ cursor: number; events: SerializedSyncEvent[] }> {
    const client = await this.database.connect();

    try {
      await client.query("BEGIN");
      await this.assertDeviceBelongsToUser((text, params) => client.query(text, params), userID, body.deviceID);

      const events: SerializedSyncEvent[] = [];
      for (const change of body.changes) {
        events.push(await this.applyChange(client, userID, body.deviceID, change));
      }

      await client.query("UPDATE devices SET last_seen_at = now() WHERE id = $1", [body.deviceID]);
      await client.query("COMMIT");

      const cursor = events.length > 0 ? events[events.length - 1].serverSeq : await this.currentCursor(userID);
      return { cursor, events };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async pull(userID: string, body: SyncPullRequest): Promise<{ cursor: number; events: SerializedSyncEvent[] }> {
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

    return { cursor, events };
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
  ): Promise<SerializedSyncEvent> {
    if (change.op === "delete") {
      if (change.entityType === "space") {
        await client.query(
          `
            UPDATE spaces
            SET deleted_at = now(), updated_at = now(), revision = revision + 1, updated_by_device_id = $3
            WHERE user_id = $1 AND id = $2
          `,
          [userID, change.entityID, deviceID]
        );
      } else {
        await client.query(
          `
            UPDATE tabs
            SET deleted_at = now(), updated_at = now(), revision = revision + 1, updated_by_device_id = $3
            WHERE user_id = $1 AND id = $2
          `,
          [userID, change.entityID, deviceID]
        );
      }

      return this.insertSyncEvent(client, userID, deviceID, change.entityType, change.entityID, "delete", {
        id: change.entityID
      });
    }

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
      return this.insertSyncEvent(client, userID, deviceID, "space", change.entityID, "upsert", {
        id: change.entityID,
        ...change.data
      });
    }

    if (!change.data) {
      throw new Error("Tab upsert requires data");
    }

    await client.query(
      `
        INSERT INTO tabs (
          id, user_id, space_id, placement, rank, url_string, title, user_title_override,
          favicon_url_string, last_activity_at, deleted_at, updated_at, revision, updated_by_device_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, now(), 1, $11)
        ON CONFLICT (user_id, id)
        DO UPDATE SET
          space_id = EXCLUDED.space_id,
          placement = EXCLUDED.placement,
          rank = EXCLUDED.rank,
          url_string = EXCLUDED.url_string,
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
        deviceID
      ]
    );

    return this.insertSyncEvent(client, userID, deviceID, "tab", change.entityID, "upsert", {
      id: change.entityID,
      ...change.data
    });
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

  private async currentCursor(userID: string): Promise<number> {
    const result = await this.database.query(
      "SELECT COALESCE(MAX(server_seq), 0) AS cursor FROM sync_events WHERE user_id = $1",
      [userID]
    );
    return Number(result.rows[0].cursor);
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
