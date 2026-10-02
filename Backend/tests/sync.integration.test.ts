import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { after, before, describe, it } from "node:test";
import type { INestApplication } from "@nestjs/common";
import type pg from "pg";
import type { SyncChange } from "../src/schemas.js";

type SyncEvent = {
  serverSeq: number;
  entityType: "space" | "tab";
  entityID: string;
  op: "upsert" | "delete";
  data: Record<string, unknown>;
};
type SyncResponse = { cursor: number; events: SyncEvent[]; protocolVersion?: 2; mutationID?: string };
type Device = { id: string; token: string };
type Account = { id: string; devices: [Device, Device] };

const testDatabaseURL = process.env.THEBROWSER_SYNC_TEST_DATABASE_URL;

describe("PostgreSQL sync convergence over authenticated localhost HTTP", {
  skip: testDatabaseURL ? false : "Run ./script/test_local_sync.sh for an isolated PostgreSQL integration run",
  timeout: 30_000
}, () => {
  let app: INestApplication;
  let baseURL: string;
  let pool: pg.Pool;
  let issueAccessToken: (userID: string) => Promise<string>;
  const legacy = { userID: randomUUID(), deletedSpace: randomUUID(), liveSpace: randomUUID(), orphan: randomUUID(), moved: randomUUID() };

  before(async () => {
    assert.ok(testDatabaseURL);
    const url = new URL(testDatabaseURL);
    assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(url.hostname), "Only loopback test databases are allowed");
    assert.match(url.pathname, /^\/thebrowser_sync_test_[a-z0-9_]+$/, "Use a dedicated disposable test database");
    process.env.DATABASE_URL = testDatabaseURL;
    process.env.APPLE_CLIENT_ID = "com.thebrowser.sync-integration-tests";
    process.env.JWT_SECRET = "local-integration-only-secret-at-least-thirty-two-bytes";
    process.env.JWT_ISSUER = "thebrowser-sync-integration-tests";
    process.env.JWT_AUDIENCE = "thebrowser-sync-integration-clients";

    const [{ buildApp }, { AuthService }, database] = await Promise.all([
      import("../src/app.js"),
      import("../src/auth.service.js"),
      import("../src/db.js")
    ]);
    pool = database.pool;
    const databaseName = await pool.query("SELECT current_database() AS name");
    assert.equal(databaseName.rows[0].name, url.pathname.slice(1));
    const existingSchema = await pool.query("SELECT to_regclass('public.app_users') AS table_name");
    assert.equal(existingSchema.rows[0].table_name, null, "Integration tests require a fresh empty database");
    await pool.query(await readFile(new URL("../migrations/001_init.sql", import.meta.url), "utf8"));
    await pool.query("INSERT INTO app_users (id, apple_subject) VALUES ($1, $2)", [legacy.userID, `legacy-${legacy.userID}`]);
    await pool.query(`
      INSERT INTO spaces (id, user_id, title, system_image_name, rank, deleted_at)
      VALUES ($1, $3, 'Deleted legacy space', 'globe', 0, now()), ($2, $3, 'Live legacy space', 'globe', 1, NULL)
    `, [legacy.deletedSpace, legacy.liveSpace, legacy.userID]);
    await pool.query(`
      INSERT INTO tabs (id, user_id, space_id, placement, rank, url_string)
      VALUES ($1, $3, $4, 'temporary', 0, 'https://example.test/orphan'),
        ($2, $3, $5, 'temporary', 1, 'https://example.test/moved')
    `, [legacy.orphan, legacy.moved, legacy.userID, legacy.deletedSpace, legacy.liveSpace]);
    for (const change of [space(legacy.deletedSpace), space(legacy.liveSpace), tab(legacy.orphan, legacy.deletedSpace),
      tab(legacy.moved, legacy.liveSpace), deletion("space", legacy.deletedSpace)]) {
      await pool.query(`
        INSERT INTO sync_events (user_id, entity_type, entity_id, op, payload) VALUES ($1, $2, $3, $4, $5)
      `, [legacy.userID, change.entityType, change.entityID, change.op, JSON.stringify({ id: change.entityID, ...change.data })]);
    }
    await promisify(execFile)(process.execPath, ["--import", "tsx", "src/migrate.ts"], {
      cwd: fileURLToPath(new URL("../", import.meta.url)), timeout: 10_000
    });
    app = await buildApp({ logger: false });
    await app.listen(0, "127.0.0.1");
    baseURL = await app.getUrl();
    const auth = app.get(AuthService);
    issueAccessToken = (userID) => auth.issueAccessToken(userID);
  });

  after(async () => {
    if (app) await app.close();
    else if (pool) await pool.end();
  });

  async function post<T>(path: string, token: string, body: unknown, expectedStatus = 201, serverURL = baseURL): Promise<T> {
    const response = await fetch(new URL(path, serverURL), {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000)
    });
    const text = await response.text();
    assert.equal(response.status, expectedStatus, `${path}: ${text}`);
    return JSON.parse(text) as T;
  }

  async function account(): Promise<Account> {
    const result = await pool.query("INSERT INTO app_users (apple_subject) VALUES ($1) RETURNING id", [`integration-${randomUUID()}`]);
    const id = result.rows[0].id as string;
    return { id, devices: [await register(id, "client A"), await register(id, "client B")] };
  }

  async function register(userID: string, name: string): Promise<Device> {
    // Identity-provider verification is outside this suite. Bearer verification and
    // device registration use the production HTTP controllers and AuthService.
    const token = await issueAccessToken(userID);
    const result = await post<{ device: { id: string } }>("/v1/devices", token, { name, platform: "integration" });
    return { id: result.device.id, token };
  }

  const push = (device: Device, changes: SyncChange[]) => post<SyncResponse>("/v1/sync/push", device.token, { deviceID: device.id, changes });
  const pull = (device: Device, cursor = 0, limit = 500) => post<SyncResponse>("/v1/sync/pull", device.token, { deviceID: device.id, cursor, limit });
  const pushV2 = (device: Device, mutationID: string, changes: SyncChange[]) => post<SyncResponse>("/v1/sync/push", device.token, {
    deviceID: device.id, protocolVersion: 2, mutationID, changes
  });

  async function allEvents(device: Device, cursor = 0, limit = 2): Promise<SyncEvent[]> {
    const events: SyncEvent[] = [];
    for (let page = 0; page < 100; page++) {
      const response = await pull(device, cursor, limit);
      if (response.events.length === 0) {
        assert.equal(response.cursor, cursor);
        return events;
      }
      for (const event of response.events) {
        assert.ok(event.serverSeq > cursor, "Pull cursor must advance without repeats");
        cursor = event.serverSeq;
        events.push(event);
      }
      assert.equal(response.cursor, cursor);
    }
    assert.fail("Pull did not finish in 100 pages");
  }

  async function assertDeleted(userID: string, entityType: "space" | "tab", ids: string[]) {
    const table = entityType === "space" ? "spaces" : "tabs";
    const rows = await pool.query(`SELECT id FROM ${table} WHERE user_id = $1 AND id = ANY($2::text[]) AND deleted_at IS NULL`, [userID, ids]);
    assert.deepEqual(rows.rows, [], "No deleted entity may remain live in storage");
  }

  it("migrates v1 orphaned children without deleting children already moved to a live space", async () => {
    const a = await register(legacy.userID, "legacy client A");
    const b = await register(legacy.userID, "legacy client B");
    const stale = await push(a, [tab(legacy.orphan, legacy.liveSpace)]);
    assert.equal(stale.events[0].op, "delete", "A delayed move cannot rescue an orphan deleted by migration");
    await assertDeleted(legacy.userID, "tab", [legacy.orphan]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), [legacy.moved]);
  });

  it("rejects an upsert without data before any mutation", async () => {
    const { devices: [a] } = await account();
    await post("/v1/sync/push", a.token, {
      deviceID: a.id, changes: [space(randomUUID()), { entityType: "tab", entityID: randomUUID(), op: "upsert" }]
    }, 400);
    assert.deepEqual(await pull(a), { protocolVersion: 2, cursor: 0, events: [] });
  });

  it("keeps a batch deleted when an offline client replays stale titles, ranks and placement", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const ids = [randomUUID(), randomUUID(), randomUUID()];
    const changes = ids.map((tabID, index) => tab(tabID, spaceID, { rank: index }));
    const seeded = await push(a, [space(spaceID), ...changes]);
    const offlineSnapshot = await pull(b);
    assert.equal(offlineSnapshot.cursor, seeded.cursor);

    await push(a, ids.map((entityID) => deletion("tab", entityID)));
    const stale = await push(b, ids.map((tabID, index) => tab(tabID, spaceID, {
      title: "offline rename", rank: 100 - index, placement: "spacePinned"
    })));
    assert.deepEqual(stale.events.map((event) => [event.entityID, event.op]), ids.map((id) => [id, "delete"]));
    await assertDeleted(id, "tab", ids);

    const aEvents = await allEvents(a);
    const bEvents = await allEvents(b);
    assert.deepEqual(aEvents, bEvents, "Both devices must receive the same complete ordered log");
    assert.deepEqual(liveEntityIDs(aEvents, "tab"), []);
    assert.ok((await allEvents(b, offlineSnapshot.cursor)).every((event) => event.op === "delete"));
  });

  it("remembers deletion before creation and keeps repeated deletes idempotent", async () => {
    const { id, devices: [a, b] } = await account();
    const tabID = randomUUID();
    const spaceID = randomUUID();
    await push(a, [space(spaceID)]);
    const first = await push(a, [deletion("tab", tabID)]);
    // Treat the first committed response as lost; resend the identical request.
    const retry = await push(a, [deletion("tab", tabID)]);
    assert.deepEqual(retry.events, first.events, "A duplicate delete must return its original authoritative event");
    const stale = await push(b, [tab(tabID, spaceID)]);
    assert.deepEqual(stale.events, first.events);
    await assertDeleted(id, "tab", [tabID]);
    const deletes = (await allEvents(b)).filter((event) => event.entityID === tabID);
    assert.equal(deletes.length, 1, "Retries must not append redundant delete events");
  });

  it("makes deletion dominate a concurrent upsert regardless of request arrival order", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const ids = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
    await push(a, [space(spaceID), ...ids.map((id) => tab(id, spaceID))]);
    await Promise.all(ids.flatMap((tabID, index) => {
      const remove = () => push(a, [deletion("tab", tabID)]);
      const stale = () => push(b, [tab(tabID, spaceID, { title: "concurrent rename", rank: 500 + index })]);
      return index % 2 === 0 ? [remove(), stale()] : [stale(), remove()];
    }));
    await assertDeleted(id, "tab", ids);
    const events = await allEvents(b);
    assert.deepEqual(liveEntityIDs(events, "tab"), []);
    for (const tabID of ids) assert.equal(events.findLast((event) => event.entityID === tabID)?.op, "delete");
  });

  it("makes an explicit delete dominate its own batch's upsert and returns the current push highwater", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const tabID = randomUUID();
    await push(a, [space(spaceID), tab(tabID, spaceID)]);
    const deleted = await push(a, [deletion("tab", tabID), tab(tabID, spaceID, { title: "same-batch update" })]);
    const highwater = await push(a, [space(randomUUID())]);
    const stale = await push(b, [tab(tabID, spaceID)]);
    assert.equal(stale.events[0].serverSeq, deleted.events.find((event) => event.op === "delete")?.serverSeq);
    assert.equal(stale.cursor, highwater.cursor, "Returning an old tombstone must not move the push highwater backwards");
    await assertDeleted(id, "tab", [tabID]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), []);
  });

  it("cascades a space delete and rejects old or newly delivered children of that space", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const ids = [randomUUID(), randomUUID()];
    await push(a, [space(spaceID), ...ids.map((id) => tab(id, spaceID))]);
    const deleted = await push(a, [deletion("space", spaceID)]);
    for (const tabID of ids) assert.ok(deleted.events.some((event) => event.entityID === tabID && event.op === "delete"));
    const unknownChild = randomUUID();
    const stale = await push(b, [space(spaceID), ...[...ids, unknownChild].map((id) => tab(id, spaceID))]);
    assert.ok(stale.events.every((event) => event.op === "delete"));
    await assertDeleted(id, "space", [spaceID]);
    await assertDeleted(id, "tab", [...ids, unknownChild]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), []);
  });

  it("preserves a committed move out of a deleted space when its old placement arrives late", async () => {
    const { devices: [a, b] } = await account();
    const oldSpace = randomUUID();
    const newSpace = randomUUID();
    const tabID = randomUUID();
    await push(a, [space(oldSpace), space(newSpace), tab(tabID, oldSpace)]);
    const moved = await push(b, [tab(tabID, newSpace, { rank: 42, title: "Moved tab" })]);
    await push(a, [deletion("space", oldSpace)]);
    const stale = await push(a, [tab(tabID, oldSpace)]);
    assert.deepEqual(stale.events, moved.events, "The stale parent must not overwrite or delete an already moved live tab");
    const events = await allEvents(b);
    assert.deepEqual(liveEntityIDs(events, "tab"), [tabID]);
    assert.equal(events.findLast((event) => event.entityID === tabID)?.data.spaceID, newSpace);
  });

  it("preserves a move out in the same batch as parent deletion even when delete is listed first", async () => {
    const { id, devices: [a, b] } = await account();
    const oldSpace = randomUUID();
    const newSpace = randomUUID();
    const movedID = randomUUID();
    const orphanID = randomUUID();
    await push(a, [space(oldSpace), space(newSpace), tab(movedID, oldSpace)]);
    await push(a, [deletion("space", oldSpace), tab(movedID, newSpace), tab(orphanID, oldSpace)]);
    const events = await allEvents(b);
    assert.deepEqual(liveEntityIDs(events, "tab"), [movedID]);
    assert.equal(events.findLast((event) => event.entityID === movedID)?.data.spaceID, newSpace);
    await assertDeleted(id, "tab", [orphanID]);
  });

  it("remembers an unknown space deletion and rejects a child delivered before the stale parent", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const tabID = randomUUID();
    await push(a, [deletion("space", spaceID)]);
    const child = await push(b, [tab(tabID, spaceID)]);
    const parent = await push(b, [space(spaceID)]);
    assert.ok([...child.events, ...parent.events].every((event) => event.op === "delete"));
    await assertDeleted(id, "space", [spaceID]);
    await assertDeleted(id, "tab", [tabID]);
    const events = await allEvents(b);
    assert.deepEqual(liveEntityIDs(events, "space"), []);
    assert.deepEqual(liveEntityIDs(events, "tab"), []);
  });

  it("retains deletion across a backend process restart and a client retry after a lost response", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const tabID = randomUUID();
    await push(a, [space(spaceID), tab(tabID, spaceID)]);
    let server = await startServerProcess();
    let original: SyncResponse;
    try {
      original = await post<SyncResponse>("/v1/sync/push", a.token, {
        deviceID: a.id, changes: [deletion("tab", tabID)]
      }, 201, server.url);
    } finally {
      await server.stop();
    }
    server = await startServerProcess();
    try {
      const retry = await post<SyncResponse>("/v1/sync/push", a.token, {
        deviceID: a.id, changes: [deletion("tab", tabID)]
      }, 201, server.url);
      const stale = await post<SyncResponse>("/v1/sync/push", b.token, {
        deviceID: b.id, changes: [tab(tabID, spaceID)]
      }, 201, server.url);
      assert.deepEqual(retry.events, original.events);
      assert.deepEqual(stale.events, original.events);
    } finally {
      await server.stop();
    }
    await assertDeleted(id, "tab", [tabID]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), []);
  });

  it("isolates same entity IDs across users and rejects another account's device", async () => {
    const first = await account();
    const second = await account();
    const spaceID = randomUUID();
    const tabID = randomUUID();
    await push(first.devices[0], [space(spaceID), tab(tabID, spaceID), deletion("tab", tabID)]);
    const saved = await push(second.devices[0], [space(spaceID), tab(tabID, spaceID)]);
    assert.equal(saved.events.at(-1)?.op, "upsert");
    await post("/v1/sync/push", first.devices[0].token, { deviceID: second.devices[0].id, changes: [] }, 403);
    await post("/v1/sync/pull", first.devices[0].token, { deviceID: second.devices[0].id }, 403);
    assert.deepEqual(liveEntityIDs(await allEvents(first.devices[1]), "tab"), []);
    assert.deepEqual(liveEntityIDs(await allEvents(second.devices[1]), "tab"), [tabID]);
  });

  it("does not page past a lower sequence whose transaction has not committed", async () => {
    const { devices: [a, b] } = await account();
    const firstID = randomUUID();
    const secondID = randomUUID();
    const gate = await pool.connect();
    let firstRequest: Promise<SyncResponse> | undefined;
    let secondRequest: Promise<SyncResponse> | undefined;
    let secondResponse: SyncResponse | undefined;
    let heldResponse: SyncResponse | undefined;
    let secondFinishedWhileHeld = false;
    try {
      await gate.query("BEGIN");
      await gate.query("SELECT pg_advisory_xact_lock(1729, 2718)");
      await pool.query(`
        CREATE FUNCTION sync_test_hold_event() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.entity_id = TG_ARGV[0] THEN PERFORM pg_advisory_xact_lock(1729, 2718); END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER sync_test_hold_event AFTER INSERT ON sync_events
          FOR EACH ROW EXECUTE FUNCTION sync_test_hold_event('${firstID}');
      `);
      firstRequest = push(a, [space(firstID)]);
      await waitUntil(async () => (await blockedQueries(pool)) >= 1);
      secondRequest = push(b, [space(secondID)]).then((response) => {
        secondResponse = response;
        return response;
      });
      await waitUntil(async () => secondResponse !== undefined || (await blockedQueries(pool)) >= 2);
      secondFinishedWhileHeld = secondResponse !== undefined;
      heldResponse = await pull(b, 0, 1);
    } finally {
      await gate.query("ROLLBACK");
      gate.release();
      await Promise.allSettled([firstRequest, secondRequest]);
      await pool.query("DROP TRIGGER IF EXISTS sync_test_hold_event ON sync_events; DROP FUNCTION IF EXISTS sync_test_hold_event()");
    }
    assert.equal(secondFinishedWhileHeld, false, "Later account events must wait until earlier events commit");
    assert.deepEqual(heldResponse, { protocolVersion: 2, cursor: 0, events: [] }, "Pull must not advance over an uncommitted event");
    assert.deepEqual((await allEvents(b, 0, 1)).map((event) => event.entityID), [firstID, secondID]);
  });

  it("advertises v2 on pull and rejects incomplete or unsupported mutation envelopes", async () => {
    const { devices: [a] } = await account();
    assert.equal((await pull(a)).protocolVersion, 2);
    for (const envelope of [
      { protocolVersion: 2 }, { mutationID: randomUUID() },
      { protocolVersion: 1, mutationID: randomUUID() }, { protocolVersion: 3, mutationID: randomUUID() },
      { protocolVersion: 2, mutationID: "invalid" }
    ]) {
      await post("/v1/sync/push", a.token, { deviceID: a.id, changes: [space(randomUUID())], ...envelope }, 400);
    }
    assert.deepEqual((await pull(a)).events, []);
  });

  it("replays a lost v2 acknowledgement after a newer write without overwriting it", async () => {
    const { id, devices: [a, b] } = await account();
    const entityID = randomUUID();
    const mutationID = randomUUID();
    const original = await pushV2(a, mutationID, [space(entityID)]);
    assert.equal(original.protocolVersion, 2);
    assert.equal(original.mutationID, mutationID);
    const newerChange = space(entityID);
    newerChange.data!.title = "Newer remote title";
    const newer = await push(b, [newerChange]);
    const before = await allEvents(b);
    const lastSeen = await pool.query("SELECT last_seen_at FROM devices WHERE id = $1", [a.id]);
    const retry = await pushV2(a, mutationID, [space(entityID)]);
    assert.deepEqual(retry, original);
    assert.ok(retry.cursor < newer.cursor, "A receipt must preserve its original cursor");
    assert.deepEqual(await allEvents(b), before);
    assert.deepEqual((await pool.query("SELECT last_seen_at FROM devices WHERE id = $1", [a.id])).rows, lastSeen.rows);
    assert.equal((await pool.query("SELECT title FROM spaces WHERE user_id = $1 AND id = $2", [id, entityID])).rows[0].title, "Newer remote title");
  });

  it("serializes concurrent duplicate v2 deliveries to one mutation and one receipt", async () => {
    const { id, devices: [a, b] } = await account();
    const mutationID = randomUUID();
    const changes = [space(randomUUID())];
    const results = await Promise.all([pushV2(a, mutationID, changes), pushV2(b, mutationID, changes), pushV2(a, mutationID, changes)]);
    assert.deepEqual(results[0], results[1]);
    assert.deepEqual(results[1], results[2]);
    assert.equal((await allEvents(a)).length, 1);
    assert.equal((await pool.query("SELECT count(*) FROM sync_mutation_receipts WHERE user_id = $1", [id])).rows[0].count, "1");
  });

  it("rejects mutation ID reuse with different parsed content and performs no writes", async () => {
    const { id, devices: [a] } = await account();
    const mutationID = randomUUID();
    const changes = [space(randomUUID()), space(randomUUID())];
    const original = await pushV2(a, mutationID, changes);
    await post("/v1/sync/push", a.token, {
      deviceID: a.id, protocolVersion: 2, mutationID, changes: [space(randomUUID())]
    }, 409);
    await post("/v1/sync/push", a.token, {
      deviceID: a.id, protocolVersion: 2, mutationID, changes: [...changes].reverse()
    }, 409);
    assert.deepEqual((await allEvents(a)).map((event) => event.serverSeq), original.events.map((event) => event.serverSeq));
    assert.equal((await pool.query("SELECT count(*) FROM sync_mutation_receipts WHERE user_id = $1", [id])).rows[0].count, "1");
  });

  it("binds receipts to the account, allows device rotation, and canonicalizes parsed key order/defaults", async () => {
    const first = await account();
    const second = await account();
    const mutationID = randomUUID();
    const entityID = randomUUID();
    const original = await pushV2(first.devices[0], mutationID, [space(entityID)]);
    const rotated = await register(first.id, "replacement after relogin");
    const retry = await post<SyncResponse>("/v1/sync/push", rotated.token, {
      changes: [{ op: "upsert", data: { rank: 0, systemImageName: "globe", title: "Integration space" }, entityID, entityType: "space" }],
      mutationID, protocolVersion: 2, deviceID: rotated.id
    });
    assert.deepEqual(retry, original, "Default false and JSON key order do not change parsed mutation identity");
    const other = await pushV2(second.devices[0], mutationID, [space(randomUUID())]);
    assert.notDeepEqual(other.events, original.events);
    assert.equal((await allEvents(first.devices[1])).length, 1);
    assert.equal((await allEvents(second.devices[1])).length, 1);
  });

  it("rolls back entity changes, event log and receipt together when receipt storage fails", async () => {
    const { id, devices: [a] } = await account();
    const mutationID = randomUUID();
    const entityID = randomUUID();
    await pool.query(`
      CREATE FUNCTION sync_test_reject_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'injected receipt failure'; END $$;
      CREATE TRIGGER sync_test_reject_receipt BEFORE INSERT ON sync_mutation_receipts
      FOR EACH ROW EXECUTE FUNCTION sync_test_reject_receipt();
    `);
    try {
      await post("/v1/sync/push", a.token, { deviceID: a.id, protocolVersion: 2, mutationID, changes: [space(entityID)] }, 500);
    } finally {
      await pool.query("DROP TRIGGER sync_test_reject_receipt ON sync_mutation_receipts; DROP FUNCTION sync_test_reject_receipt()");
    }
    assert.deepEqual((await pull(a)).events, []);
    assert.equal((await pool.query("SELECT count(*) FROM spaces WHERE user_id = $1", [id])).rows[0].count, "0");
    assert.equal((await pool.query("SELECT count(*) FROM sync_mutation_receipts WHERE user_id = $1", [id])).rows[0].count, "0");
    assert.equal((await pushV2(a, mutationID, [space(entityID)])).events.length, 1);
  });

  it("retains exact v2 receipt across a backend process restart after later deletion", async () => {
    const { devices: [a, b] } = await account();
    const mutationID = randomUUID();
    const entityID = randomUUID();
    const body = { deviceID: a.id, protocolVersion: 2, mutationID, changes: [space(entityID)] };
    let server = await startServerProcess();
    let original: SyncResponse;
    try {
      original = await post<SyncResponse>("/v1/sync/push", a.token, body, 201, server.url);
    } finally { await server.stop(); }
    await push(b, [deletion("space", entityID)]);
    const before = await allEvents(b);
    server = await startServerProcess();
    try {
      const retry = await post<SyncResponse>("/v1/sync/push", a.token, body, 201, server.url);
      assert.deepEqual(retry, original);
    } finally { await server.stop(); }
    assert.deepEqual(await allEvents(b), before);
    assert.deepEqual(liveEntityIDs(before, "space"), []);
  });

  it("persists pinned home URLs through pull and receipts while preserving legacy omission and explicit clearing", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const tabID = randomUUID();
    const mutationID = randomUUID();
    const changes = [space(spaceID), tab(tabID, spaceID, {
      placement: "spacePinned", urlString: "https://example.test/live", pinnedURLString: "https://example.test/home"
    })];
    const first = await pushV2(a, mutationID, changes);
    assert.equal(first.events.at(-1)?.data.pinnedURLString, "https://example.test/home");
    assert.equal((await allEvents(b)).at(-1)?.data.pinnedURLString, "https://example.test/home");
    const legacyUpdate = await push(b, [tab(tabID, spaceID, { placement: "spacePinned", urlString: "https://example.test/next" })]);
    assert.equal(legacyUpdate.events[0].data.pinnedURLString, "https://example.test/home");
    assert.deepEqual(await pushV2(a, mutationID, changes), first);
    assert.equal((await pool.query("SELECT url_string, pinned_url_string FROM tabs WHERE user_id = $1 AND id = $2", [id, tabID])).rows[0].url_string, "https://example.test/next");
    const cleared = await pushV2(a, randomUUID(), [tab(tabID, spaceID, { placement: "spacePinned", pinnedURLString: null })]);
    assert.equal(cleared.events[0].data.pinnedURLString, null);
    const omittedAfterClear = await push(b, [tab(tabID, spaceID, { placement: "spacePinned" })]);
    assert.equal(omittedAfterClear.events[0].data.pinnedURLString, null);
    const newLegacyTab = await push(b, [tab(randomUUID(), spaceID, { placement: "spacePinned", urlString: "https://example.test/initial" })]);
    assert.equal(newLegacyTab.events[0].data.pinnedURLString, "https://example.test/initial");
    await pushV2(a, randomUUID(), [tab(tabID, spaceID, { placement: "spacePinned", pinnedURLString: "https://example.test/home" })]);
    const unpinned = await pushV2(a, randomUUID(), [tab(tabID, spaceID, { placement: "temporary", pinnedURLString: "https://ignored.example" })]);
    assert.equal(unpinned.events[0].data.pinnedURLString, null);
    assert.equal((await pool.query("SELECT pinned_url_string FROM tabs WHERE user_id = $1 AND id = $2", [id, tabID])).rows[0].pinned_url_string, null);
  });

  it("keeps global Favorites after deleting their historical space while explicit tab deletion remains terminal", async () => {
    const { id, devices: [a, b] } = await account();
    const spaceID = randomUUID();
    const favoriteID = randomUUID();
    const childID = randomUUID();
    await pushV2(a, randomUUID(), [space(spaceID), tab(favoriteID, spaceID, { placement: "app" }), tab(childID, spaceID)]);
    const deletedSpace = await pushV2(a, randomUUID(), [deletion("space", spaceID)]);
    assert.ok(deletedSpace.events.some((event) => event.entityID === childID && event.op === "delete"));
    assert.equal(deletedSpace.events.some((event) => event.entityID === favoriteID), false);
    await assertDeleted(id, "space", [spaceID]);
    await assertDeleted(id, "tab", [childID]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), [favoriteID]);

    const retryID = randomUUID();
    const staleFavorite = [tab(favoriteID, spaceID, { placement: "app", title: "Favorite after space deletion" })];
    const updated = await pushV2(b, retryID, staleFavorite);
    assert.equal(updated.events[0].op, "upsert");
    assert.equal(updated.events[0].data.placement, "app");
    assert.deepEqual(await pushV2(b, retryID, staleFavorite), updated);
    await push(a, [deletion("space", spaceID)]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), [favoriteID]);
    const storedFavorite = await pool.query("SELECT title, deleted_at FROM tabs WHERE user_id = $1 AND id = $2", [id, favoriteID]);
    assert.equal(storedFavorite.rows[0].title, "Favorite after space deletion");
    assert.equal(storedFavorite.rows[0].deleted_at, null);

    const explicitDelete = await pushV2(a, randomUUID(), [deletion("tab", favoriteID)]);
    const staleAfterDelete = await pushV2(b, randomUUID(), staleFavorite);
    assert.deepEqual(staleAfterDelete.events, explicitDelete.events);
    await assertDeleted(id, "tab", [favoriteID]);
    assert.deepEqual(liveEntityIDs(await allEvents(b), "tab"), []);
  });
});

