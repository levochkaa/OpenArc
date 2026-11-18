import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { writeFile } from "node:fs/promises";
import { createServer, request, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { gunzipSync } from "node:zlib";
import pg from "pg";
import { issueAccessToken, migrate, startSyncServer } from "./sync-server.js";

// This driver is test-only. Authentication, device registration, migrations and
// every sync request use the production server. Fault controls live separately.
const [fixturePath, reportPath] = process.argv.slice(2);
assert.ok(fixturePath && reportPath, "Expected fixture and completion-report paths");
const suite = process.env.OPENARC_SYNC_FIXTURE_SUITE ?? "desktop";
assert.ok(suite === "desktop" || suite === "mobile", "Unknown Swift sync fixture suite");
const databaseURL = new URL(process.env.OPENARC_SYNC_TEST_DATABASE_URL ?? "");
assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(databaseURL.hostname));
assert.match(databaseURL.pathname, /^\/openarc_sync_test_[a-z0-9_]+$/);
const pool = new pg.Pool({ connectionString: databaseURL.toString(), max: 10 });
const schema = await pool.query("SELECT to_regclass('public.app_users') AS table_name");
assert.equal(schema.rows[0].table_name, null, "Swift HTTP tests require a fresh empty database");
await migrate(databaseURL.toString());
const server = await startSyncServer(databaseURL.toString());
const upstream = server.url;
const controlToken = randomUUID();

type Mode = "drop" | "hold";
type Attempt = {
  deviceID: string; mutationID: string; protocolVersion: number; digest: string; compressed: boolean; status: number;
  outcomeStatuses?: string[]; outcomeReasons?: string[]; hasAutoArchive?: boolean;
};
type ObservedPull = {
  deviceID: string; protocolVersion: number; cursor: number; status: number;
  eventCount?: number; responseCursor?: number;
};
type ExpiryAttempt = {
  deviceID: string; mutationID: string; digest: string; status: number;
  response: { outcomes?: { status: string }[]; events?: { data?: { autoArchive?: unknown } }[] };
};
type HeldResponse = { response: ServerResponse; status: number; headers: IncomingMessage["headers"]; data: Buffer };
const modes = new Map<string, Mode>();
const held = new Map<string, HeldResponse>();
const pullModes = new Map<string, { cursor: number; protocolVersion: number }>();
const heldPulls = new Map<string, HeldResponse>();
const attempts: Attempt[] = [];
const observedPulls: ObservedPull[] = [];
const expiryAttempts: ExpiryAttempt[] = [];
const completed = new Set<string>();
const legacyScenarios = new Set(["offline-delete", "lost-ack", "edit-during-ack", "global-favorite"]);
const legacyAuthorizations = new Set<string>();
const semanticAuthorizations = new Set<string>();
const capabilityOverrides = new Map<string, number[]>();
const adoptionScenario = "folder-adoption-paged";
const expiryScenario = "expiry-recovery";
const expiryQueueScenario = "expiry-queue";
const expiryLimitScenario = "expiry-response-limit";
const desktopArchiveScenario = "desktop-archive-restore";
const desktopAutomaticScenario = "desktop-auto-archive";
const desktopConfirmedCloseScenario = "desktop-confirmed-close";
const desktopLocalAutomaticScenario = "desktop-local-auto-archive";
const desktopPersistentCloseScenario = "desktop-persistent-close";
const desktopPersistentRemovalScenario = "desktop-persistent-removal";
const folderScenarios = new Set([
  "folder-roundtrip", "folder-race", "folder-lost-ack", adoptionScenario,
  "folder-device-rotation", "folder-pending-delete", "folder-activity-replay"
]);
const mobileAutomaticScenario = "mobile-v5-automatic-archive";
const mobileScenarios = new Set([
  "mobile-v4-roundtrip", "mobile-v4-recovery", "mobile-v4-group-replay", "mobile-v4-cross-space",
  mobileAutomaticScenario
]);
const desktopScenarios = [
  ...legacyScenarios, "semantic-move-first", "semantic-patch-first",
  "coordinator-move-first", "coordinator-patch-first", "coordinator-lost-ack", "coordinator-delete-pending",
  "coordinator-space-delete-move", "explicit-local-first", "explicit-remote-first", "explicit-group-replay",
  "persistence-retry", "pending-parent-delete", "pending-navigation", ...folderScenarios,
  expiryScenario, expiryQueueScenario, expiryLimitScenario, desktopArchiveScenario, desktopAutomaticScenario,
  desktopConfirmedCloseScenario, desktopLocalAutomaticScenario, desktopPersistentCloseScenario,
  desktopPersistentRemovalScenario
];
const scenarios = suite === "mobile" ? [...mobileScenarios] : desktopScenarios;

