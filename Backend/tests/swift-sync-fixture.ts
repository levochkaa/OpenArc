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
type HeldResponse = { response: ServerResponse; status: number; headers: IncomingMessage["headers"]; data: Buffer };
const modes = new Map<string, Mode>();
const held = new Map<string, HeldResponse>();
const attempts: Attempt[] = [];
const completed = new Set<string>();
const legacyScenarios = new Set(["offline-delete", "lost-ack", "edit-during-ack", "global-favorite"]);
const legacyAuthorizations = new Set<string>();
const scenarios = [
  ...legacyScenarios, "semantic-move-first", "semantic-patch-first",
  "coordinator-move-first", "coordinator-patch-first", "coordinator-lost-ack", "coordinator-delete-pending",
  "coordinator-space-delete-move", "explicit-local-first", "explicit-remote-first", "explicit-group-replay",
  "persistence-retry", "pending-parent-delete", "pending-navigation"
];

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
    const bytes = await body(incoming);
    const compressed = incoming.headers["content-encoding"] === "gzip";
    const push = incoming.url === "/v1/sync/push"
      ? JSON.parse((compressed ? gunzipSync(bytes) : bytes).toString()) as {
        deviceID: string; mutationID: string; protocolVersion?: number; changes?: unknown[]; operations?: unknown[];
      } : undefined;
    const legacyPull = new URL(incoming.url ?? "/", upstream).pathname === "/v1/sync/pull"
      && legacyAuthorizations.has(incoming.headers.authorization ?? "");
    const headers = { ...incoming.headers, host: new URL(upstream).host };
    // Only the capability shim needs plaintext; other accounts retain real
    // production response compression negotiated by URLSession.
    if (legacyPull) headers["accept-encoding"] = "identity";
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
    if (legacyPull && status >= 200 && status < 300) {
      // Keep the original v2 durability cases exercising an older server's
      // capability response. All writes still reach the unchanged production API.
      const result = JSON.parse(data.toString()) as { supportedPushVersions?: number[] };
      delete result.supportedPushVersions;
      data = Buffer.from(JSON.stringify(result));
      delete responseHeaders["transfer-encoding"];
      responseHeaders["content-length"] = String(data.length);
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
for (const scenario of scenarios) {
  const result = await pool.query("INSERT INTO app_users (apple_subject) VALUES ($1) RETURNING id", [`swift-${randomUUID()}`]);
  const userID = result.rows[0].id as string;
  const accessToken = await auth.issueAccessToken(userID);
  if (legacyScenarios.has(scenario)) legacyAuthorizations.add(`Bearer ${accessToken}`);
  const devices: Device[] = [];
  for (const name of ["Swift A", "Swift B"]) {
    const response = await fetch(new URL("/v1/devices", baseURL), {
      method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ name, platform: "Swift HTTP integration" }), signal: AbortSignal.timeout(10_000)
    });
    assert.equal(response.status, 201);
    const device = await response.json() as { device: { id: string } };
    devices.push({ deviceID: device.device.id, userID, accessToken });
  }
  accounts.push({ scenario, userID, devices });
}

async function inspect(userID: string) {
  assert.ok(accounts.some((account) => account.userID === userID));
  const [events, receipts, tabs] = await Promise.all([
    pool.query("SELECT count(*)::int AS count FROM sync_events WHERE user_id = $1", [userID]),
    pool.query("SELECT count(*)::int AS count FROM sync_mutation_receipts WHERE user_id = $1", [userID]),
    pool.query(`
      SELECT t.id, t.rank, t.space_id AS "spaceID", t.placement, t.url_string AS "urlString",
        t.user_title_override AS title, t.deleted_at IS NOT NULL AS deleted,
        EXISTS (SELECT 1 FROM sync_tombstones s
          WHERE s.user_id = t.user_id AND s.entity_type = 'tab' AND s.entity_id = t.id) AS tombstoned
      FROM tabs t WHERE t.user_id = $1 ORDER BY t.rank, t.id
    `, [userID])
  ]);
  const deviceIDs = new Set(accounts.find((account) => account.userID === userID)!.devices.map((device) => device.deviceID));
  return {
    eventCount: events.rows[0].count, receiptCount: receipts.rows[0].count, tabs: tabs.rows,
    attempts: attempts.filter((attempt) => deviceIDs.has(attempt.deviceID)),
    heldDeviceIDs: [...held.keys()]
  };
}

const control = createServer((incoming, outgoing) => {
  void (async () => {
    assert.equal(incoming.method, "POST");
    assert.equal(incoming.url, "/control");
    assert.equal(incoming.headers.authorization, `Bearer ${controlToken}`);
    const command = JSON.parse((await body(incoming)).toString()) as {
      action: string; deviceID?: string; userID?: string; scenario?: string;
    };
    let result: unknown = {};
    if (command.action === "drop" || command.action === "hold") {
      assert.ok(command.deviceID && accounts.some((account) => account.devices.some((device) => device.deviceID === command.deviceID)));
      modes.set(command.deviceID, command.action);
    } else if (command.action === "release") {
      assert.ok(command.deviceID);
      modes.delete(command.deviceID);
      const response = held.get(command.deviceID);
      held.delete(command.deviceID);
      if (response) sendHeld(response);
    } else if (command.action === "inspect") {
      assert.ok(command.userID);
      result = await inspect(command.userID);
    } else if (command.action === "complete") {
      assert.ok(command.scenario && accounts.some((account) => account.scenario === command.scenario));
      const account = accounts.find((account) => account.scenario === command.scenario)!;
      const deviceIDs = new Set(account.devices.map((device) => device.deviceID));
      const scenarioAttempts = attempts.filter((attempt) => deviceIDs.has(attempt.deviceID));
      assert.ok(scenarioAttempts.length > 0, "Completed scenario must send production sync mutations");
      const expectedVersion = legacyScenarios.has(account.scenario) ? 2 : 3;
      assert.ok(scenarioAttempts.every((attempt) => attempt.protocolVersion === expectedVersion),
        `Scenario ${account.scenario} must exercise protocol v${expectedVersion}`);
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
  proxy.closeAllConnections();
  control.closeAllConnections();
  await Promise.all([new Promise<void>((resolve) => proxy.close(() => resolve())), new Promise<void>((resolve) => control.close(() => resolve()))]);
  await app.close();
}
process.once("SIGTERM", () => void close());
process.once("SIGINT", () => void close());
