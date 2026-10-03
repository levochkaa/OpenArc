import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { it } from "node:test";
import type pg from "pg";

type Version = 1 | 2 | 3 | 4;
type Device = { id: string; token: string };
type Event = {
  serverSeq: number; entityType: string; entityID: string; op: string; data: Record<string, unknown>;
};
type Response = { cursor: number; events: Event[]; protocolVersion?: number; mutationID?: string };
type Context = {
  pool: () => pg.Pool;
  account: () => Promise<{ id: string; devices: [Device, Device] }>;
  post: <T>(path: string, token: string, body: unknown, status?: number, url?: string) => Promise<T>;
  startServerProcess: () => Promise<{ url: string; stop: () => Promise<void> }>;
};

const older = "2026-10-03T04:05:06.123455Z";
const newer = "2026-10-03T04:05:06.123456Z";
const newest = "2026-10-03T04:05:07.987654Z";

/** Runs against the suite's production Nest server and disposable PostgreSQL. */
export function registerActivitySyncTests({ pool, account, post, startServerProcess }: Context) {
  const envelope = (version: Version, device: Device, writes: unknown[], mutationID: string = randomUUID()) => ({
    deviceID: device.id,
    ...(version === 1 ? {} : { protocolVersion: version, mutationID }),
    ...(version <= 2 ? { changes: writes } : { operations: writes })
  });
  const push = (version: Version, device: Device, writes: unknown[], mutationID: string = randomUUID(), url?: string) =>
    post<Response>("/v1/sync/push", device.token, envelope(version, device, writes, mutationID), 201, url);
  const pull = (version: Version, device: Device) => post<Response>("/v1/sync/pull", device.token, {
    deviceID: device.id, cursor: 0, limit: 500, ...(version === 4 ? { protocolVersion: 4 } : {})
  });

  async function stored(userID: string, tabID: string) {
    const result = await pool().query(`SELECT
      to_char(last_activity_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS activity,
      title, rank, placement, space_id, pinned_folder_id, revision, deleted_at IS NOT NULL AS deleted
      FROM tabs WHERE user_id = $1 AND id = $2`, [userID, tabID]);
    assert.equal(result.rowCount, 1);
    return result.rows[0];
  }

  function assertActivity(response: Response, id: string, expected: string | null) {
    const upserts = response.events.filter((event) => event.entityType === "tab" && event.entityID === id && event.op === "upsert");
    assert.ok(upserts.length, "The ACK must include the tab's canonical committed state");
    for (const event of upserts) assert.equal(event.data.lastActivityAt, expected);
  }

  for (const version of [2, 3, 4] as const) {
    it(`v${version} activity converges to the maximum in both delivery orders and concurrent writes at microsecond precision`, async () => {
      const { id, devices: [a, b] } = await account();
      const s = randomUUID(), ascending = randomUUID(), descending = randomUUID(), concurrent = randomUUID();
      await push(version, a, [space(version, s), ...[ascending, descending, concurrent].map((t) => createTab(version, t, s))]);
      for (const [t, values] of [[ascending, [older, newer]], [descending, [newer, older]]] as const) {
        for (const [index, value] of values.entries()) {
          const response = await push(version, index === 0 ? a : b, [patchTab(version, t, s, { lastActivityAt: value })]);
          assertActivity(response, t, index === 0 ? value : newer);
        }
        assert.equal((await stored(id, t)).activity, newer);
      }
      await Promise.all([
        push(version, a, [patchTab(version, concurrent, s, { lastActivityAt: newer })]),
        push(version, b, [patchTab(version, concurrent, s, { lastActivityAt: older })])
      ]);
      assert.equal((await stored(id, concurrent)).activity, newer);
      const first = await pull(version, a), second = await pull(version, b);
      assert.deepEqual(second, first, "Both devices receive the same canonical activity history");
      for (const t of [ascending, descending, concurrent]) {
        const history = first.events.filter((event) => event.entityID === t && event.op === "upsert")
          .map((event) => event.data.lastActivityAt).filter((value): value is string => typeof value === "string");
        assert.equal(history.at(-1), newer);
        assert.deepEqual(history, [...history].sort(), "Committed activity never decreases, including within one millisecond");
      }
    });
  }

  for (const version of [1, 2, 3, 4] as const) {
    it(`v${version} null and omitted activity preserve a known value while new tabs remain null`, async () => {
      const { id, devices: [a, b] } = await account();
      const s = randomUUID(), t = randomUUID(), absent = randomUUID(), explicitNull = randomUUID();
      const initial = await push(version, a, [space(version, s), createTab(version, t, s, { lastActivityAt: newer }),
        createTab(version, absent, s), createTab(version, explicitNull, s, { lastActivityAt: null })]);
      assertActivity(initial, absent, null);
      assertActivity(initial, explicitNull, null);
      assert.equal((await stored(id, absent)).activity, null);
      assert.equal((await stored(id, explicitNull)).activity, null);
      for (const fields of [{ lastActivityAt: null, title: "Null touch" }, { title: "Metadata only" },
        { lastActivityAt: newer, title: "Equal touch" }, { lastActivityAt: "2026-10-03T04:05:06.1234560Z", title: "Equivalent precision" }]) {
        const response = await push(version, b, [patchTab(version, t, s, fields)]);
        assertActivity(response, t, newer);
        const row = await stored(id, t);
        assert.equal(row.activity, newer);
        assert.equal(row.title, fields.title, "An old/null touch must not suppress unrelated metadata");
      }
      assert.equal((await pull(version, a)).events.findLast((event) => event.entityID === t)?.data.lastActivityAt, newer);
    });
  }

  for (const version of [3, 4] as const) {
    it(`v${version} patch, rename, move and peer normalization in one request preserve committed activity`, async () => {
      const { id, devices: [a, b] } = await account();
      const s = randomUUID(), target = randomUUID(), t = randomUUID(), peer = randomUUID();
      await push(version, a, [space(version, s), space(version, target), createTab(version, t, s),
        createTab(version, peer, target, { lastActivityAt: newest })]);
      const move = version === 3
        ? { kind: "move", entityType: "tab", entityIDs: [t], destination: { spaceID: target, placement: "temporary" }, beforeID: peer }
        : { kind: "move", items: [{ entityType: "tab", entityID: t }],
          destination: { kind: "tabs", spaceID: target, placement: "temporary", pinnedFolderID: null },
          before: { entityType: "tab", entityID: peer } };
      const response = await push(version, b, [patchTab(version, t, s, { lastActivityAt: newer }),
        patchTab(version, t, s, { lastActivityAt: older, title: "Renamed with stale activity" }), move,
        patchTab(version, t, target, { lastActivityAt: null, userTitleOverride: "After move" })]);
      assertActivity(response, t, newer);
      assertActivity(response, peer, newest);
      const row = await stored(id, t);
      assert.equal(row.activity, newer);
      assert.equal(row.space_id, target);
      assert.equal(row.rank, 0);
      assert.equal(row.title, "Renamed with stale activity");
      assert.equal((await stored(id, peer)).rank, 1);
      assert.equal((await stored(id, peer)).activity, newest);
    });
  }

  it("v4 subtree moves preserve each child's canonical activity after stale patches", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), target = randomUUID(), f = randomUUID(), t = randomUUID();
    await push(4, a, [space(4, s), space(4, target), { kind: "create", entityType: "folder", entityID: f,
      data: { spaceID: s, parentFolderID: null, title: "Activity folder" } },
    createTab(4, t, s, { placement: "spacePinned", pinnedFolderID: f, lastActivityAt: newest })]);
    const response = await push(4, b, [patchTab(4, t, s, { lastActivityAt: older }), {
      kind: "move", items: [{ entityType: "folder", entityID: f }],
      destination: { kind: "tabs", spaceID: target, placement: "spacePinned", pinnedFolderID: null }
    }]);
    assertActivity(response, t, newest);
    const row = await stored(id, t);
    assert.equal(row.space_id, target);
    assert.equal(row.pinned_folder_id, f);
    assert.equal(row.activity, newest);
  });

  it("compares PostgreSQL instants independently of timezone and retains UTC-only wire validation", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), t = randomUUID();
    await push(4, a, [space(4, s), createTab(4, t, s)]);
    // Existing database values may originate in a non-UTC SQL session. The
    // HTTP schema still accepts UTC only; this does not broaden wire validation.
    await pool().query("UPDATE tabs SET last_activity_at = $3::timestamptz WHERE user_id = $1 AND id = $2",
      [id, t, "2026-10-03T08:05:06.123456+04:00"]);
    assertActivity(await push(4, a, [patchTab(4, t, s, { lastActivityAt: older })]), t, newer);
    assert.equal((await stored(id, t)).activity, newer);
    const before = await pull(4, a);
    for (const invalid of ["2026-10-03T08:05:06.123456+04:00", "not-a-date"]) {
      await post("/v1/sync/push", a.token, envelope(4, a, [patchTab(4, t, s, { lastActivityAt: invalid })]), 400);
    }
    assert.deepEqual(await pull(4, a), before, "Rejected timestamps cannot append events or mutate the row");
  });

  it("v2/v3/v4 lost-ACK retries keep exact historical receipts after a newer touch and process restart", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID();
    await push(4, a, [space(4, s)]);
    const pending: { version: 2 | 3 | 4; t: string; mutationID: string; writes: unknown[]; receipt: Response }[] = [];
    for (const version of [2, 3, 4] as const) {
      const t = randomUUID(), mutationID = randomUUID();
      await push(version, a, [createTab(version, t, s)]);
      const writes = [patchTab(version, t, s, { lastActivityAt: older })];
      // Discard the first ACK from the client's perspective; the server has committed it.
      const receipt = await push(version, a, writes, mutationID);
      assertActivity(receipt, t, older);
      await push(4, b, [patchTab(4, t, s, { lastActivityAt: newest })]);
      pending.push({ version, t, mutationID, writes, receipt });
    }
    const before = await pull(4, b);
    const receiptRows = await pool().query("SELECT mutation_id, payload_digest, response FROM sync_mutation_receipts WHERE user_id=$1 ORDER BY mutation_id", [id]);
    const revisions = await Promise.all(pending.map(({ t }) => stored(id, t)));
    const restarted = await startServerProcess();
    try {
      for (const { version, t, mutationID, writes, receipt } of pending) {
        assert.deepEqual(await push(version, a, writes, mutationID, restarted.url), receipt);
        assert.equal((await stored(id, t)).activity, newest, "An old receipt must not reapply its older touch");
      }
    } finally { await restarted.stop(); }
    assert.deepEqual(await Promise.all(pending.map(({ t }) => stored(id, t))), revisions);
    assert.deepEqual(await pull(4, b), before);
    assert.deepEqual((await pool().query("SELECT mutation_id, payload_digest, response FROM sync_mutation_receipts WHERE user_id=$1 ORDER BY mutation_id", [id])).rows,
      receiptRows.rows, "Retries preserve stored payload digests and exact responses");
  });

  it("activity never resurrects explicitly deleted tabs or children of a deleted Space", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), parent = randomUUID(), child = randomUUID(), ids = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
    await push(4, a, [space(4, s), space(4, parent), createTab(4, child, parent, { lastActivityAt: newer }),
      ...ids.map((t) => createTab(4, t, s, { lastActivityAt: newer }))]);
    const deleted = await push(4, a, [...ids.map((entityID) => ({ kind: "delete", entityType: "tab", entityID })),
      { kind: "delete", entityType: "space", entityID: parent }]);
    for (const [index, version] of ([1, 2, 3, 4] as const).entries()) {
      const t = ids[index];
      const response = await push(version, b, [patchTab(version, t, s, { lastActivityAt: newest }),
        patchTab(version, child, parent, { lastActivityAt: newest })]);
      assert.equal(response.events.length, 2);
      for (const entityID of [t, child]) {
        assert.deepEqual(response.events.filter((event) => event.entityID === entityID),
          deleted.events.filter((event) => event.entityID === entityID && event.op === "delete"));
        assert.equal((await stored(id, entityID)).deleted, true);
        assert.equal((await stored(id, entityID)).activity, newer);
      }
    }
  });
}

function space(version: Version, id: string) {
  const data = { title: "Activity", systemImageName: "clock" };
  return version <= 2 ? { entityType: "space", entityID: id, op: "upsert", data: { ...data, rank: 0 } }
    : { kind: "create", entityType: "space", entityID: id, data };
}

function createTab(version: Version, id: string, spaceID: string, fields: Record<string, unknown> = {}) {
  const data = { spaceID, placement: "temporary", urlString: `https://example.test/activity/${id}`,
    ...(version === 4 ? { pinnedFolderID: null } : {}), ...fields };
  return version <= 2 ? { entityType: "tab", entityID: id, op: "upsert", data: { ...data, rank: 0 } }
    : { kind: "create", entityType: "tab", entityID: id, data };
}

function patchTab(version: Version, id: string, spaceID: string, fields: Record<string, unknown>) {
  return version <= 2 ? createTab(version, id, spaceID, fields) : { kind: "patch", entityType: "tab", entityID: id, fields };
}
