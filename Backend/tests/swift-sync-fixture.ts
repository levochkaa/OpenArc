import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { writeFile } from "node:fs/promises";
import { createServer, request, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { gunzipSync } from "node:zlib";

// This driver is test-only. Authentication, device registration, migrations and
// every sync request use the production server. Fault controls live separately.
const [fixturePath, reportPath] = process.argv.slice(2);
assert.ok(fixturePath && reportPath, "Expected fixture and completion-report paths");
const suite = process.env.THEBROWSER_SYNC_FIXTURE_SUITE ?? "desktop";
assert.ok(suite === "desktop" || suite === "mobile", "Unknown Swift sync fixture suite");
const databaseURL = new URL(process.env.THEBROWSER_SYNC_TEST_DATABASE_URL ?? "");
assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(databaseURL.hostname));
assert.match(databaseURL.pathname, /^\/thebrowser_sync_test_[a-z0-9_]+$/);
process.env.DATABASE_URL = databaseURL.toString();
process.env.APPLE_CLIENT_ID = "com.thebrowser.sync-integration-tests";
process.env.JWT_SECRET = "local-integration-only-secret-at-least-thirty-two-bytes";
process.env.JWT_ISSUER = "thebrowser-sync-integration-tests";
process.env.JWT_AUDIENCE = "thebrowser-sync-integration-clients";

const [{ buildApp }, { AuthService }, { pool }] = await Promise.all([
  import("../src/app.js"), import("../src/auth.service.js"), import("../src/db.js")
]);
const schema = await pool.query("SELECT to_regclass('public.app_users') AS table_name");
assert.equal(schema.rows[0].table_name, null, "Swift HTTP tests require a fresh empty database");
await promisify(execFile)(process.execPath, ["--import", "tsx", "src/migrate.ts"], {
  cwd: fileURLToPath(new URL("../", import.meta.url)), timeout: 15_000
});
const app = await buildApp({ logger: false });
await app.listen(0, "127.0.0.1");
const upstream = await app.getUrl();
const auth = app.get(AuthService);
const controlToken = randomUUID();

type Mode = "drop" | "hold";
type Attempt = { deviceID: string; mutationID: string; protocolVersion: number; digest: string; compressed: boolean; status: number };
type ObservedPull = {
  deviceID: string; protocolVersion: number; cursor: number; status: number;
  eventCount?: number; responseCursor?: number;
};
type HeldResponse = { response: ServerResponse; status: number; headers: IncomingMessage["headers"]; data: Buffer };
const modes = new Map<string, Mode>();
const held = new Map<string, HeldResponse>();
const pullModes = new Map<string, number>();
const heldPulls = new Map<string, HeldResponse>();
const attempts: Attempt[] = [];
const observedPulls: ObservedPull[] = [];
const completed = new Set<string>();
const legacyScenarios = new Set(["offline-delete", "lost-ack", "edit-during-ack", "global-favorite"]);
const legacyAuthorizations = new Set<string>();
const semanticAuthorizations = new Set<string>();
const capabilityOverrides = new Map<string, number[]>();
const adoptionScenario = "folder-adoption-paged";
const folderScenarios = new Set([
  "folder-roundtrip", "folder-race", "folder-lost-ack", adoptionScenario,
  "folder-device-rotation", "folder-pending-delete"
]);
const mobileScenarios = new Set(["mobile-v4-roundtrip", "mobile-v4-recovery"]);
const desktopScenarios = [
  ...legacyScenarios, "semantic-move-first", "semantic-patch-first",
  "coordinator-move-first", "coordinator-patch-first", "coordinator-lost-ack", "coordinator-delete-pending",
  "coordinator-space-delete-move", "explicit-local-first", "explicit-remote-first", "explicit-group-replay",
  "persistence-retry", "pending-parent-delete", "pending-navigation", ...folderScenarios
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
      attempts.push({
        deviceID: push.deviceID, mutationID: push.mutationID,
        protocolVersion: push.protocolVersion ?? 1,
        digest: createHash("sha256").update(JSON.stringify(canonical({
          protocolVersion: push.protocolVersion, changes: push.changes, operations: push.operations
        }))).digest("hex"),
        compressed, status
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
    } else if (pull?.protocolVersion === 4 && status >= 200 && status < 300
      && pullModes.get(pull.deviceID) === pull.cursor) {
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
  const accessToken = await auth.issueAccessToken(userID);
  if (legacyScenarios.has(scenario)) legacyAuthorizations.add(`Bearer ${accessToken}`);
  else if (!folderScenarios.has(scenario) && !mobileScenarios.has(scenario)) semanticAuthorizations.add(`Bearer ${accessToken}`);
  if (scenario === adoptionScenario) capabilityOverrides.set(`Bearer ${accessToken}`, [2, 3]);
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
        t.user_title_override AS title, t.pinned_folder_id AS "pinnedFolderID", t.deleted_at IS NOT NULL AS deleted,
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
      cursor?: number; versions?: number[];
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
      assert.ok(!heldPulls.has(command.deviceID) && !pullModes.has(command.deviceID), "A pull is already armed or held");
      pullModes.set(command.deviceID, command.cursor!);
    } else if (command.action === "releasepull") {
      assert.ok(command.deviceID);
      pullModes.delete(command.deviceID);
      const response = heldPulls.get(command.deviceID);
      heldPulls.delete(command.deviceID);
      if (response) sendHeld(response);
    } else if (command.action === "setcapabilities") {
      const account = accounts.find((account) => account.userID === command.userID);
      assert.ok(account?.scenario === adoptionScenario, "Capability transitions belong to the adoption scenario");
      assert.ok(JSON.stringify(command.versions) === "[2,3]" || JSON.stringify(command.versions) === "[2,3,4]");
      for (const device of account.devices) {
        capabilityOverrides.set(`Bearer ${device.accessToken}`, command.versions!);
      }
    } else if (command.action === "rotate") {
      const account = accounts.find((account) => account.userID === command.userID);
      assert.ok(account?.scenario === "folder-device-rotation", "Device rotation belongs to its isolated scenario");
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
      if (mobileScenarios.has(account.scenario)) {
        assert.ok(scenarioAttempts.every((attempt) => [2, 3, 4].includes(attempt.protocolVersion)),
          "Mobile scenarios allow initial v2/v3 bootstrap before v4 adoption");
        for (const device of account.devices) {
          assert.ok(scenarioAttempts.some((attempt) => attempt.deviceID === device.deviceID
            && attempt.protocolVersion === 4 && attempt.status === 201),
          "Both mobile scenario devices must commit production v4 mutations");
        }
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
  await app.close();
}
process.once("SIGTERM", () => void close());
process.once("SIGINT", () => void close());