async function body(message: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of message) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
      .map(([key, entry]) => [key, canonical(entry)]));
  }
  return value;
}

function sendHeld(value: HeldResponse): void {
  value.response.writeHead(value.status, value.headers);
  value.response.end(value.data);
}

const proxy = createServer((incoming, outgoing) => {
  void (async () => {
    const path = new URL(incoming.url ?? "/", upstream).pathname;
    if (suite === "mobile" && incoming.method === "GET"
      && ["/mobile-test-page", "/mobile-test-second"].includes(path)) {
      outgoing.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      outgoing.end(path === "/mobile-test-page"
        ? "<!doctype html><html><head><title>Mobile sync fixture</title></head><body>Mobile sync fixture page<a id='next' href='/mobile-test-second'>Next page</a></body></html>"
        : "<!doctype html><html><head><title>Mobile sync second</title></head><body>Mobile sync second page</body></html>");
      return;
    }
    const bytes = await body(incoming);
    const compressed = incoming.headers["content-encoding"] === "gzip";
    const authorization = incoming.headers.authorization ?? "";
    const push = path === "/v1/sync/push"
      ? JSON.parse((compressed ? gunzipSync(bytes) : bytes).toString()) as {
        deviceID: string; mutationID: string; protocolVersion?: number; changes?: unknown[]; operations?: unknown[];
      } : undefined;
    const pull = path === "/v1/sync/pull"
      ? JSON.parse((compressed ? gunzipSync(bytes) : bytes).toString()) as {
        deviceID: string; protocolVersion?: number; cursor: number;
      } : undefined;
    const legacyPull = !!pull && legacyAuthorizations.has(authorization);
    const semanticPull = !!pull && semanticAuthorizations.has(authorization);
    const capabilityOverride = pull ? capabilityOverrides.get(authorization) : undefined;
    const headers = { ...incoming.headers, host: new URL(upstream).host };
    // Only the capability shim needs plaintext; other accounts retain real
    // production response compression negotiated by URLSession.
    if (legacyPull || semanticPull || capabilityOverride) headers["accept-encoding"] = "identity";
    const forwarded = request(new URL(incoming.url ?? "/", upstream), {
      method: incoming.method, headers, timeout: 15_000
    });
    forwarded.on("timeout", () => forwarded.destroy(new Error("Fixture upstream timeout")));
    forwarded.on("error", (error) => outgoing.destroy(error));
    forwarded.end(bytes);
    const [received] = await once(forwarded, "response") as [IncomingMessage];
    let data = await body(received);
    const responseHeaders = { ...received.headers };
    const status = received.statusCode ?? 502;
    if ((legacyPull || semanticPull || capabilityOverride) && status >= 200 && status < 300) {
      // Keep the original v2 durability cases exercising an older server's
      // capability response. All writes still reach the unchanged production API.
      const result = JSON.parse(data.toString()) as { supportedPushVersions?: number[] };
      if (capabilityOverride) result.supportedPushVersions = capabilityOverride;
      else if (legacyPull) delete result.supportedPushVersions;
      else result.supportedPushVersions = [2, 3];
      data = Buffer.from(JSON.stringify(result));
      delete responseHeaders["transfer-encoding"];
      responseHeaders["content-length"] = String(data.length);
    }
    if (pull) {
      const observation: ObservedPull = {
        deviceID: pull.deviceID, protocolVersion: pull.protocolVersion ?? 2, cursor: pull.cursor, status
      };
      if (status >= 200 && status < 300) {
        const decoded = JSON.parse((responseHeaders["content-encoding"] === "gzip" ? gunzipSync(data) : data).toString()) as {
          events: unknown[]; cursor: number;
        };
        observation.eventCount = decoded.events.length;
        observation.responseCursor = decoded.cursor;
      }
      observedPulls.push(observation);
    }
    if (push) {
      // Include v4 tombstone replays in the recorded outcome evidence.
      const result = (push.protocolVersion === 4 || push.protocolVersion === 5) && status >= 200 && status < 300
        ? JSON.parse((responseHeaders["content-encoding"] === "gzip" ? gunzipSync(data) : data).toString()) as {
          outcomes: { status: string; reason?: string }[]; events: { data?: { autoArchive?: unknown } }[];
        } : undefined;
      attempts.push({
        deviceID: push.deviceID, mutationID: push.mutationID,
        protocolVersion: push.protocolVersion ?? 1,
        digest: createHash("sha256").update(JSON.stringify(canonical({
          protocolVersion: push.protocolVersion, changes: push.changes, operations: push.operations
        }))).digest("hex"),
        compressed, status,
        ...(result ? {
          outcomeStatuses: result.outcomes.map((outcome) => outcome.status),
          outcomeReasons: result.outcomes.flatMap((outcome) => outcome.reason ? [outcome.reason] : []),
          hasAutoArchive: result.events.some((event) => !!event.data?.autoArchive)
        } : {})
      });
    }
    const mode = push ? modes.get(push.deviceID) : undefined;
    if (push && status >= 200 && status < 300 && mode === "drop") {
      // The entire upstream response was received: its transaction has committed.
      outgoing.destroy();
    } else if (push && status >= 200 && status < 300 && mode === "hold") {
      modes.delete(push.deviceID);
      assert.ok(!held.has(push.deviceID), "Only one ACK may be held per device");
      held.set(push.deviceID, { response: outgoing, status, headers: responseHeaders, data });
    } else if (pull && status >= 200 && status < 300
      && pullModes.get(pull.deviceID)?.protocolVersion === pull.protocolVersion
      && pullModes.get(pull.deviceID)?.cursor === pull.cursor) {
      // Hold after the real response completes, including the device bootstrap
      // transaction. The client has not received or persisted this page yet.
      pullModes.delete(pull.deviceID);
      assert.ok(!heldPulls.has(pull.deviceID), "Only one pull may be held per device");
      heldPulls.set(pull.deviceID, { response: outgoing, status, headers: responseHeaders, data });
    } else {
      outgoing.writeHead(status, responseHeaders);
      outgoing.end(data);
    }
  })().catch((error: unknown) => {
    console.error(error);
    outgoing.destroy(error instanceof Error ? error : undefined);
  });
});
proxy.listen(0, "127.0.0.1");
await once(proxy, "listening");
const baseURL = `http://127.0.0.1:${(proxy.address() as AddressInfo).port}`;

