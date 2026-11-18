import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomUUID } from "node:crypto";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { exportJWK, generateKeyPair, jwtVerify, SignJWT } from "jose";
import type pg from "pg";
import { integrationEnvironment, issueAccessToken, type SyncServer } from "./sync-server.js";

// Account deletion against a stand-in for Apple's key, token and revocation
// endpoints. The server under test runs unchanged; only the endpoints point here.

type Context = {
  pool: () => pg.Pool;
  startServer: (extra: NodeJS.ProcessEnv) => Promise<SyncServer>;
};
type Session = { accessToken: string; user: { id: string; email: string | null }; device: { id: string } };
type Revocation = { clientID: string; token: string; hint: string | null };

const publicBaseURL = "https://api.openarc.test";
const servicesID = `${integrationEnvironment.APPLE_CLIENT_ID}.signin`;
const teamID = "TEAMDELETE";
const keyID = "KEYDELETE1";
const base64url = (data: string) => Buffer.from(data).toString("base64url");

async function readBody(request: IncomingMessage): Promise<string> {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}

function json(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

/** Rows that still belong to the account, per table. */
async function accountRows(pool: pg.Pool, userID: string, emails: string[]): Promise<Record<string, number>> {
  const result = await pool.query(`
    SELECT
      (SELECT count(*) FROM app_users WHERE id = $1)::int AS app_users,
      (SELECT count(*) FROM devices WHERE user_id = $1)::int AS devices,
      (SELECT count(*) FROM auth_identities WHERE user_id = $1)::int AS auth_identities,
      (SELECT count(*) FROM auth_web_sign_ins WHERE user_id = $1)::int AS auth_web_sign_ins,
      (SELECT count(*) FROM auth_email_codes WHERE email = ANY($2))::int AS auth_email_codes,
      (SELECT count(*) FROM spaces WHERE user_id = $1)::int AS spaces,
      (SELECT count(*) FROM tabs WHERE user_id = $1)::int AS tabs,
      (SELECT count(*) FROM folders WHERE user_id = $1)::int AS folders,
      (SELECT count(*) FROM boosts WHERE user_id = $1)::int AS boosts,
      (SELECT count(*) FROM sync_events WHERE user_id = $1)::int AS sync_events,
      (SELECT count(*) FROM sync_tombstones WHERE user_id = $1)::int AS sync_tombstones,
      (SELECT count(*) FROM sync_mutation_receipts WHERE user_id = $1)::int AS sync_mutation_receipts`,
  [userID, emails]);
  return result.rows[0] as Record<string, number>;
}

export function registerAccountDeletionTests(context: Context) {
  describe("account deletion", () => {
    let mock: Server;
    let mockURL = "";
    let server: SyncServer;
    let environment: NodeJS.ProcessEnv;
    let appleKey: Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
    const signingKey = generateKeyPairSync("ec", { namedCurve: "P-256" });
    /** Authorization codes Apple would accept, by the subject that signed in. */
    const codes = new Map<string, string>();
    const revocations: Revocation[] = [];
    let revokeStatus = 200;

    /** Apple accepts only client secrets signed with the configured key for this team. */
    async function assertClientSecret(form: URLSearchParams) {
      const secret = form.get("client_secret") ?? "";
      const { payload, protectedHeader } = await jwtVerify(secret, signingKey.publicKey, {
        issuer: teamID, audience: "https://appleid.apple.com", algorithms: ["ES256"]
      });
      assert.equal(protectedHeader.kid, keyID);
      assert.equal(payload.sub, form.get("client_id"));
    }

    before(async () => {
      const pair = await generateKeyPair("RS256");
      appleKey = pair.privateKey;
      const jwk = { ...(await exportJWK(pair.publicKey)), kid: "apple-delete-key", alg: "RS256", use: "sig" };
      mock = createServer(async (request, response) => {
        const body = await readBody(request);
        const url = new URL(request.url ?? "/", "http://mock");
        if (request.method === "GET" && url.pathname === "/apple/keys") return json(response, 200, { keys: [jwk] });
        if (request.method === "POST" && url.pathname === "/apple/token") {
          const form = new URLSearchParams(body);
          await assertClientSecret(form);
          assert.equal(form.get("grant_type"), "authorization_code");
          const clientID = form.get("client_id");
          assert.equal(form.get("redirect_uri"), clientID === servicesID ? `${publicBaseURL}/v1/auth/apple/callback` : null);
          const subject = codes.get(form.get("code") ?? "");
          if (!subject) return json(response, 400, { error: "invalid_grant" });
          codes.delete(form.get("code") ?? "");
          return json(response, 200, {
            access_token: "unused", token_type: "Bearer", expires_in: 3600,
            refresh_token: `refresh-${form.get("code")}`,
            id_token: `${base64url("{}")}.${base64url(JSON.stringify({ sub: subject }))}.x`
          });
        }
        if (request.method === "POST" && url.pathname === "/apple/revoke") {
          const form = new URLSearchParams(body);
          await assertClientSecret(form);
          if (revokeStatus !== 200) return json(response, revokeStatus, { error: "server_error" });
          revocations.push({ clientID: form.get("client_id") ?? "", token: form.get("token") ?? "", hint: form.get("token_type_hint") });
          response.writeHead(200);
          return response.end();
        }
        json(response, 404, {});
      });
      mock.listen(0, "127.0.0.1");
      await once(mock, "listening");
      mockURL = `http://127.0.0.1:${(mock.address() as AddressInfo).port}`;
      environment = {
        OPENARC_PUBLIC_BASE_URL: publicBaseURL,
        OPENARC_APPLE_SERVICES_ID: servicesID,
        OPENARC_APPLE_KEYS_URL: `${mockURL}/apple/keys`,
        OPENARC_APPLE_TOKEN_URL: `${mockURL}/apple/token`,
        OPENARC_APPLE_REVOKE_URL: `${mockURL}/apple/revoke`,
        OPENARC_APPLE_TEAM_ID: teamID,
        OPENARC_APPLE_KEY_ID: keyID,
        OPENARC_APPLE_PRIVATE_KEY: signingKey.privateKey.export({ type: "pkcs8", format: "pem" }).toString()
      };
      server = await context.startServer(environment);
    });

    after(async () => {
      await server?.stop();
      mock?.close();
    });

    const call = (path: string, token: string, init: RequestInit = {}) => fetch(`${server.url}${path}`, {
      redirect: "manual", ...init, headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...init.headers }
    });
    const postJSON = async <T>(path: string, token: string, body: unknown, status = 201): Promise<T> => {
      const response = await call(path, token, { method: "POST", body: JSON.stringify(body) });
      const text = await response.text();
      assert.equal(response.status, status, `${path}: ${text}`);
      return (text ? JSON.parse(text) : undefined) as T;
    };
    const deleteAccount = (token: string) => call("/v1/account", token, { method: "DELETE" });

    const appleToken = (subject: string, email: string, audience = integrationEnvironment.APPLE_CLIENT_ID, nonce?: string) =>
      new SignJWT({ email, email_verified: true, ...(nonce ? { nonce } : {}) })
        .setProtectedHeader({ alg: "RS256", kid: "apple-delete-key" })
        .setIssuer("https://appleid.apple.com").setAudience(audience).setSubject(subject)
        .setIssuedAt().setExpirationTime("5m").sign(appleKey);

    async function nativeSignIn(subject: string, email: string, code?: string): Promise<Session> {
      if (code) codes.set(code, subject);
      const response = await fetch(`${server.url}/v1/auth/apple`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({
          identityToken: await appleToken(subject, email), ...(code ? { authorizationCode: code } : {}),
          deviceName: "iPhone", devicePlatform: "iOS"
        })
      });
      assert.equal(response.status, 201, await response.clone().text());
      return response.json() as Promise<Session>;
    }

    async function storedGrant(subject: string) {
      const result = await context.pool().query(
        "SELECT apple_refresh_token AS token, apple_client_id AS \"clientID\" FROM auth_identities WHERE provider = 'apple' AND subject = $1",
        [subject]);
      return result.rows[0] as { token: string | null; clientID: string | null } | undefined;
    }

    /** Spaces, tabs, a folder, a boost, a tombstone and receipts for the session's device. */
    async function syncSomething(session: Session) {
      const device = session.device.id;
      const spaceID = randomUUID();
      await postJSON("/v1/sync/push", session.accessToken, {
        deviceID: device, protocolVersion: 2, mutationID: randomUUID(), changes: [
          { entityType: "space", entityID: spaceID, op: "upsert", data: { title: "Work", systemImageName: "globe", rank: 0, isPinnedSectionCollapsed: false } },
          { entityType: "tab", entityID: randomUUID(), op: "upsert", data: { spaceID, placement: "temporary", rank: 0, urlString: "https://example.test/", title: "Tab" } },
          { entityType: "tab", entityID: randomUUID(), op: "delete" }
        ]
      });
      await postJSON("/v1/sync/push", session.accessToken, {
        deviceID: device, protocolVersion: 4, mutationID: randomUUID(), operations: [
          { kind: "create", entityType: "folder", entityID: randomUUID(), data: { spaceID, parentFolderID: null, title: "Reading" } }
        ]
      });
      await postJSON("/v1/sync/push", session.accessToken, {
        deviceID: device, protocolVersion: 6, mutationID: randomUUID(), operations: [
          { kind: "upsert", entityType: "boost", entityID: randomUUID(), data: { host: "example.test", isEnabled: true, css: "", javaScript: "", zappedSelectors: [] } }
        ]
      });
    }

    it("deletes the account and everything stored for it, and revokes its Apple token", async () => {
      const pool = context.pool();
      const subject = `apple-delete-${randomUUID()}`;
      const email = `${subject}@privaterelay.appleid.com`;
      const session = await nativeSignIn(subject, email, `native-${subject}`);
      assert.deepEqual(await storedGrant(subject), { token: `refresh-native-${subject}`, clientID: integrationEnvironment.APPLE_CLIENT_ID });

      // A second device on the web: Apple's code there is issued to the Services ID.
      const verifier = base64url(randomUUID() + randomUUID());
      const challenge = createHash("sha256").update(verifier).digest("base64url");
      const start = await fetch(`${server.url}/v1/auth/web/apple/start?code_challenge=${challenge}`, { redirect: "manual" });
      const query = new URL(start.headers.get("location") ?? "").searchParams;
      codes.set(`web-${subject}`, subject);
      const callback = await fetch(`${server.url}/v1/auth/apple/callback`, {
        method: "POST", redirect: "manual", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ state: query.get("state") ?? "", code: `web-${subject}`, id_token: await appleToken(subject, email, servicesID, query.get("nonce") ?? "") })
      });
      const appCode = new URL(callback.headers.get("location") ?? "").searchParams.get("code") ?? "";
      const web = await fetch(`${server.url}/v1/auth/web/exchange`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ code: appCode, codeVerifier: verifier, deviceName: "Mac", devicePlatform: "macOS" })
      });
      const mac = await web.json() as Session;
      assert.equal(mac.user.id, session.user.id);
      assert.deepEqual(await storedGrant(subject), { token: `refresh-web-${subject}`, clientID: servicesID }, "the latest grant is kept");

      await syncSomething(session);
      await pool.query(`
        INSERT INTO auth_email_codes (email, code_hash, sent_at, expires_at, window_started_at)
        VALUES ($1, 'x', now(), now() + interval '10 minutes', now())`, [email]);
      await pool.query(`
        INSERT INTO auth_web_sign_ins (provider, state_hash, nonce, code_challenge, expires_at, code_hash, user_id, code_expires_at)
        VALUES ('google', $1, 'n', 'c', now() + interval '10 minutes', $1, $2, now() + interval '5 minutes')`, [`pending-${subject}`, session.user.id]);

      const bystander = await nativeSignIn(`apple-bystander-${randomUUID()}`, `bystander-${randomUUID()}@example.test`);
      await syncSomething(bystander);
      const bystanderBefore = await accountRows(pool, bystander.user.id, []);

      const before = await accountRows(pool, session.user.id, [email]);
      for (const [table, count] of Object.entries(before)) assert.ok(count > 0, `${table} has rows before deletion`);

      const deleted = await deleteAccount(session.accessToken);
      assert.equal(deleted.status, 204);
      assert.equal(await deleted.text(), "");
      const after = await accountRows(pool, session.user.id, [email]);
      assert.deepEqual(Object.entries(after).filter(([, count]) => count > 0), [], "no table keeps the account's rows");
      assert.deepEqual(revocations.splice(0), [{ clientID: servicesID, token: `refresh-web-${subject}`, hint: "refresh_token" }]);
      assert.equal((await pool.query("SELECT count(*)::int AS count FROM apple_token_revocations")).rows[0].count, 0);
      assert.deepEqual(await accountRows(pool, bystander.user.id, []), bystanderBefore, "other accounts keep their data");

      // Every device's token stops working, and deleting again succeeds.
      assert.equal((await deleteAccount(mac.accessToken)).status, 204);
      assert.equal(revocations.length, 0, "nothing is left to revoke");
      await postJSON("/v1/sync/pull", mac.accessToken, { deviceID: mac.device.id, cursor: 0, limit: 10 }, 401);
      await postJSON("/v1/sync/push", session.accessToken, { deviceID: session.device.id, changes: [] }, 401);
      await postJSON("/v1/devices", session.accessToken, { name: "Mac", platform: "macOS" }, 401);

      // Signing in again starts a new, empty account.
      const again = await nativeSignIn(subject, email);
      assert.notEqual(again.user.id, session.user.id);
      const pulled = await postJSON<{ events: unknown[] }>("/v1/sync/pull", again.accessToken, { deviceID: again.device.id, cursor: 0, limit: 10 });
      assert.deepEqual(pulled.events, []);
    });

    it("keeps a revocation Apple refused and retries it when the server starts", async () => {
      const pool = context.pool();
      const subject = `apple-retry-${randomUUID()}`;
      const session = await nativeSignIn(subject, `${subject}@example.test`, `native-${subject}`);
      revokeStatus = 503;
      try {
        assert.equal((await deleteAccount(session.accessToken)).status, 204, "Apple being down does not block deletion");
      } finally {
        revokeStatus = 200;
      }
      const pending = await pool.query("SELECT client_id, refresh_token, attempts FROM apple_token_revocations");
      assert.deepEqual(pending.rows, [{ client_id: integrationEnvironment.APPLE_CLIENT_ID, refresh_token: `refresh-native-${subject}`, attempts: 1 }]);
      assert.equal(revocations.length, 0);

      const restarted = await context.startServer(environment);
      try {
        for (let attempt = 0; attempt < 100 && revocations.length === 0; attempt += 1) {
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        assert.deepEqual(revocations.splice(0), [{ clientID: integrationEnvironment.APPLE_CLIENT_ID, token: `refresh-native-${subject}`, hint: "refresh_token" }]);
        for (let attempt = 0; attempt < 100; attempt += 1) {
          if ((await pool.query("SELECT count(*)::int AS count FROM apple_token_revocations")).rows[0].count === 0) break;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        assert.equal((await pool.query("SELECT count(*)::int AS count FROM apple_token_revocations")).rows[0].count, 0);
      } finally {
        await restarted.stop();
      }
    });

    it("deletes accounts without an Apple token, and limits requests per account", async () => {
      const pool = context.pool();
      const legacy = await pool.query("INSERT INTO app_users (apple_subject) VALUES ($1) RETURNING id", [`legacy-delete-${randomUUID()}`]);
      const userID = legacy.rows[0].id as string;
      const token = await issueAccessToken(userID);
      assert.equal((await deleteAccount(token)).status, 204);
      assert.equal((await pool.query("SELECT count(*)::int AS count FROM app_users WHERE id = $1", [userID])).rows[0].count, 0);
      assert.equal(revocations.length, 0, "an account from before refresh tokens has nothing to revoke");
      for (let attempt = 1; attempt < 5; attempt += 1) assert.equal((await deleteAccount(token)).status, 204);
      const limited = await deleteAccount(token);
      assert.equal(limited.status, 429);
      assert.equal(((await limited.json()) as { statusCode: number }).statusCode, 429);
      assert.equal((await deleteAccount(await issueAccessToken(randomUUID()))).status, 204, "the limit is per account");
      assert.equal((await fetch(`${server.url}/v1/account`, { method: "DELETE" })).status, 401);
    });
  });
}
