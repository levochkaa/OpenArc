import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { it } from "node:test";
import type pg from "pg";

type Device = { id: string; token: string };
type Event = { serverSeq: number; entityType: string; entityID: string; op: string; data: Record<string, unknown> };
type Response = {
  protocolVersion: number; mutationID?: string; cursor: number; events: Event[]; supportedPushVersions?: number[];
  outcomes: { operationIndex: number; status: string; reason?: string }[];
};
type Context = {
  pool: () => pg.Pool;
  account: () => Promise<{ id: string; devices: [Device, Device] }>;
  post: <T>(path: string, token: string, body: unknown, status?: number, url?: string) => Promise<T>;
};
type BoostStyle = {
  colors?: {
    tint?: { hue: number; saturation: number; secondaryHueOffset: number };
    invertsLightness: boolean; contrast: number; brightness: number; originalSaturation: number;
  };
  fontFamily?: string; textCase?: string; textZoom?: number;
};
type BoostData = {
  host: string; isEnabled: boolean; css: string; javaScript: string; zappedSelectors: string[];
  title?: string; style?: BoostStyle;
};

const boost = (host: string, css = ""): BoostData => ({ host, isEnabled: true, css, javaScript: "", zappedSelectors: [] });
const upsert = (entityID: string, data: BoostData) => ({ kind: "upsert", entityType: "boost", entityID, data });
const remove = (entityID: string) => ({ kind: "delete", entityType: "boost", entityID });