type Device = { deviceID: string; userID: string; accessToken: string };
type Account = { scenario: string; userID: string; devices: Device[] };
const accounts: Account[] = [];

async function registerDevice(userID: string, accessToken: string, name: string): Promise<Device> {
  const response = await fetch(new URL("/v1/devices", baseURL), {
    method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ name, platform: "Swift HTTP integration" }), signal: AbortSignal.timeout(10_000)
  });
  assert.equal(response.status, 201);
  const device = await response.json() as { device: { id: string } };
  return { deviceID: device.device.id, userID, accessToken };
}

for (const scenario of scenarios) {
  const result = await pool.query("INSERT INTO app_users (apple_subject) VALUES ($1) RETURNING id", [`swift-${randomUUID()}`]);
  const userID = result.rows[0].id as string;
  const accessToken = await issueAccessToken(userID);
  if (legacyScenarios.has(scenario)) legacyAuthorizations.add(`Bearer ${accessToken}`);
  else if (!folderScenarios.has(scenario) && !mobileScenarios.has(scenario)
    && scenario !== expiryScenario && scenario !== expiryQueueScenario && scenario !== expiryLimitScenario
    && scenario !== desktopArchiveScenario && scenario !== desktopAutomaticScenario
    && scenario !== desktopConfirmedCloseScenario && scenario !== desktopLocalAutomaticScenario
    && scenario !== desktopPersistentCloseScenario && scenario !== desktopPersistentRemovalScenario) {
    semanticAuthorizations.add(`Bearer ${accessToken}`);
  }
  if (scenario === adoptionScenario) capabilityOverrides.set(`Bearer ${accessToken}`, [2, 3]);
  else if (folderScenarios.has(scenario) || (mobileScenarios.has(scenario) && scenario !== mobileAutomaticScenario)) {
    // These existing cases deliberately retain their v4 coverage. Only the
    // isolated recovery scenario enables the new recovery bootstrap reader.
    capabilityOverrides.set(`Bearer ${accessToken}`, [2, 3, 4]);
  }
  if (scenario === expiryScenario) capabilityOverrides.set(`Bearer ${accessToken}`, [2, 3, 4]);
  const devices: Device[] = [];
  for (const name of ["Swift A", "Swift B"]) {
    devices.push(await registerDevice(userID, accessToken, name));
  }
  accounts.push({ scenario, userID, devices });
}

