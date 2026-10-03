import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { it } from "node:test";
import type pg from "pg";
import type { SyncExpiryOperation, SyncOperationV4 } from "../src/schemas.js";

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
  startServerProcess: () => Promise<{ url: string; stop: () => Promise<void> }>;
};
type Archive = { archivedAt: string; sourceServerSeq: number; tab: Record<string, unknown> };
const oldActivity = "2000-01-01T01:02:03.123456Z";

/** Uses the shared production HTTP application and isolated PostgreSQL fixture. */
export function registerExpirySyncTests({ pool, account, post, startServerProcess }: Context) {
  const body = (device: Device, operations: unknown[], mutationID: string = randomUUID()) => ({
    protocolVersion: 5, mutationID, deviceID: device.id, operations
  });
  const expire = (device: Device, operations: SyncExpiryOperation[], mutationID: string = randomUUID(), url?: string) =>
    post<Response>("/v1/sync/push", device.token, body(device, operations, mutationID), 201, url);
  const push = (device: Device, operations: SyncOperationV4[], mutationID: string = randomUUID()) =>
    post<Response>("/v1/sync/push", device.token, { protocolVersion: 4, mutationID, deviceID: device.id, operations });
  const pull = (device: Device, cursor = 0, version: 2 | 4 | 5 = 5) => post<Response>("/v1/sync/pull", device.token, {
    deviceID: device.id, cursor, limit: 500, ...(version === 2 ? {} : { protocolVersion: version })
  });
  const latest = (response: Response, id: string) => {
    const event = response.events.findLast((event) => event.entityType === "tab" && event.entityID === id);
    assert.ok(event, `Canonical tab event missing: ${id}`);
    return event;
  };
  async function live(userID: string, id: string) {
    return (await pool().query("SELECT 1 FROM tabs WHERE user_id=$1 AND id=$2 AND deleted_at IS NULL", [userID, id])).rowCount === 1;
  }
  async function counts(userID: string) {
    return (await pool().query(`SELECT
      (SELECT count(*) FROM sync_events WHERE user_id=$1) AS events,
      (SELECT count(*) FROM sync_tombstones WHERE user_id=$1) AS tombstones,
      (SELECT count(*) FROM sync_mutation_receipts WHERE user_id=$1) AS receipts`, [userID])).rows[0];
  }
  function rejected(response: Response, reason: string, current?: Event) {
    assert.deepEqual(response.outcomes, [{ operationIndex: 0, status: "rejected", reason }]);
    assert.deepEqual(response.events, current ? [current] : []);
  }

  it("v5 expires an unchanged Today batch with canonical recovery available on ACK and fresh pulls", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), ids = [randomUUID(), randomUUID()], survivor = randomUUID();
    const seeded = await push(a, [space(s), ...[...ids, survivor].map((id) => tab(id, s))]);
    const originals = ids.map((id) => latest(seeded, id));
    const result = await expire(a, originals.map((event) => expiry(event)));
    assert.equal(result.protocolVersion, 5);
    assert.deepEqual(result.outcomes, ids.map((_, operationIndex) => ({ operationIndex, status: "applied" })));
    assert.equal(result.events.length, 2, "Expiry does not renumber peers and invalidate the next candidate");
    for (const [index, t] of ids.entries()) {
      const event = latest(result, t);
      assert.equal(event.op, "delete");
      const archive = event.data.autoArchive as Archive;
      assert.equal(event.data.id, t);
      assert.equal(archive.sourceServerSeq, originals[index].serverSeq);
      assert.deepEqual(archive.tab, originals[index].data);
      assert.equal(archive.tab.lastActivityAt, oldActivity);
      assert.match(archive.archivedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/);
      assert.equal((await pool().query("SELECT deleted_at = $3::timestamptz AS same_time FROM tabs WHERE user_id=$1 AND id=$2",
        [id, t, archive.archivedAt])).rows[0].same_time, true);
      assert.equal(await live(id, t), false);
    }
    const first = await pull(a), second = await pull(b);
    assert.equal(first.protocolVersion, 5);
    assert.deepEqual(first, second);
    assert.deepEqual(first.supportedPushVersions, [2, 3, 4, 5]);
    for (const t of ids) assert.deepEqual(latest(second, t), latest(result, t));
    const legacy = await pull(b, 0, 2);
    assert.equal(legacy.protocolVersion, 2);
    for (const t of ids) assert.deepEqual(latest(legacy, t), latest(result, t), "Legacy readers retain additive delete data");
    assert.equal(await live(id, survivor), true);
    assert.equal((await pool().query("SELECT rank FROM tabs WHERE user_id=$1 AND id=$2", [id, survivor])).rows[0].rank, 2);
  });

  it("v5 rejects a stale sequence after newer activity, pinning, movement or title changes", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), target = randomUUID(), ids = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
    const seeded = await push(a, [space(s), space(target), ...ids.map((id) => tab(id, s))]);
    const originals = ids.map((id) => latest(seeded, id));
    await push(b, [
      { kind: "patch", entityType: "tab", entityID: ids[0], fields: { lastActivityAt: "2100-01-01T00:00:00.000001Z" } },
      move(ids[1], s, "spacePinned"), move(ids[2], target, "temporary"),
      { kind: "patch", entityType: "tab", entityID: ids[3], fields: { title: "Fresh title" } }
    ]);
    const current = await pull(a);
    for (const original of originals) {
      rejected(await expire(a, [expiry(original)]), "state_changed", latest(current, original.entityID));
      assert.equal(await live(id, original.entityID), true);
    }
    rejected(await expire(a, [expiry(latest(current, ids[1]))]), "not_temporary", latest(current, ids[1]));
    assert.equal((await pool().query("SELECT count(*) AS count FROM sync_tombstones WHERE user_id=$1", [id])).rows[0].count, "0");
  });

  it("v5 skips unknown, future, recent and non-Today activity using server time and validates each interval", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), unknown = randomUUID(), future = randomUUID(), recent = randomUUID(), favorite = randomUUID();
    const relative = (await pool().query(`SELECT to_char((now() - interval '13 hours') AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS activity`)).rows[0].activity as string;
    const seeded = await push(a, [space(s), tab(unknown, s, null), tab(future, s, "2100-01-01T00:00:00.000000Z"),
      tab(recent, s, relative), { ...tab(favorite, s), data: { ...tab(favorite, s).data, placement: "app" as const } }]);
    for (const [t, reason] of [[unknown, "activity_unknown"], [future, "not_expired"], [recent, "not_expired"], [favorite, "not_temporary"]]) {
      rejected(await expire(a, [expiry(latest(seeded, t), 86400)]), reason, latest(seeded, t));
      assert.equal(await live(id, t), true);
    }
    assert.equal((await expire(a, [expiry(latest(seeded, recent), 43200)])).outcomes[0].status, "applied");
    for (const interval of [43200, 86400, 259200, 604800, 2592000] as const) {
      const t = randomUUID();
      const created = await push(a, [tab(t, s)]);
      assert.equal((await expire(a, [expiry(latest(created, t), interval)])).outcomes[0].status, "applied");
    }
  });

  it("v5 treats legacy PostgreSQL infinite timestamps as unknown activity", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID();
    await push(a, [space(s)]);
    for (const activity of ["infinity", "-infinity"]) {
      const t = randomUUID();
      const seeded = await push(a, [tab(t, s)]);
      await pool().query("UPDATE tabs SET last_activity_at=$3::timestamptz WHERE user_id=$1 AND id=$2", [id, t, activity]);
      rejected(await expire(a, [expiry(latest(seeded, t))]), "activity_unknown", latest(seeded, t));
      assert.equal(await live(id, t), true);
    }
  });

  it("v5 pull requires recovery replay after registration and every v4/legacy downgrade", async () => {
    const { devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID();
    const seeded = await push(a, [space(s), { kind: "create", entityType: "folder", entityID: f,
      data: { spaceID: s, parentFolderID: null, title: "Replay folder" } }, tab(t, s)]);
    const expired = await expire(a, [expiry(latest(seeded, t))]);
    const recovery = latest(expired, t);
    for (const older of [undefined, 4, 2] as const) {
      if (older) assert.deepEqual(latest(await pull(b, 0, older), t), recovery);
      const error = await post<{ message: string }>("/v1/sync/pull", b.token,
        { deviceID: b.id, protocolVersion: 5, cursor: expired.cursor }, 409);
      assert.equal(error.message, "Protocol 5 bootstrap requires cursor 0");
      const replay = await pull(b);
      assert.equal(replay.protocolVersion, 5);
      assert.deepEqual(latest(replay, t), recovery);
      assert.ok(replay.events.some((event) => event.entityType === "folder" && event.entityID === f));
      assert.deepEqual((await pull(b, replay.cursor)).events, []);
    }
    // Registering a replacement device gets independent bootstrap state even
    // when the account and its already upgraded local profile are unchanged.
    const replacement = await post<{ device: { id: string } }>("/v1/devices", a.token, { name: "replacement", platform: "integration" });
    const rotated = { id: replacement.device.id, token: a.token };
    await post("/v1/sync/pull", rotated.token, { deviceID: rotated.id, protocolVersion: 5, cursor: expired.cursor }, 409);
    assert.deepEqual(latest(await pull(rotated), t), recovery);
    for (const request of [{ deviceID: b.id, protocolVersion: 5, cursor: -1 },
      { deviceID: b.id, protocolVersion: 5, unexpected: true }]) {
      await post("/v1/sync/pull", b.token, request, 400);
    }
  });

  it("v5 bounds recovery and rejected-state echoes without deleting oversized candidates", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), large = randomUUID(), small = randomUUID(), mutationID = randomUUID();
    const huge = "🙂".repeat(1_100_000); // UTF-8 exceeds 4 MiB although the JS string length does not.
    const seeded = await push(a, [space(s), { ...tab(large, s), data: { ...tab(large, s).data, title: huge } }, tab(small, s)]);
    const original = latest(seeded, large), operation = expiry(original);
    const response = await expire(a, [operation, expiry(latest(seeded, small))], mutationID);
    assert.deepEqual(response.outcomes, [
      { operationIndex: 0, status: "rejected", reason: "response_limit" }, { operationIndex: 1, status: "applied" }
    ]);
    assert.ok(response.events.every((event) => event.entityID === small));
    assert.ok(Buffer.byteLength(JSON.stringify(response), "utf8") < 4 * 1024 * 1024);
    assert.equal(await live(id, large), true);
    assert.equal(await live(id, small), false);
    rejected(await expire(a, [{ ...operation, expectedServerSeq: operation.expectedServerSeq + 1 }]), "response_limit");
    const stored = (await pool().query("SELECT title, revision FROM tabs WHERE user_id=$1 AND id=$2", [id, large])).rows[0];
    assert.equal(stored.title, huge);
    assert.equal(stored.revision, "1");
    // A terminal response-limit receipt must not become destructive when the
    // tab later becomes small enough to fit a fresh request.
    await push(a, [{ kind: "patch", entityType: "tab", entityID: large, fields: { title: "Now small" } }]);
    const before = await counts(id);
    assert.deepEqual(await expire(a, [operation, expiry(latest(seeded, small))], mutationID), response);
    assert.deepEqual(await counts(id), before);
    assert.equal(await live(id, large), true);
  });

  it("v5 accounts for cumulative event bytes and continues smaller operations after the budget is exhausted", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), one = randomUUID(), two = randomUUID(), small = randomUUID();
    const title = "x".repeat(2_200_000);
    const seeded = await push(a, [space(s), ...[one, two].map((id) => ({ ...tab(id, s), data: { ...tab(id, s).data, title } })), tab(small, s)]);
    const response = await expire(a, [expiry(latest(seeded, one)), expiry(latest(seeded, two)), expiry(latest(seeded, small)), expiry(latest(seeded, one))]);
    assert.deepEqual(response.outcomes, [
      { operationIndex: 0, status: "applied" }, { operationIndex: 1, status: "rejected", reason: "response_limit" },
      { operationIndex: 2, status: "applied" }, { operationIndex: 3, status: "deleted" }
    ]);
    assert.deepEqual(response.events.map((event) => event.entityID), [one, small]);
    assert.ok(Buffer.byteLength(JSON.stringify(response), "utf8") < 4 * 1024 * 1024);
    assert.equal(await live(id, one), false);
    assert.equal(await live(id, two), true);
    assert.equal(await live(id, small), false);
    assert.equal((latest(response, one).data.autoArchive as Archive).tab.title, title, "Recovery is complete, never truncated");
  });

  it("v5 missing candidates never create tombstones and rejected receipts remain terminal after later creation", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), t = randomUUID(), mutationID = randomUUID();
    await push(a, [space(s)]);
    const operation: SyncExpiryOperation = { kind: "expire", entityType: "tab", entityID: t, expectedServerSeq: 1, inactiveForSeconds: 43200 };
    const receipt = await expire(a, [operation], mutationID);
    rejected(receipt, "missing");
    assert.equal((await pool().query("SELECT count(*) AS count FROM sync_tombstones WHERE user_id=$1", [id])).rows[0].count, "0");
    await push(a, [tab(t, s)]);
    const before = await counts(id);
    assert.deepEqual(await expire(a, [operation], mutationID), receipt);
    assert.deepEqual(await counts(id), before);
    assert.equal(await live(id, t), true);
  });

  it("v5 duplicate/lost-ACK delivery replays exact recovery after restart, device rotation and fresh-ID restore", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), t = randomUUID(), restored = randomUUID(), mutationID = randomUUID();
    const seeded = await push(a, [space(s), tab(t, s)]);
    const operation = expiry(latest(seeded, t));
    const [first, duplicate] = await Promise.all([expire(a, [operation], mutationID), expire(a, [operation], mutationID)]);
    assert.deepEqual(first, duplicate);
    assert.deepEqual(first.outcomes, [{ operationIndex: 0, status: "applied" }]);
    const prior = (latest(first, t).data.autoArchive as Archive).tab;
    await push(b, [tab(restored, s, oldActivity, prior.urlString as string)]);
    const before = await counts(id);
    const receipt = (await pool().query("SELECT payload_digest, response FROM sync_mutation_receipts WHERE user_id=$1 AND mutation_id=$2", [id, mutationID])).rows[0];
    const restarted = await startServerProcess();
    try { assert.deepEqual(await expire(b, [operation], mutationID, restarted.url), first); }
    finally { await restarted.stop(); }
    assert.deepEqual(await counts(id), before);
    assert.deepEqual((await pool().query("SELECT payload_digest, response FROM sync_mutation_receipts WHERE user_id=$1 AND mutation_id=$2", [id, mutationID])).rows[0], receipt);
    assert.equal(await live(id, restored), true);
    assert.equal(await live(id, t), false);
    for (const conflicting of [body(a, [{ ...operation, inactiveForSeconds: 86400 }], mutationID),
      { protocolVersion: 4, mutationID, deviceID: a.id, operations: [{ kind: "delete", entityType: "tab", entityID: restored }] }]) {
      await post("/v1/sync/push", a.token, conflicting, 409);
    }
    assert.deepEqual(await counts(id), before);
    assert.equal(await live(id, restored), true);
  });

  it("v5 keeps deletion terminal and never fabricates archive data for manual or parent deletion", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), other = randomUUID(), manual = randomUUID(), child = randomUUID(), automatic = randomUUID();
    const seeded = await push(a, [space(s), space(other), tab(manual, s), tab(child, other), tab(automatic, s)]);
    await push(b, [{ kind: "delete", entityType: "tab", entityID: manual }, { kind: "delete", entityType: "space", entityID: other }]);
    for (const t of [manual, child]) {
      const result = await expire(a, [expiry(latest(seeded, t))]);
      assert.deepEqual(result.outcomes, [{ operationIndex: 0, status: "deleted" }]);
      assert.deepEqual(latest(result, t).data, { id: t });
    }
    const expired = await expire(a, [expiry(latest((await pull(a)), automatic))]);
    const tombstone = latest(expired, automatic);
    assert.ok(tombstone.data.autoArchive);
    const retry = await expire(b, [expiry(latest(seeded, automatic))]);
    assert.deepEqual(retry.outcomes, [{ operationIndex: 0, status: "deleted" }]);
    assert.deepEqual(retry.events, [tombstone]);
    const late = await push(b, [{ kind: "patch", entityType: "tab", entityID: automatic, fields: { lastActivityAt: "2200-01-01T00:00:00Z" } }]);
    assert.deepEqual(late.events, [tombstone]);
    assert.equal(await live(id, automatic), false);
  });

  it("v5 isolates same tab identities and observed sequences across accounts", async () => {
    const one = await account(), two = await account();
    const a = one.devices[0], b = two.devices[0], s = randomUUID(), t = randomUUID();
    const first = await push(a, [space(s), tab(t, s)]);
    const second = await push(b, [space(s), tab(t, s, oldActivity, "https://other-account.test/")]);
    rejected(await expire(b, [expiry(latest(first, t))]), "state_changed", latest(second, t));
    await post("/v1/sync/push", a.token, body(b, [expiry(latest(second, t))]), 403);
    assert.equal((await expire(b, [expiry(latest(second, t))])).outcomes[0].status, "applied");
    assert.equal(await live(one.id, t), true);
    assert.equal(await live(two.id, t), false);
    assert.deepEqual((await pull(a)).events, first.events);
  });

  it("v5 rolls back deletion, recovery events, tombstones and receipt together on storage failure", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), t = randomUUID(), mutationID = randomUUID();
    const seeded = await push(a, [space(s), tab(t, s)]);
    const operation = expiry(latest(seeded, t)), before = await counts(id);
    await pool().query(`CREATE FUNCTION sync_expiry_test_abort() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
      IF NEW.mutation_id = '${mutationID}'::uuid THEN RAISE EXCEPTION 'expiry test rollback'; END IF;
      RETURN NEW; END $$;
      CREATE TRIGGER sync_expiry_test_abort BEFORE INSERT ON sync_mutation_receipts FOR EACH ROW EXECUTE FUNCTION sync_expiry_test_abort()`);
    try { await post("/v1/sync/push", a.token, body(a, [operation], mutationID), 500); }
    finally { await pool().query("DROP TRIGGER sync_expiry_test_abort ON sync_mutation_receipts; DROP FUNCTION sync_expiry_test_abort()"); }
    assert.deepEqual(await counts(id), before);
    assert.equal(await live(id, t), true);
    assert.deepEqual((await pull(a)).events, seeded.events);
    const result = await expire(a, [operation], mutationID);
    assert.equal(result.outcomes[0].status, "applied");
    assert.deepEqual((latest(result, t).data.autoArchive as Archive).tab, latest(seeded, t).data);
  });

  it("v5 rejects malformed expiry envelopes before writes without legacy fallback", async () => {
    const { id, devices: [a] } = await account();
    const operation: SyncExpiryOperation = { kind: "expire", entityType: "tab", entityID: "valid", expectedServerSeq: 1, inactiveForSeconds: 43200 };
    const invalid = [
      body(a, [{ ...operation, kind: "delete" }]), body(a, [{ ...operation, entityType: "space" }]),
      body(a, [{ ...operation, entityID: "" }]), body(a, [{ ...operation, expectedServerSeq: 0 }]),
      body(a, [{ ...operation, expectedServerSeq: -1 }]), body(a, [{ ...operation, expectedServerSeq: 1.5 }]),
      body(a, [{ ...operation, expectedServerSeq: Number.MAX_SAFE_INTEGER + 1 }]),
      body(a, [{ ...operation, inactiveForSeconds: 1 }]), body(a, [{ ...operation, inactiveForSeconds: "43200" }]),
      body(a, [{ ...operation, inactiveBefore: "2200-01-01T00:00:00Z" }]),
      body(a, Array.from({ length: 101 }, () => operation)), { ...body(a, [operation]), mutationID: undefined },
      { ...body(a, [operation]), protocolVersion: undefined }, { ...body(a, [operation]), changes: [] },
      { deviceID: a.id, protocolVersion: 5, mutationID: randomUUID(), changes: [] }
    ];
    for (const request of invalid) await post("/v1/sync/push", a.token, request, 400);
    assert.deepEqual(await counts(id), { events: "0", tombstones: "0", receipts: "0" });
  });
}

function expiry(event: Event, inactiveForSeconds: SyncExpiryOperation["inactiveForSeconds"] = 43200): SyncExpiryOperation {
  return { kind: "expire", entityType: "tab", entityID: event.entityID, expectedServerSeq: event.serverSeq, inactiveForSeconds };
}
function space(id: string): SyncOperationV4 {
  return { kind: "create", entityType: "space", entityID: id, data: { title: "Expiry", systemImageName: "clock", isPinnedSectionCollapsed: false } };
}
function tab(id: string, spaceID: string, lastActivityAt: string | null = oldActivity, urlString = `https://expiry.test/${id}`): Extract<SyncOperationV4, { kind: "create"; entityType: "tab" }> {
  return { kind: "create", entityType: "tab", entityID: id, data: {
    spaceID, placement: "temporary", pinnedFolderID: null, urlString, title: "Recovery title", userTitleOverride: "Custom title", lastActivityAt
  } };
}
function move(entityID: string, spaceID: string, placement: "temporary" | "spacePinned"): SyncOperationV4 {
  return { kind: "move", items: [{ entityType: "tab", entityID }], destination: { kind: "tabs", spaceID, placement, pinnedFolderID: null } };
}
