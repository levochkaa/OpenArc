import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createServer as createTCPServer, type Server as TCPServer, type Socket } from "node:net";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import type pg from "pg";
import { integrationEnvironment, type SyncServer } from "./sync-server.js";

// Sign-in methods against stand-ins for Apple, Google, GitHub and a mail server. The
// server under test runs unchanged; only the providers' endpoints point here.

type Context = {
  pool: () => pg.Pool;
  startServer: (extra: NodeJS.ProcessEnv) => Promise<SyncServer>;
};
type Session = { accessToken: string; user: { id: string; email: string | null }; device: { id: string } };
type GithubUser = { id: number; emails: { email: string; primary: boolean; verified: boolean }[] };

const publicBaseURL = "https://api.openarc.test";
const servicesID = `${integrationEnvironment.APPLE_CLIENT_ID}.signin`;

const base64url = (data: Buffer | string) => Buffer.from(data).toString("base64url");
const challengeOf = (verifier: string) => base64url(createHash("sha256").update(verifier).digest());
const newVerifier = () => base64url(randomBytes(32));

async function readBody(request: IncomingMessage): Promise<string> {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}

type Email = { from: string; to: string[]; headers: Map<string, string>; text: string };

/** Just enough SMTP to accept one message per transaction, without TLS or AUTH. */
function startMailServer(received: Email[], sockets: Set<Socket>): TCPServer {
  return createTCPServer((socket: Socket) => {
    // The server under test pools its connection, which a restart resets.
    sockets.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => sockets.delete(socket));
    let buffer = "";
    let data: string[] | undefined;
    let from = "";
    let to: string[] = [];
    const reply = (line: string) => socket.write(`${line}\r\n`);
    reply("220 mock ESMTP");
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let index: number;
      while ((index = buffer.indexOf("\r\n")) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        if (data) {
          if (line !== ".") {
            data.push(line.startsWith("..") ? line.slice(1) : line);
            continue;
          }
          const blank = data.indexOf("");
          const headers = new Map<string, string>();
          for (const header of data.slice(0, blank)) {
            const colon = header.indexOf(":");
            if (colon > 0) headers.set(header.slice(0, colon).toLowerCase(), header.slice(colon + 1).trim());
          }
          received.push({ from, to, headers, text: data.slice(blank + 1).join("\n") });
          data = undefined;
          reply("250 queued");
          continue;
        }
        const command = line.slice(0, 4).toUpperCase();
        if (command === "EHLO" || command === "HELO") reply("250 mock");
        else if (command === "MAIL") { from = /<([^>]*)>/.exec(line)?.[1] ?? ""; to = []; reply("250 OK"); }
        else if (command === "RCPT") { to.push(/<([^>]*)>/.exec(line)?.[1] ?? ""); reply("250 OK"); }
        else if (command === "DATA") { data = []; reply("354 go ahead"); }
        else if (command === "QUIT") { reply("221 bye"); socket.end(); }
        else if (command === "RSET" || command === "NOOP") reply("250 OK");
        else reply("502 not implemented");
      }
    });
  });
}