/** Version 6 boosts over the shared production HTTP application and isolated PostgreSQL fixture. */
export function registerBoostSyncTests({ pool, account, post }: Context) {
  const push = (device: Device, operations: unknown[], mutationID: string = randomUUID()) =>
    post<Response>("/v1/sync/push", device.token, { protocolVersion: 6, mutationID, deviceID: device.id, operations });
  const pull = (device: Device, cursor = 0, version: 2 | 4 | 5 | 6 = 6, status = 201) =>
    post<Response>("/v1/sync/pull", device.token, {
      deviceID: device.id, cursor, limit: 500, ...(version === 2 ? {} : { protocolVersion: version })
    }, status);

  it("v6 upserts replace a whole boost, the last write wins, and v6 pulls carry it", async () => {
    const { devices: [a, b] } = await account();
    const id = randomUUID();
    const first = await push(a, [upsert(id, boost("example.com", "body { color: red }"))]);
    assert.equal(first.protocolVersion, 6);
    assert.deepEqual(first.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual(first.events.map((event) => [event.entityType, event.entityID, event.op]), [["boost", id, "upsert"]]);
    assert.deepEqual(first.events[0].data, { id, ...boost("example.com", "body { color: red }") });
    const second = await push(b, [upsert(id, { ...boost("example.com"), isEnabled: false, zappedSelectors: ["#ad"] })]);
    assert.deepEqual(second.outcomes, [{ operationIndex: 0, status: "applied" }]);
    const fresh = await pull(b);
    assert.equal(fresh.protocolVersion, 6);
    assert.deepEqual(fresh.supportedPushVersions, [2, 3, 4, 5, 6]);
    const events = fresh.events.filter((event) => event.entityID === id);
    assert.deepEqual(events.at(-1)?.data, { id, ...boost("example.com"), isEnabled: false, zappedSelectors: ["#ad"] });
  });

  it("v6 deletions are permanent: a late upsert is rejected with the tombstone", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const id = randomUUID();
    await push(a, [upsert(id, boost("example.com"))]);
    const deleted = await push(b, [remove(id)]);
    assert.deepEqual(deleted.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual(deleted.events.map((event) => [event.entityID, event.op, event.data]), [[id, "delete", { id }]]);
    const late = await push(a, [upsert(id, boost("example.com", "late"))]);
    assert.deepEqual(late.outcomes, [{ operationIndex: 0, status: "rejected", reason: "deleted" }]);
    assert.deepEqual(late.events, deleted.events);
    const again = await push(a, [remove(id)]);
    assert.deepEqual(again.outcomes, [{ operationIndex: 0, status: "deleted" }]);
    const rows = await pool().query("SELECT deleted_at IS NOT NULL AS deleted FROM boosts WHERE user_id=$1 AND id=$2", [userID, id]);
    assert.deepEqual(rows.rows, [{ deleted: true }]);
    // A boost deleted before it ever reached the server is tombstoned too.
    const unseen = randomUUID();
    assert.deepEqual((await push(a, [remove(unseen)])).outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual((await push(b, [upsert(unseen, boost("other.test"))])).outcomes,
      [{ operationIndex: 0, status: "rejected", reason: "deleted" }]);
  });

  it("v6 receipts replay exactly and conflict on different content", async () => {
    const { devices: [a] } = await account();
    const mutationID = randomUUID(), id = randomUUID();
    const original = await push(a, [upsert(id, boost("example.com"))], mutationID);
    assert.deepEqual(await push(a, [upsert(id, boost("example.com"))], mutationID), original);
    await post("/v1/sync/push", a.token, {
      protocolVersion: 6, mutationID, deviceID: a.id, operations: [upsert(id, boost("example.com", "changed"))]
    }, 409);
  });

  it("readers before v6 never see boosts, and upgrading after an older pull replays from zero", async () => {
    const { devices: [a, b] } = await account();
    const id = randomUUID();
    await push(a, [upsert(id, boost("example.com"))]);
    // A later Space gives older readers a cursor past the boost.
    await post("/v1/sync/push", a.token, { protocolVersion: 4, mutationID: randomUUID(), deviceID: a.id, operations: [
      { kind: "create", entityType: "space", entityID: randomUUID(),
        data: { title: "Boosts", systemImageName: "globe", isPinnedSectionCollapsed: false } }
    ] });
    for (const version of [2, 4, 5] as const) {
      const older = await pull(b, 0, version);
      assert.ok(older.events.every((event) => event.entityType !== "boost"), `v${version} pull leaked a boost`);
    }
    const current = await pull(b, 0, 5);
    assert.ok(current.cursor > 0);
    // The v5 pull reset the boost marker: a v6 read above zero must bootstrap.
    await pull(b, current.cursor, 6, 409);
    const bootstrap = await pull(b, 0, 6);
    assert.ok(bootstrap.events.some((event) => event.entityType === "boost" && event.entityID === id));
    const incremental = await pull(b, bootstrap.cursor, 6);
    assert.deepEqual(incremental.events, []);
  });

  it("v6 upserts carry the boost's name and styling, and a write without them clears them", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const id = randomUUID();
    const style: BoostStyle = {
      colors: { tint: { hue: 210.5, saturation: 0.4, secondaryHueOffset: 30 },
        invertsLightness: true, contrast: 1.2, brightness: 0.9, originalSaturation: 0.25 },
      fontFamily: "Georgia", textCase: "uppercase", textZoom: 1.25
    };
    const styled = { ...boost("example.com", "a {}"), title: "Reader", style };
    const pushed = await push(a, [upsert(id, styled)]);
    assert.deepEqual(pushed.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual(pushed.events[0].data, { id, ...styled });
    const pulled = await pull(b);
    assert.deepEqual(pulled.events.find((event) => event.entityID === id)?.data, { id, ...styled });
    const stored = await pool().query("SELECT title, style FROM boosts WHERE user_id=$1 AND id=$2", [userID, id]);
    assert.deepEqual(stored.rows, [{ title: "Reader", style }]);

    // A whole-record write without them goes back to the site's own look and the default name.
    await push(b, [upsert(id, boost("example.com", "a {}"))]);
    const cleared = await pull(a);
    const latest = cleared.events.filter((event) => event.entityID === id).at(-1);
    assert.deepEqual(latest?.data, { id, ...boost("example.com", "a {}") });
    const after = await pool().query("SELECT title, style FROM boosts WHERE user_id=$1 AND id=$2", [userID, id]);
    assert.deepEqual(after.rows, [{ title: null, style: null }]);
  });

  it("v6 rejects styling outside its bounds without writing", async () => {
    const { id: userID, devices: [a] } = await account();
    const before = (await pool().query("SELECT count(*) AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    const colors = { invertsLightness: false, contrast: 1, brightness: 1, originalSaturation: 0 };
    for (const extra of [
      { title: "" },
      { title: "a".repeat(1025) },
      { style: { textCase: "smallcaps" } },
      { style: { textZoom: 10 } },
      { style: { fontFamily: "" } },
      { style: { colors: { ...colors, contrast: 5 } } },
      { style: { colors: { ...colors, tint: { hue: 361, saturation: 0.5, secondaryHueOffset: 30 } } } },
      { style: { colors: { invertsLightness: true } } },
      { style: { shadow: true } }
    ]) {
      await post("/v1/sync/push", a.token, {
        protocolVersion: 6, mutationID: randomUUID(), deviceID: a.id,
        operations: [upsert(randomUUID(), { ...boost("example.com"), ...extra } as BoostData)]
      }, 400);
    }
    const after = (await pool().query("SELECT count(*) AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    assert.deepEqual(after, before);
  });

  it("v6 rejects malformed boosts without writing", async () => {
    const { id: userID, devices: [a] } = await account();
    const before = (await pool().query("SELECT count(*) AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    await post("/v1/sync/push", a.token, {
      protocolVersion: 6, mutationID: randomUUID(), deviceID: a.id,
      operations: [upsert(randomUUID(), { ...boost(""), css: "" })]
    }, 400);
    await post("/v1/sync/push", a.token, {
      protocolVersion: 6, mutationID: randomUUID(), deviceID: a.id,
      operations: [{ kind: "patch", entityType: "boost", entityID: "x", fields: {} }]
    }, 400);
    const after = (await pool().query("SELECT count(*) AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    assert.deepEqual(after, before);
  });
}
