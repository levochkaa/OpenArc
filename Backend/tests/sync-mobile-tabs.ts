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
type MobileTabData = { urlString: string; title?: string; createdAt: string; lastActivityAt?: string };

const createdAt = "2026-11-27T10:00:00Z";
const tab = (urlString: string, extra: Partial<MobileTabData> = {}): MobileTabData => ({ urlString, createdAt, ...extra });
const upsert = (entityID: string, data: MobileTabData) => ({ kind: "upsert", entityType: "mobileTab", entityID, data });
const remove = (entityID: string) => ({ kind: "delete", entityType: "mobileTab", entityID });

/** Version 7 mobile tabs over the shared production HTTP application and isolated PostgreSQL fixture. */
export function registerMobileTabSyncTests({ pool, account, post }: Context) {
  const push = (device: Device, operations: unknown[], mutationID: string = randomUUID()) =>
    post<Response>("/v1/sync/push", device.token, { protocolVersion: 7, mutationID, deviceID: device.id, operations });
  const pull = (device: Device, cursor = 0, version: 2 | 4 | 5 | 6 | 7 = 7, status = 201) =>
    post<Response>("/v1/sync/pull", device.token, {
      deviceID: device.id, cursor, limit: 500, ...(version === 2 ? {} : { protocolVersion: version })
    }, status);
  const latest = (response: Response, id: string) => response.events.filter((event) => event.entityID === id).at(-1);
  const stored = async (userID: string, id: string) => (await pool().query(
    `SELECT url_string, title, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
       to_char(last_activity_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS last_activity_at,
       deleted_at IS NOT NULL AS deleted
     FROM mobile_tabs WHERE user_id = $1 AND id = $2`, [userID, id])).rows;

  it("v7 upserts echo the committed mobile tab with microsecond UTC instants, and v7 pulls carry it", async () => {
    const { devices: [a, b] } = await account();
    const id = randomUUID();
    const pushed = await push(a, [upsert(id, tab("https://example.com/", {
      title: "Example", lastActivityAt: "2026-11-27T10:05:00.123456Z"
    }))]);
    assert.equal(pushed.protocolVersion, 7);
    assert.deepEqual(pushed.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual(pushed.events.map((event) => [event.entityType, event.entityID, event.op]), [["mobileTab", id, "upsert"]]);
    const expected = {
      id, urlString: "https://example.com/", createdAt: "2026-11-27T10:00:00.000000Z",
      lastActivityAt: "2026-11-27T10:05:00.123456Z", title: "Example"
    };
    assert.deepEqual(pushed.events[0].data, expected);
    const fresh = await pull(b);
    assert.equal(fresh.protocolVersion, 7);
    assert.deepEqual(fresh.supportedPushVersions, [2, 3, 4, 5, 6, 7]);
    assert.deepEqual(latest(fresh, id)?.data, expected);
  });

  it("v7 upserts replace the whole tab: the last write wins and an absent title clears it", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const id = randomUUID();
    await push(a, [upsert(id, tab("https://example.com/", { title: "Example" }))]);
    const replaced = await push(b, [upsert(id, tab("https://example.org/next", { createdAt: "2026-11-26T08:30:00.5Z" }))]);
    assert.deepEqual(replaced.outcomes, [{ operationIndex: 0, status: "applied" }]);
    const expected = { id, urlString: "https://example.org/next", createdAt: "2026-11-26T08:30:00.500000Z" };
    assert.deepEqual(replaced.events[0].data, expected);
    assert.deepEqual(latest(await pull(a), id)?.data, expected);
    assert.deepEqual(await stored(userID, id), [{
      url_string: "https://example.org/next", title: null, created_at: "2026-11-26T08:30:00.500000Z",
      last_activity_at: null, deleted: false
    }]);
  });

  it("v7 activity keeps the maximum: older or absent activity never lowers or erases it", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const id = randomUUID();
    const later = "2026-11-27T12:00:00.654321Z";
    await push(a, [upsert(id, tab("https://example.com/", { lastActivityAt: later }))]);
    const older = await push(b, [upsert(id, tab("https://example.com/older", { lastActivityAt: "2026-11-27T11:00:00Z" }))]);
    assert.deepEqual(older.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.equal(older.events[0].data.lastActivityAt, later);
    assert.equal(older.events[0].data.urlString, "https://example.com/older", "other fields still replace");
    const omitted = await push(b, [upsert(id, tab("https://example.com/omitted"))]);
    assert.equal(omitted.events[0].data.lastActivityAt, later);
    assert.equal((await stored(userID, id))[0].last_activity_at, later);
    const newer = await push(a, [upsert(id, tab("https://example.com/", { lastActivityAt: "2026-11-27T13:00Z" }))]);
    assert.equal(newer.events[0].data.lastActivityAt, "2026-11-27T13:00:00.000000Z");
    // A new tab with no known activity stays without one.
    const quiet = randomUUID();
    const unknown = await push(a, [upsert(quiet, tab("https://example.com/quiet"))]);
    assert.equal("lastActivityAt" in unknown.events[0].data, false);
    assert.equal((await stored(userID, quiet))[0].last_activity_at, null);
  });

  it("v7 deletions are permanent: a late upsert is rejected with the tombstone, a repeat returns deleted", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const id = randomUUID();
    await push(a, [upsert(id, tab("https://example.com/"))]);
    const deleted = await push(b, [remove(id)]);
    assert.deepEqual(deleted.outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual(deleted.events.map((event) => [event.entityType, event.entityID, event.op, event.data]),
      [["mobileTab", id, "delete", { id }]]);
    const late = await push(a, [upsert(id, tab("https://example.com/late", { lastActivityAt: "2099-01-01T00:00Z" }))]);
    assert.deepEqual(late.outcomes, [{ operationIndex: 0, status: "rejected", reason: "deleted" }]);
    assert.deepEqual(late.events, deleted.events);
    const again = await push(a, [remove(id)]);
    assert.deepEqual(again.outcomes, [{ operationIndex: 0, status: "deleted" }]);
    assert.deepEqual(again.events, deleted.events);
    const rows = await stored(userID, id);
    assert.deepEqual(rows.map((row) => [row.url_string, row.deleted]), [["https://example.com/", true]]);
    const tombstones = await pool().query(
      "SELECT entity_type FROM sync_tombstones WHERE user_id = $1 AND entity_id = $2", [userID, id]);
    assert.deepEqual(tombstones.rows, [{ entity_type: "mobileTab" }]);
    // A tab closed before it ever reached the server is tombstoned too.
    const unseen = randomUUID();
    assert.deepEqual((await push(a, [remove(unseen)])).outcomes, [{ operationIndex: 0, status: "applied" }]);
    assert.deepEqual((await push(b, [upsert(unseen, tab("https://example.com/"))])).outcomes,
      [{ operationIndex: 0, status: "rejected", reason: "deleted" }]);
    // A desktop tab with the same identity is a different entity.
    const desktop = await post<Response>("/v1/sync/push", a.token, {
      protocolVersion: 2, mutationID: randomUUID(), deviceID: a.id, changes: [{ entityType: "tab", entityID: id, op: "delete" }]
    });
    assert.ok(desktop.events.some((event) => event.entityType === "tab" && event.entityID === id));
  });

  it("v7 receipts replay exactly, include the operations, and conflict on different content", async () => {
    const { id: userID, devices: [a, b] } = await account();
    const mutationID = randomUUID(), id = randomUUID();
    const operations = [upsert(id, tab("https://example.com/", { title: "One" })), remove(randomUUID())];
    const original = await push(a, operations, mutationID);
    assert.equal(original.mutationID, mutationID);
    assert.deepEqual(original.outcomes.map((outcome) => outcome.status), ["applied", "applied"]);
    // Later writes do not change the replayed receipt, and another device may retry it.
    await push(b, [upsert(id, tab("https://example.com/changed"))]);
    const events = (await pool().query("SELECT count(*)::int AS count FROM sync_events WHERE user_id = $1", [userID])).rows[0];
    assert.deepEqual(await push(b, operations, mutationID), original);
    assert.deepEqual((await pool().query("SELECT count(*)::int AS count FROM sync_events WHERE user_id = $1", [userID])).rows[0], events);
    await post("/v1/sync/push", a.token, {
      protocolVersion: 7, mutationID, deviceID: a.id, operations: [upsert(id, tab("https://example.com/", { title: "Two" }))]
    }, 409);
    await post("/v1/sync/push", a.token, { protocolVersion: 6, mutationID, deviceID: a.id, operations: [] }, 409);
  });

  it("readers before v7 never see mobile tabs, and upgrading after an older pull replays from zero", async () => {
    const { devices: [a, b] } = await account();
    const id = randomUUID();
    await push(a, [upsert(id, tab("https://example.com/"))]);
    // A later boost gives older readers a cursor past the mobile tab.
    await post("/v1/sync/push", a.token, { protocolVersion: 6, mutationID: randomUUID(), deviceID: a.id, operations: [
      { kind: "upsert", entityType: "boost", entityID: randomUUID(),
        data: { host: "example.com", isEnabled: true, css: "", javaScript: "", zappedSelectors: [] } }
    ] });
    // A device that never pulled at v7 must bootstrap from zero.
    await pull(b, 1, 7, 409);
    for (const version of [2, 4, 5, 6] as const) {
      const older = await pull(b, 0, version);
      assert.equal(older.protocolVersion, version);
      assert.deepEqual(older.supportedPushVersions, [2, 3, 4, 5, 6, 7]);
      assert.ok(older.events.every((event) => event.entityType !== "mobileTab"), `v${version} pull leaked a mobile tab`);
    }
    const current = await pull(b, 0, 6);
    assert.ok(current.cursor > 0);
    assert.ok(current.events.some((event) => event.entityType === "boost"));
    // The v6 pull reset the mobile tab marker: a v7 read above zero must bootstrap.
    const conflict = await pull(b, current.cursor, 7, 409);
    assert.match(JSON.stringify(conflict), /Protocol 7 bootstrap requires cursor 0/);
    const bootstrap = await pull(b, 0, 7);
    assert.equal(bootstrap.protocolVersion, 7);
    assert.ok(bootstrap.events.some((event) => event.entityType === "mobileTab" && event.entityID === id));
    assert.ok(bootstrap.events.some((event) => event.entityType === "boost"), "v7 reads everything v6 reads");
    assert.deepEqual((await pull(b, bootstrap.cursor, 7)).events, []);
    // Every older version resets the marker again.
    for (const version of [2, 4, 5, 6] as const) {
      await pull(b, bootstrap.cursor, version);
      await pull(b, bootstrap.cursor, 7, 409);
      await pull(b, 0, 7);
    }
  });

  it("v7 rejects malformed mobile tabs and other entities without writing", async () => {
    const { id: userID, devices: [a] } = await account();
    const before = (await pool().query("SELECT count(*)::int AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    for (const operations of [
      [],
      [upsert(randomUUID(), tab(""))],
      [upsert(randomUUID(), tab("a".repeat(8193)))],
      [upsert(randomUUID(), tab("https://example.com/", { title: "" }))],
      [upsert(randomUUID(), tab("https://example.com/", { title: "a".repeat(1025) }))],
      [upsert(randomUUID(), { ...tab("https://example.com/"), title: null } as unknown as MobileTabData)],
      [upsert(randomUUID(), tab("https://example.com/", { createdAt: "2026-11-27T10:00:00+04:00" }))],
      [upsert(randomUUID(), tab("https://example.com/", { lastActivityAt: "2026-11-27 10:00:00Z" }))],
      [upsert(randomUUID(), { ...tab("https://example.com/"), lastActivityAt: null } as unknown as MobileTabData)],
      [upsert(randomUUID(), { urlString: "https://example.com/" } as MobileTabData)],
      [upsert(randomUUID(), { ...tab("https://example.com/"), spaceID: "s" } as MobileTabData)],
      [upsert("a".repeat(201), tab("https://example.com/"))],
      [{ kind: "patch", entityType: "mobileTab", entityID: "x", fields: {} }],
      [{ kind: "delete", entityType: "boost", entityID: "x" }],
      Array.from({ length: 1001 }, () => remove(randomUUID()))
    ]) {
      await post("/v1/sync/push", a.token, { protocolVersion: 7, mutationID: randomUUID(), deviceID: a.id, operations }, 400);
    }
    // Older versions cannot write mobile tabs.
    await post("/v1/sync/push", a.token, {
      protocolVersion: 6, mutationID: randomUUID(), deviceID: a.id, operations: [upsert(randomUUID(), tab("https://example.com/"))]
    }, 400);
    const after = (await pool().query("SELECT count(*)::int AS events FROM sync_events WHERE user_id=$1", [userID])).rows[0];
    assert.deepEqual(after, before);
  });
}