function json(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

export function registerSignInTests(context: Context) {
  describe("sign-in methods", () => {
    let mock: Server;
    let mailServer: TCPServer;
    const mailSockets = new Set<Socket>();
    let mockURL = "";
    let server: SyncServer;
    let appleKey: Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
    const googleCodes = new Map<string, Record<string, unknown>>();
    const githubCodes = new Map<string, GithubUser>();
    const githubTokens = new Map<string, GithubUser>();
    const emails: Email[] = [];

    before(async () => {
      const pair = await generateKeyPair("RS256");
      appleKey = pair.privateKey;
      const jwk = { ...(await exportJWK(pair.publicKey)), kid: "apple-test-key", alg: "RS256", use: "sig" };
      mock = createServer(async (request, response) => {
        const body = await readBody(request);
        const url = new URL(request.url ?? "/", "http://mock");
        if (request.method === "POST" && url.pathname === "/google/token") {
          const form = new URLSearchParams(body);
          assert.equal(form.get("client_id"), "google-client");
          assert.equal(form.get("client_secret"), "google-secret");
          assert.equal(form.get("grant_type"), "authorization_code");
          assert.equal(form.get("redirect_uri"), `${publicBaseURL}/v1/auth/google/callback`);
          const claims = googleCodes.get(form.get("code") ?? "");
          if (!claims) return json(response, 400, { error: "invalid_grant" });
          // Unsigned, as the server reads claims straight from Google's endpoint.
          return json(response, 200, { id_token: `${base64url("{}")}.${base64url(JSON.stringify(claims))}.x` });
        }
        if (request.method === "POST" && url.pathname === "/github/token") {
          const form = new URLSearchParams(body);
          assert.equal(form.get("client_secret"), "github-secret");
          const user = githubCodes.get(form.get("code") ?? "");
          if (!user) return json(response, 200, { error: "bad_verification_code" });
          const token = `token-${form.get("code")}`;
          githubTokens.set(token, user);
          return json(response, 200, { access_token: token, token_type: "bearer" });
        }
        if (request.method === "GET" && url.pathname.startsWith("/github/api/user")) {
          const user = githubTokens.get((request.headers.authorization ?? "").replace("Bearer ", ""));
          if (!user) return json(response, 401, {});
          return json(response, 200, url.pathname.endsWith("/emails") ? user.emails : { id: user.id, login: `user${user.id}` });
        }
        if (request.method === "GET" && url.pathname === "/apple/keys") return json(response, 200, { keys: [jwk] });
        json(response, 404, {});
      });
      mock.listen(0, "127.0.0.1");
      await once(mock, "listening");
      mockURL = `http://127.0.0.1:${(mock.address() as AddressInfo).port}`;
      mailServer = startMailServer(emails, mailSockets);
      mailServer.listen(0, "127.0.0.1");
      await once(mailServer, "listening");
      server = await context.startServer({
        OPENARC_PUBLIC_BASE_URL: publicBaseURL,
        OPENARC_APPLE_SERVICES_ID: servicesID,
        OPENARC_APPLE_KEYS_URL: `${mockURL}/apple/keys`,
        OPENARC_GOOGLE_CLIENT_ID: "google-client",
        OPENARC_GOOGLE_CLIENT_SECRET: "google-secret",
        OPENARC_GOOGLE_TOKEN_URL: `${mockURL}/google/token`,
        OPENARC_GITHUB_CLIENT_ID: "github-client",
        OPENARC_GITHUB_CLIENT_SECRET: "github-secret",
        OPENARC_GITHUB_TOKEN_URL: `${mockURL}/github/token`,
        OPENARC_GITHUB_API_URL: `${mockURL}/github/api`,
        OPENARC_SMTP_HOST: "127.0.0.1",
        OPENARC_SMTP_PORT: String((mailServer.address() as AddressInfo).port),
        OPENARC_SMTP_SECURITY: "none",
        OPENARC_EMAIL_FROM: "OpenArc <login@openarc.test>"
      });
    });

    after(async () => {
      await server?.stop();
      mock?.close();
      for (const socket of mailSockets) socket.destroy();
      mailServer?.close();
    });

    const call = async (path: string, init: RequestInit = {}) => fetch(`${server.url}${path}`, { redirect: "manual", ...init });
    const postJSON = (path: string, body: unknown) =>
      call(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

    /** Starts a web sign-in and returns the provider's query plus the verifier. */
    async function start(provider: string, verifier = newVerifier()) {
      const response = await call(`/v1/auth/web/${provider}/start?code_challenge=${challengeOf(verifier)}`);
      assert.equal(response.status, 303);
      assert.equal(response.headers.get("cache-control"), "no-store");
      const location = new URL(response.headers.get("location") ?? "");
      return { query: location.searchParams, location, verifier };
    }

    function appCallback(response: Response): URLSearchParams {
      assert.equal(response.status, 303);
      const location = new URL(response.headers.get("location") ?? "");
      assert.equal(`${location.protocol}//${location.host}`, "openarc-auth://callback");
      return location.searchParams;
    }

    async function exchange(code: string, verifier: string, expected = 201): Promise<Session> {
      const response = await postJSON("/v1/auth/web/exchange", { code, codeVerifier: verifier, deviceName: "Test Mac", devicePlatform: "macOS" });
      assert.equal(response.status, expected, await response.clone().text());
      return response.json() as Promise<Session>;
    }

    async function googleSignIn(code: string, claims: Record<string, unknown>) {
      const { query, verifier } = await start("google");
      googleCodes.set(code, {
        iss: "https://accounts.google.com", aud: "google-client", nonce: query.get("nonce"),
        exp: Math.floor(Date.now() / 1000) + 300, ...claims
      });
      const callback = appCallback(await call(`/v1/auth/google/callback?code=${code}&state=${query.get("state")}`));
      return { code: callback.get("code") ?? "", verifier };
    }

    async function emailedCode(address: string): Promise<string> {
      const sent = emails.at(-1);
      assert.equal(sent?.from, "login@openarc.test");
      assert.deepEqual(sent?.to, [address]);
      assert.equal(sent?.headers.get("to"), address);
      const code = /\b(\d{6})\b/.exec(sent?.text ?? "")?.[1];
      assert.ok(code, "the email carries a six-digit code");
      assert.equal(sent?.headers.get("subject"), `${code} is your OpenArc code`);
      return code;
    }

    it("lists the configured methods and keeps existing Apple accounts", async () => {
      const response = await call("/v1/auth/providers");
      assert.deepEqual(await response.json(), { providers: ["apple", "google", "github", "email"] });
      // The suite's legacy account existed before the migration.
      const legacy = await context.pool().query(`
        SELECT count(*)::int AS accounts,
               count(i.subject)::int AS identities
        FROM app_users u
        LEFT JOIN auth_identities i ON i.provider = 'apple' AND i.subject = u.apple_subject AND i.user_id = u.id
        WHERE u.apple_subject LIKE 'legacy-%'`);
      assert.ok(legacy.rows[0].accounts > 0);
      assert.equal(legacy.rows[0].identities, legacy.rows[0].accounts, "earlier Apple accounts keep their Apple identity");
      const unknown = await call(`/v1/auth/web/twitter/start?code_challenge=${challengeOf(newVerifier())}`);
      assert.equal(unknown.status, 404);
      const badChallenge = await call("/v1/auth/web/google/start?code_challenge=short");
      assert.equal(badChallenge.status, 400);
    });

    it("signs in with Google and redeems the code once, only with its verifier", async () => {
      const { query, location } = await start("google");
      assert.equal(`${location.origin}${location.pathname}`, "https://accounts.google.com/o/oauth2/v2/auth");
      assert.equal(query.get("client_id"), "google-client");
      assert.equal(query.get("redirect_uri"), `${publicBaseURL}/v1/auth/google/callback`);
      assert.equal(query.get("scope"), "openid email profile");

      const signIn = await googleSignIn("google-alice", { sub: "google-alice", email: "Alice@Example.test", email_verified: true });
      await exchange(signIn.code, newVerifier(), 401);
      const session = await exchange(signIn.code, signIn.verifier);
      assert.equal(session.user.email, "alice@example.test");
      await exchange(signIn.code, signIn.verifier, 401);

      const again = await googleSignIn("google-alice-2", { sub: "google-alice", email: "alice@example.test", email_verified: true });
      assert.equal((await exchange(again.code, again.verifier)).user.id, session.user.id, "the same Google account");
    });

    it("joins a verified email to its account and keeps unverified ones apart", async () => {
      const google = await googleSignIn("google-carol", { sub: "google-carol", email: "carol@example.test", email_verified: true });
      const carol = await exchange(google.code, google.verifier);

      assert.equal((await postJSON("/v1/auth/email/start", { email: " CAROL@example.test " })).status, 202);
      const code = await emailedCode("carol@example.test");
      const byEmail = await postJSON("/v1/auth/email/verify", { email: "carol@example.test", code, deviceName: "Phone", devicePlatform: "iOS" });
      assert.equal(byEmail.status, 201);
      assert.equal(((await byEmail.json()) as Session).user.id, carol.user.id);

      const { query, verifier } = await start("github");
      assert.equal(query.get("scope"), "read:user user:email");
      githubCodes.set("github-carol", { id: 7001, emails: [{ email: "carol@example.test", primary: true, verified: false }] });
      const callback = appCallback(await call(`/v1/auth/github/callback?code=github-carol&state=${query.get("state")}`));
      const github = await exchange(callback.get("code") ?? "", verifier);
      assert.notEqual(github.user.id, carol.user.id, "an unverified email never joins an account");

      const verified = await start("github");
      githubCodes.set("github-dave", { id: 7002, emails: [{ email: "dave@example.test", primary: true, verified: true }] });
      const daveCallback = appCallback(await call(`/v1/auth/github/callback?code=github-dave&state=${verified.query.get("state")}`));
      assert.equal((await exchange(daveCallback.get("code") ?? "", verified.verifier)).user.email, "dave@example.test");
    });

    it("returns refusals, stale states and provider failures to the app without a code", async () => {
      const denied = await start("google");
      assert.deepEqual(
        [...appCallback(await call(`/v1/auth/google/callback?error=access_denied&state=${denied.query.get("state")}`)).entries()],
        [["error", "access_denied"]]
      );
      assert.equal(appCallback(await call("/v1/auth/google/callback?code=x&state=unknown")).get("error"), "expired");
      const failing = await start("google");
      assert.equal(
        appCallback(await call(`/v1/auth/google/callback?code=never-issued&state=${failing.query.get("state")}`)).get("error"),
        "provider_error"
      );
      const afterFailures = await googleSignIn("google-erin", { sub: "google-erin", email: "erin@example.test", email_verified: true });
      assert.equal((await exchange(afterFailures.code, afterFailures.verifier)).user.email, "erin@example.test");
    });

    it("signs in with Apple on the web and natively into one account", async () => {
      const { query, verifier } = await start("apple");
      assert.equal(query.get("client_id"), servicesID);
      assert.equal(query.get("response_mode"), "form_post");
      const appleToken = (audience: string, nonce?: string) => new SignJWT({ email: "frank@privaterelay.appleid.com", email_verified: "true", ...(nonce ? { nonce } : {}) })
        .setProtectedHeader({ alg: "RS256", kid: "apple-test-key" })
        .setIssuer("https://appleid.apple.com").setAudience(audience).setSubject("apple-frank")
        .setIssuedAt().setExpirationTime("5m").sign(appleKey);

      const wrongNonce = await start("apple");
      const rejected = await call("/v1/auth/apple/callback", {
        method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ state: wrongNonce.query.get("state") ?? "", id_token: await appleToken(servicesID, "other") })
      });
      assert.equal(appCallback(rejected).get("error"), "provider_error");

      const posted = await call("/v1/auth/apple/callback", {
        method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ state: query.get("state") ?? "", code: "unused", id_token: await appleToken(servicesID, query.get("nonce") ?? "") })
      });
      const web = await exchange(appCallback(posted).get("code") ?? "", verifier);
      assert.equal(web.user.email, "frank@privaterelay.appleid.com");

      const native = await postJSON("/v1/auth/apple", {
        identityToken: await appleToken(integrationEnvironment.APPLE_CLIENT_ID), deviceName: "iPhone", devicePlatform: "iOS"
      });
      assert.equal(native.status, 201);
      assert.equal(((await native.json()) as Session).user.id, web.user.id);
    });

    it("deletes expired sign-in records when the server starts and every hour after", async () => {
      const pool = context.pool();
      await pool.query(`
        INSERT INTO auth_email_codes (email, code_hash, sent_at, expires_at, window_started_at)
        VALUES ('stale@example.test', 'x', now() - interval '3 hours', now() - interval '3 hours', now() - interval '3 hours'),
               ('fresh@example.test', 'x', now(), now() + interval '10 minutes', now())`);
      await pool.query(`
        INSERT INTO auth_web_sign_ins (provider, state_hash, nonce, code_challenge, expires_at)
        VALUES ('google', 'stale-state', 'n', 'c', now() - interval '2 hours'),
               ('google', 'fresh-state', 'n', 'c', now() + interval '10 minutes')`);
      const restarted = await context.startServer({});
      try {
        let remaining: string[] = [];
        for (let attempt = 0; attempt < 100; attempt += 1) {
          const rows = await pool.query(`
            SELECT email AS key FROM auth_email_codes WHERE email IN ('stale@example.test', 'fresh@example.test')
            UNION ALL SELECT state_hash FROM auth_web_sign_ins WHERE state_hash IN ('stale-state', 'fresh-state')`);
          remaining = rows.rows.map((row) => row.key).sort();
          if (!remaining.some((key) => key.startsWith("stale"))) break;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        assert.deepEqual(remaining, ["fresh-state", "fresh@example.test"]);
      } finally {
        await restarted.stop();
      }
    });

    it("limits email codes: a resend wait, five tries and expiry", async () => {
      const address = "grace@example.test";
      assert.equal((await postJSON("/v1/auth/email/start", { email: address })).status, 202);
      await emailedCode(address);
      assert.equal((await postJSON("/v1/auth/email/start", { email: address })).status, 429);

      const verify = (code: string) => postJSON("/v1/auth/email/verify", { email: address, code, deviceName: "Mac", devicePlatform: "macOS" });
      await context.pool().query("UPDATE auth_email_codes SET sent_at = now() - interval '2 minutes' WHERE email = $1", [address]);
      assert.equal((await postJSON("/v1/auth/email/start", { email: address })).status, 202);
      const code = await emailedCode(address);
      const wrong = code === "000000" ? "111111" : "000000";
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const response = await verify(wrong);
        assert.equal(response.status, 401);
        assert.equal(((await response.json()) as { message: string }).message, "Wrong code");
      }
      const locked = await verify(code);
      assert.equal(locked.status, 401, "five wrong tries end the code");
      assert.equal(((await locked.json()) as { message: string }).message, "The code expired; ask for a new one");
      assert.equal((await postJSON("/v1/auth/email/start", { email: "not an email" })).status, 400);
    });
  });
}
