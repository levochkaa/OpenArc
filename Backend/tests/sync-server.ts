import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { SignJWT } from "jose";

// Black-box helpers for the Rust server. Tests talk to it only over HTTP and
// its own `migrate` command; access tokens are signed here with the same
// secret, issuer and audience the server verifies.

export const serverBinary = process.env.OPENARC_SYNC_SERVER_BINARY
  ?? fileURLToPath(new URL("../target/debug/openarc-sync-server", import.meta.url));

export const integrationEnvironment = {
  APPLE_CLIENT_ID: "com.openarc.sync-integration-tests",
  JWT_SECRET: "local-integration-only-secret-at-least-thirty-two-bytes",
  JWT_ISSUER: "openarc-sync-integration-tests",
  JWT_AUDIENCE: "openarc-sync-integration-clients"
};

export type SyncServer = { url: string; stop: () => Promise<void> };

function environment(databaseURL: string): NodeJS.ProcessEnv {
  return { ...process.env, ...integrationEnvironment, DATABASE_URL: databaseURL, HOST: "127.0.0.1", PORT: "0", RUST_LOG: "warn" };
}

export async function migrate(databaseURL: string): Promise<void> {
  await promisify(execFile)(serverBinary, ["migrate"], { env: environment(databaseURL), timeout: 15_000 });
}

export async function startSyncServer(databaseURL: string): Promise<SyncServer> {
  const child = spawn(serverBinary, ["serve"], { env: environment(databaseURL), stdio: ["ignore", "pipe", "pipe"] });
  let errors = "";
  child.stderr.on("data", (data: Buffer) => { errors += data.toString(); });
  const lines = createInterface({ input: child.stdout });
  const url = await new Promise<string>((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`Backend startup timed out: ${errors}`)); }, 10_000);
    child.once("error", (error) => { clearTimeout(timeout); reject(error); });
    child.once("exit", (code) => { clearTimeout(timeout); reject(new Error(`Backend exited during startup (${code}): ${errors}`)); });
    lines.on("line", (line: string) => {
      const match = /listening on (http:\/\/\S+)/.exec(line);
      if (match) {
        clearTimeout(timeout);
        resolve(match[1]);
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

/// A sync access token as the server issues it after Apple sign-in.
export async function issueAccessToken(userID: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userID)
    .setIssuer(integrationEnvironment.JWT_ISSUER)
    .setAudience(integrationEnvironment.JWT_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(new TextEncoder().encode(integrationEnvironment.JWT_SECRET));
}