async function inspect(userID: string) {
  assert.ok(accounts.some((account) => account.userID === userID));
  const [events, receipts, tabs, folders] = await Promise.all([
    pool.query("SELECT count(*)::int AS count FROM sync_events WHERE user_id = $1", [userID]),
    pool.query("SELECT count(*)::int AS count FROM sync_mutation_receipts WHERE user_id = $1", [userID]),
    pool.query(`
      SELECT t.id, t.rank, t.space_id AS "spaceID", t.placement, t.url_string AS "urlString",
        t.user_title_override AS title, t.pinned_folder_id AS "pinnedFolderID",
        t.last_activity_at AS "lastActivityAt", t.deleted_at IS NOT NULL AS deleted,
        EXISTS (SELECT 1 FROM sync_tombstones s
          WHERE s.user_id = t.user_id AND s.entity_type = 'tab' AND s.entity_id = t.id) AS tombstoned
      FROM tabs t WHERE t.user_id = $1 ORDER BY t.rank, t.id
    `, [userID]),
    pool.query(`SELECT id, space_id AS "spaceID", parent_folder_id AS "parentFolderID", title,
      system_image_name AS "systemImageName", rank, deleted_at IS NOT NULL AS deleted
      FROM folders WHERE user_id = $1 ORDER BY rank, id`, [userID])
  ]);
  const deviceIDs = new Set(accounts.find((account) => account.userID === userID)!.devices.map((device) => device.deviceID));
  return {
    eventCount: events.rows[0].count, receiptCount: receipts.rows[0].count, tabs: tabs.rows, folders: folders.rows,
    attempts: attempts.filter((attempt) => deviceIDs.has(attempt.deviceID)),
    heldDeviceIDs: [...held.keys()],
    observedPulls: observedPulls.filter((pull) => deviceIDs.has(pull.deviceID)),
    expiryAttempts: expiryAttempts.filter((attempt) => deviceIDs.has(attempt.deviceID)),
    heldPullDeviceIDs: [...heldPulls.keys()].filter((deviceID) => deviceIDs.has(deviceID))
  };
}