function space(entityID: string): SyncChange {
  return {
    entityType: "space", entityID, op: "upsert",
    data: { title: "Integration space", systemImageName: "globe", rank: 0, isPinnedSectionCollapsed: false }
  };
}

function tab(entityID: string, spaceID: string, overrides: Record<string, unknown> = {}): SyncChange {
  return {
    entityType: "tab", entityID, op: "upsert",
    data: { spaceID, placement: "temporary", rank: 0, urlString: "https://example.test/", title: "Integration tab", ...overrides }
  };
}

function deletion(entityType: "space" | "tab", entityID: string): SyncChange {
  return { entityType, entityID, op: "delete" };
}

function liveEntityIDs(events: SyncEvent[], entityType: "space" | "tab"): string[] {
  const entities = new Set<string>();
  for (const event of events.filter((event) => event.entityType === entityType)) {
    if (event.op === "delete") entities.delete(event.entityID);
    else entities.add(event.entityID);
  }
  return [...entities].sort();
}

async function blockedQueries(pool: pg.Pool): Promise<number> {
  const result = await pool.query("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'");
  return Number(result.rows[0].count);
}

async function waitUntil(predicate: () => Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(20);
  }
  assert.fail("Database did not reach the expected synchronization point");
}

async function startServerProcess(): Promise<{ url: string; stop: () => Promise<void> }> {
  const child = spawn(process.execPath, ["--import", "tsx", "--input-type=module", "--eval", `
    const { buildApp } = await import("./src/app.ts");
    const app = await buildApp({ logger: false });
    await app.listen(0, "127.0.0.1");
    process.stdout.write("SYNC_TEST_READY " + await app.getUrl() + "\\n");
    process.once("SIGTERM", async () => { await app.close(); process.exit(0); });
  `], { cwd: fileURLToPath(new URL("../", import.meta.url)), stdio: ["ignore", "pipe", "pipe"] });
  let errors = "";
  child.stderr.on("data", (data: Buffer) => { errors += data.toString(); });
  const lines = createInterface({ input: child.stdout });
  const url = await new Promise<string>((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`Backend startup timed out: ${errors}`)); }, 10_000);
    child.once("error", (error) => { clearTimeout(timeout); reject(error); });
    child.once("exit", (code) => { clearTimeout(timeout); reject(new Error(`Backend exited during startup (${code}): ${errors}`)); });
    lines.on("line", (line: string) => {
      if (line.startsWith("SYNC_TEST_READY ")) {
        clearTimeout(timeout);
        resolve(line.slice("SYNC_TEST_READY ".length));
      }
    });
  });
  return { url, stop: async () => {
    if (child.exitCode !== null || child.signalCode !== null) {
      lines.close();
      assert.fail(`Backend exited before shutdown (${child.exitCode ?? child.signalCode}): ${errors}`);
    }
    const closed = once(child, "close");
    child.kill("SIGTERM");
    const timeout = setTimeout(() => { child.kill("SIGKILL"); }, 5_000);
    try {
      const [code] = await closed;
      assert.equal(code, 0, `Backend shutdown failed: ${errors}`);
    } finally {
      clearTimeout(timeout);
      lines.close();
    }
  } };
}
