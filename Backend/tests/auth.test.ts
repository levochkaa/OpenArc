import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createRemoteJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";

const desktopID = "com.thebrowser.auth-test-desktop";
const mobileID = "com.thebrowser.auth-test-mobile";
process.env.DATABASE_URL = "postgres://test:test@127.0.0.1:5432/thebrowser_auth_test";
process.env.APPLE_CLIENT_ID = desktopID;
process.env.APPLE_CLIENT_IDS = ` ${desktopID}, ${mobileID} `;
process.env.JWT_SECRET = "local-auth-test-secret-at-least-thirty-two-bytes";

const { config, parseConfig } = await import("../src/config.js");
const { AuthService } = await import("../src/auth.service.js");

describe("Apple audience configuration", () => {
  const required = {
    DATABASE_URL: "postgres://test:test@127.0.0.1:5432/thebrowser_auth_test",
    JWT_SECRET: "local-auth-test-secret-at-least-thirty-two-bytes"
  };

  it("retains the single configured desktop audience as the default", () => {
    const result = parseConfig({ ...required, APPLE_CLIENT_ID: ` ${desktopID} ` });
    assert.deepEqual(result.APPLE_CLIENT_IDS, [desktopID]);
  });

  it("trims and deduplicates an explicit list without adding the fallback", () => {
    const result = parseConfig({
      ...required, APPLE_CLIENT_ID: "com.thebrowser.unlisted",
      APPLE_CLIENT_IDS: ` ${desktopID}, ${mobileID}, ${desktopID} `
    });
    assert.deepEqual(result.APPLE_CLIENT_IDS, [desktopID, mobileID]);
    assert.deepEqual(parseConfig({ ...required, APPLE_CLIENT_IDS: mobileID }).APPLE_CLIENT_IDS, [mobileID]);
  });

  it("fails closed for absent, empty, wildcard and malformed audiences", () => {
    assert.throws(() => parseConfig(required));
    for (const value of ["", " ", `,${mobileID}`, `${desktopID},`, `${desktopID}, ,${mobileID}`,
      "*", "com.thebrowser.*", "https://example.test", "com..thebrowser", "com.thebrowser mobile",
      `${desktopID};${mobileID}`]) {
      assert.throws(() => parseConfig({ ...required, APPLE_CLIENT_ID: desktopID, APPLE_CLIENT_IDS: value }));
    }
    for (const value of ["", " ", "*", "com..thebrowser", `${desktopID},${mobileID}`]) {
      assert.throws(() => parseConfig({ ...required, APPLE_CLIENT_ID: value }));
    }
  });
});

describe("Apple identity verification with local JWKS", () => {
  let server: Server;
  let privateKey: CryptoKey;
  let auth: InstanceType<typeof AuthService>;
  let keyRequests = 0;

  before(async () => {
    const keys = await generateKeyPair("RS256");
    privateKey = keys.privateKey;
    const jwk = { ...await exportJWK(keys.publicKey), kid: "local-apple-test-key", alg: "RS256", use: "sig" };
    server = createServer((request, response) => {
      if (request.method !== "GET" || request.url !== "/keys") {
        response.writeHead(404);
        response.end();
        return;
      }
      keyRequests += 1;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ keys: [jwk] }));
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    auth = new AuthService();
    // Replace only key transport in this fixture. Production keeps Apple's URL;
    // the real service still verifies signatures, expiry, issuer and audience.
    Object.defineProperty(auth, "appleJWKS", {
      value: createRemoteJWKSet(new URL(`http://127.0.0.1:${(server.address() as AddressInfo).port}/keys`))
    });
  });

  after(async () => {
    server?.closeAllConnections();
    if (server) await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });

  async function token(audience: string, issuer = "https://appleid.apple.com", expired = false) {
    return new SignJWT({ email: "local@example.test" })
      .setProtectedHeader({ alg: "RS256", kid: "local-apple-test-key" })
      .setSubject("local-apple-subject")
      .setIssuer(issuer)
      .setAudience(audience)
      .setIssuedAt()
      .setExpirationTime(expired ? "-1s" : "5m")
      .sign(privateKey);
  }

  it("accepts exactly the configured desktop and mobile clients", async () => {
    assert.deepEqual(config.APPLE_CLIENT_IDS, [desktopID, mobileID]);
    for (const audience of [desktopID, mobileID]) {
      assert.deepEqual(await auth.verifyAppleIdentityToken(await token(audience)), {
        appleSubject: "local-apple-subject", email: "local@example.test"
      });
    }
    assert.ok(keyRequests > 0, "The fixture must fetch its real local JWKS");
  });

  it("rejects unlisted and lookalike audiences", async () => {
    for (const audience of ["com.thebrowser.unlisted", `${mobileID}.other`, mobileID.toUpperCase()]) {
      await assert.rejects(auth.verifyAppleIdentityToken(await token(audience)), { code: "ERR_JWT_CLAIM_VALIDATION_FAILED" });
    }
  });

  it("rejects the wrong issuer even with an allowed audience", async () => {
    await assert.rejects(auth.verifyAppleIdentityToken(await token(mobileID, "https://not-apple.example.test")), {
      code: "ERR_JWT_CLAIM_VALIDATION_FAILED"
    });
  });

  it("continues to reject expired tokens", async () => {
    await assert.rejects(auth.verifyAppleIdentityToken(await token(mobileID, "https://appleid.apple.com", true)), {
      code: "ERR_JWT_EXPIRED"
    });
  });
});