const control = createServer((incoming, outgoing) => {
  void (async () => {
    if (incoming.method !== "POST" || incoming.url !== "/control") {
      outgoing.writeHead(404);
      outgoing.end();
      return;
    }
    if (incoming.headers.authorization !== `Bearer ${controlToken}`) {
      // Never include the expected or supplied credentials in assertion logs.
      outgoing.writeHead(401, { "content-type": "application/json" });
      outgoing.end(JSON.stringify({ error: "Fixture authorization required" }));
      return;
    }
    const command = JSON.parse((await body(incoming)).toString()) as {
      action: string; deviceID?: string; userID?: string; scenario?: string;
      cursor?: number; versions?: number[]; protocolVersion?: number;
      mutationID?: string; tabID?: string; expectedServerSeq?: number; inactiveForSeconds?: number;
    };
    let result: unknown = {};
    if (command.action === "fixture") {
      result = { baseURL, controlURL, controlToken, accounts };
    } else if (command.action === "drop" || command.action === "hold") {
      assert.ok(command.deviceID && accounts.some((account) => account.devices.some((device) => device.deviceID === command.deviceID)));
      modes.set(command.deviceID, command.action);
    } else if (command.action === "release") {
      assert.ok(command.deviceID);
      modes.delete(command.deviceID);
      const response = held.get(command.deviceID);
      held.delete(command.deviceID);
      if (response) sendHeld(response);
    } else if (command.action === "holdpull") {
      assert.ok(command.deviceID && accounts.some((account) => account.devices.some((device) => device.deviceID === command.deviceID)));
      assert.ok(Number.isSafeInteger(command.cursor) && command.cursor! >= 0);
      const protocolVersion = command.protocolVersion ?? 4;
      assert.ok(protocolVersion === 4 || protocolVersion === 5);
      assert.ok(!heldPulls.has(command.deviceID) && !pullModes.has(command.deviceID), "A pull is already armed or held");
      pullModes.set(command.deviceID, { cursor: command.cursor!, protocolVersion });
    } else if (command.action === "releasepull") {
      assert.ok(command.deviceID);
      pullModes.delete(command.deviceID);
      const response = heldPulls.get(command.deviceID);
      heldPulls.delete(command.deviceID);
      if (response) sendHeld(response);
    } else if (command.action === "setcapabilities") {
      const account = accounts.find((account) => account.userID === command.userID);
      assert.ok(account?.scenario === adoptionScenario || account?.scenario === expiryScenario || account?.scenario === expiryQueueScenario,
        "Capability transitions belong to isolated upgrade scenarios");
      const allowed = account.scenario === adoptionScenario ? ["[2,3]", "[2,3,4]"] : ["[2,3,4]", "[2,3,4,5]"];
      assert.ok(allowed.includes(JSON.stringify(command.versions)));
      for (const device of account.devices) {
        capabilityOverrides.set(`Bearer ${device.accessToken}`, command.versions!);
      }
    } else if (command.action === "expire") {
      const account = accounts.find((account) => account.userID === command.userID);
      assert.ok(account?.scenario === expiryScenario, "Expiry controls belong to their isolated scenario");
      const device = account.devices.find((candidate) => candidate.deviceID === command.deviceID);
      assert.ok(device && command.mutationID && command.tabID);
      assert.ok(Number.isSafeInteger(command.expectedServerSeq) && command.expectedServerSeq! > 0);
      assert.ok([43200, 86400, 259200, 604800, 2592000].includes(command.inactiveForSeconds!));
      const payload = {
        protocolVersion: 5, mutationID: command.mutationID, deviceID: device.deviceID,
        operations: [{ kind: "expire", entityType: "tab", entityID: command.tabID,
          expectedServerSeq: command.expectedServerSeq, inactiveForSeconds: command.inactiveForSeconds }]
      };
      // Use the real controller/authentication/transaction, independently of
      // Swift ACK fault arms. No fixture SQL mutates tabs or manufactures events.
      const response = await fetch(new URL("/v1/sync/push", upstream), {
        method: "POST", headers: { authorization: `Bearer ${device.accessToken}`, "content-type": "application/json" },
        body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000)
      });
      const decoded = await response.json() as ExpiryAttempt["response"];
      expiryAttempts.push({
        deviceID: device.deviceID, mutationID: command.mutationID, status: response.status, response: decoded,
        digest: createHash("sha256").update(JSON.stringify(canonical({
          protocolVersion: payload.protocolVersion, operations: payload.operations
        }))).digest("hex")
      });
      result = { status: response.status, response: decoded };
    } else if (command.action === "rotate") {
      const account = accounts.find((account) => account.userID === command.userID);
      assert.ok(account?.scenario === "folder-device-rotation" || account?.scenario === expiryQueueScenario,
        "Device rotation belongs to isolated rebootstrap scenarios");
      const device = await registerDevice(account.userID, account.devices[0].accessToken, "Swift rotated device");
      account.devices.push(device);
      result = device;
    } else if (command.action === "inspect") {
      assert.ok(command.userID);
      result = await inspect(command.userID);
    } else if (command.action === "complete") {
      assert.ok(command.scenario && accounts.some((account) => account.scenario === command.scenario));
      const account = accounts.find((account) => account.scenario === command.scenario)!;
      const deviceIDs = new Set(account.devices.map((device) => device.deviceID));
      const scenarioAttempts = attempts.filter((attempt) => deviceIDs.has(attempt.deviceID));
      assert.ok(scenarioAttempts.length > 0, "Completed scenario must send production sync mutations");
      if (account.scenario === mobileAutomaticScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4, 5, 6].includes(attempt.protocolVersion)));
        assert.ok(scenarioAttempts.some((attempt) => attempt.protocolVersion === 5 && attempt.status === 201
          && attempt.outcomeStatuses?.includes("applied") && attempt.hasAutoArchive),
        "The mobile scheduler must commit actual v5 expiry with recovery");
        for (const device of account.devices) {
          assert.ok(scenarioAttempts.some((attempt) => attempt.deviceID === device.deviceID
            && attempt.protocolVersion === 4 && attempt.status === 201),
          "Both mobile scheduler devices must commit ordinary v4 changes");
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both mobile scheduler devices must bootstrap recovery through production v5 pulls");
        }
      } else if (mobileScenarios.has(account.scenario)) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4].includes(attempt.protocolVersion)),
          "Mobile scenarios allow initial v2/v3 bootstrap before v4 adoption");
        for (const device of account.devices) {
          assert.ok(scenarioAttempts.some((attempt) => attempt.deviceID === device.deviceID
            && attempt.protocolVersion === 4 && attempt.status === 201),
          "Both mobile scenario devices must commit production v4 mutations");
        }
      } else if (account.scenario === desktopLocalAutomaticScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4].includes(attempt.protocolVersion)),
          "Local expiry must finish before ordinary sync adoption; no conditional expiry is submitted");
        const seeds = scenarioAttempts.filter((attempt) => attempt.protocolVersion === 2 && attempt.status === 201);
        assert.ok(seeds.some((receipt) => seeds.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest).length >= 2),
        "Adoption must replay the exact surviving-tab seed after its lost ACK");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both clients must finish current recovery-capable bootstrap after local recovery");
        }
        const state = await inspect(account.userID);
        assert.deepEqual(state.tabs.map((tab) => tab.id).sort(), ["active", "pinned"],
          "The locally archived identity must never be adopted or remotely tombstoned");
        assert.ok(state.tabs.every((tab) => !tab.deleted && !tab.tombstoned));
      } else if (account.scenario === desktopPersistentRemovalScenario) {
        assert.ok(scenarioAttempts.every((attempt) => attempt.protocolVersion === 4));
        const writes = scenarioAttempts.filter((attempt) => attempt.status === 201);
        assert.ok(new Set(writes.map((attempt) => attempt.mutationID)).size >= 6,
          "Persistent removal requires seed, Close, Undo, Redo, second Undo and stale replay");
        assert.ok(writes.some((receipt) => writes.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest).length >= 2),
        "Persistent deletion must replay its exact immutable mutation after a lost ACK");
        assert.ok(writes.some((attempt) => attempt.outcomeStatuses?.length === 2
          && attempt.outcomeStatuses.every((status) => status === "deleted")),
        "Stale creations for both retired identities must receive terminal tombstones");
        for (const device of account.devices) {
          assert.ok(observedPulls.filter((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201).length >= 2,
          "Both clients must repeat recovery-capable bootstrap from fresh SQLite profiles");
        }
        const state = await inspect(account.userID);
        assert.equal(state.tabs.filter((tab) => tab.deleted && tab.tombstoned).length, 2);
        assert.equal(state.tabs.filter((tab) => !tab.deleted && !tab.tombstoned).length, 4);
        assert.ok(state.tabs.some((tab) => tab.id === "pinned" && tab.deleted && tab.tombstoned));
      } else if (account.scenario === desktopPersistentCloseScenario) {
        assert.ok(scenarioAttempts.every((attempt) => attempt.protocolVersion === 4),
          "Persistent unload may only submit ordinary metadata changes");
        const writes = scenarioAttempts.filter((attempt) => attempt.status === 201);
        assert.ok(new Set(writes.map((attempt) => attempt.mutationID)).size >= 3,
          "Persistent close requires the seed, confirmed home reset and later metadata write");
        assert.ok(writes.some((receipt) => writes.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest).length >= 2),
        "Confirmed home reset must replay its exact immutable mutation after a lost ACK");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both persistent-close clients must finish recovery-capable bootstrap");
        }
        const state = await inspect(account.userID);
        assert.deepEqual(state.tabs.map((tab) => tab.id).sort(), ["anchor", "favorite", "pinned"]);
        assert.ok(state.tabs.every((tab) => !tab.deleted && !tab.tombstoned),
          "Unloading a persistent engine must preserve every server identity");
      } else if (account.scenario === desktopConfirmedCloseScenario) {
        assert.ok(scenarioAttempts.every((attempt) => attempt.protocolVersion === 4),
          "Confirmed manual close and Undo use ordinary v4 semantic mutations");
        const writes = scenarioAttempts.filter((attempt) => attempt.status === 201);
        assert.ok(new Set(writes.map((attempt) => attempt.mutationID)).size >= 3,
          "Confirmed close requires seed, terminal deletion and fresh restoration mutations");
        assert.ok(writes.some((receipt) => writes.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest).length >= 2),
        "Confirmed close must replay its exact immutable mutation after a lost ACK");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both confirmed-close clients must use the current recovery-capable production transport");
        }
      } else if (account.scenario === desktopArchiveScenario || account.scenario === desktopAutomaticScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [4, 5].includes(attempt.protocolVersion)));
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both desktop Archive clients must bootstrap recovery through production v5 pulls");
        }
        const expiry = scenarioAttempts.filter((attempt) => attempt.protocolVersion === 5 && attempt.status === 201
          && attempt.outcomeStatuses?.includes("applied") && attempt.hasAutoArchive);
        assert.ok(expiry.some((receipt) => expiry.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest).length >= 2),
        "Desktop Archive requires accepted canonical recovery and an exact expiry replay");
        if (account.scenario === desktopArchiveScenario) {
          const writes = scenarioAttempts.filter((attempt) => attempt.protocolVersion === 4 && attempt.status === 201);
          assert.ok(writes.some((receipt) => writes.filter((attempt) => attempt.mutationID === receipt.mutationID
            && attempt.digest === receipt.digest).length >= 2),
          "Desktop Archive restore must replay an immutable production mutation after a lost ACK");
        } else {
          const acceptedIndex = scenarioAttempts.findIndex((attempt) => attempt.protocolVersion === 5
            && attempt.status === 201 && attempt.hasAutoArchive);
          assert.ok(scenarioAttempts.slice(acceptedIndex + 1).some((attempt) => attempt.protocolVersion === 4
            && attempt.status === 201), "Desktop scheduled expiry must be followed by a production restoration write");
        }
      } else if (account.scenario === expiryLimitScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [4, 5].includes(attempt.protocolVersion)));
        assert.ok(scenarioAttempts.some((attempt) => attempt.protocolVersion === 4 && attempt.status === 201 && attempt.compressed),
          "The oversized canonical row must be seeded by a real compressed v4 request");
        assert.ok(scenarioAttempts.some((attempt) => attempt.protocolVersion === 5 && attempt.status === 201
          && attempt.outcomeReasons?.includes("response_limit") && attempt.outcomeStatuses?.includes("applied")
          && attempt.hasAutoArchive), "One real queued batch must retain the oversized tab while expiring its small peer");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both response-limit clients must read production v5 state");
        }
      } else if (account.scenario === expiryQueueScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4, 5, 6].includes(attempt.protocolVersion)));
        const expiry = scenarioAttempts.filter((attempt) => attempt.protocolVersion === 5 && attempt.status === 201);
        assert.ok(expiry.some((attempt) => attempt.outcomeReasons?.includes("state_changed")),
          "Queued expiry must reject a stale canonical version");
        assert.ok(expiry.some((receipt) => receipt.outcomeStatuses?.includes("applied") && receipt.hasAutoArchive
          && new Set(expiry.filter((attempt) => attempt.mutationID === receipt.mutationID
            && attempt.digest === receipt.digest && attempt.hasAutoArchive).map((attempt) => attempt.deviceID)).size >= 2),
        "Accepted queued expiry must replay unchanged across real device rotation");
        assert.equal(account.devices.length, 3, "Queued expiry must re-register one device");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Queued expiry clients must complete real v5 bootstrap reads");
        }
        const rotated = account.devices[2];
        assert.ok(observedPulls.some((pull) => pull.deviceID === rotated.deviceID
          && [5, 6].includes(pull.protocolVersion) && pull.cursor > 0 && pull.status === 409),
        "The rotated device must encounter the production v5 bootstrap fence");
      } else if (account.scenario === expiryScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4].includes(attempt.protocolVersion)),
          "Recovery clients retain ordinary v2/v3/v4 mutations");
        for (const device of account.devices) {
          assert.ok(observedPulls.some((pull) => pull.deviceID === device.deviceID
            && [5, 6].includes(pull.protocolVersion) && pull.cursor === 0 && pull.status === 201),
          "Both recovery clients must complete a real v5 bootstrap");
        }
        const expiry = expiryAttempts.filter((attempt) => deviceIDs.has(attempt.deviceID));
        const accepted = expiry.filter((attempt) => attempt.status === 201
          && attempt.response.outcomes?.some((outcome) => outcome.status === "applied")
          && attempt.response.events?.some((event) => event.data?.autoArchive));
        assert.ok(accepted.length > 0, "Recovery requires an accepted production expiry with canonical archive data");
        assert.ok(accepted.some((receipt) => expiry.filter((attempt) => attempt.mutationID === receipt.mutationID
          && attempt.digest === receipt.digest && attempt.status === 201
          && JSON.stringify(canonical(attempt.response)) === JSON.stringify(canonical(receipt.response))).length >= 2),
        "Recovery requires an exact expiry receipt replay");
      } else if (account.scenario === adoptionScenario) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4].includes(attempt.protocolVersion)));
        assert.ok(scenarioAttempts.some((attempt) => attempt.protocolVersion === 3 && attempt.status === 201), "Adoption must begin with v3 writes");
        assert.ok(scenarioAttempts.some((attempt) => attempt.protocolVersion === 4 && attempt.status === 201), "Adoption must finish with v4 writes");
      } else {
        const expectedVersion = legacyScenarios.has(account.scenario) ? 2 : folderScenarios.has(account.scenario) ? 4 : 3;
        assert.ok(scenarioAttempts.every((attempt) => attempt.protocolVersion === expectedVersion),
          `Scenario ${account.scenario} must exercise protocol v${expectedVersion}`);
      }
      completed.add(command.scenario);
      await writeFile(reportPath, JSON.stringify({ completed: [...completed].sort(), attempts: attempts.length }), { mode: 0o600 });
    } else {
      throw new Error("Unknown fixture command");
    }
    outgoing.writeHead(200, { "content-type": "application/json" });
    outgoing.end(JSON.stringify(result));
  })().catch((error: unknown) => {
    console.error(error);
    outgoing.writeHead(500, { "content-type": "application/json" });
    outgoing.end(JSON.stringify({ error: "Fixture control failed" }));
  });
});
control.listen(0, "127.0.0.1");
await once(control, "listening");
const controlURL = `http://127.0.0.1:${(control.address() as AddressInfo).port}/control`;
await writeFile(fixturePath, JSON.stringify({ baseURL, controlURL, controlToken, accounts }), { mode: 0o600 });

let closing = false;
async function close(): Promise<void> {
  if (closing) return;
  closing = true;
  for (const value of held.values()) value.response.destroy();
  for (const value of heldPulls.values()) value.response.destroy();
  proxy.closeAllConnections();
  control.closeAllConnections();
  await Promise.all([new Promise<void>((resolve) => proxy.close(() => resolve())), new Promise<void>((resolve) => control.close(() => resolve()))]);
  await server.stop();
  await pool.end();
}
process.once("SIGTERM", () => void close());
process.once("SIGINT", () => void close());
