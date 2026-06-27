import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { after, before, describe, it } from "node:test";
import type { INestApplication } from "@nestjs/common";

process.env.DATABASE_URL ??= "postgres://test:test@127.0.0.1:5432/thebrowser_test";
process.env.APPLE_CLIENT_ID ??= "com.thebrowser.tests";
process.env.JWT_SECRET ??= "test-secret-with-at-least-thirty-two-bytes";
process.env.JWT_ISSUER ??= "thebrowser-sync-test";
process.env.JWT_AUDIENCE ??= "thebrowser-test-clients";
process.env.THEBROWSER_PUBLIC_BASE_URL ??= "https://updates.thebrowser.test";

const { buildApp } = await import("../src/app.js");
const { UpdatesService } = await import("../src/updates.service.js");

describe("updates service", () => {
  const updates = new UpdatesService();

  it("preserves normal filenames in content disposition", () => {
    assert.equal(
      updates.contentDispositionForAsset("TheBrowser-1.2.3.dmg"),
      'attachment; filename="TheBrowser-1.2.3.dmg"'
    );
  });

  it("removes header injection characters from content disposition filenames", () => {
    const header = updates.contentDispositionForAsset('TheBrowser\r\nX-Injected: yes "Beta".dmg');

    assert.equal(header, 'attachment; filename="TheBrowserX-Injected: yes Beta.dmg"');
    assert.doesNotMatch(header, /[\r\n]/);
  });
});

describe("sync API", () => {
  let app: INestApplication;
  let baseURL: string;

  before(async () => {
    app = await buildApp({ logger: false });
    await app.listen(0, "127.0.0.1");
    baseURL = await app.getUrl();
  });

  after(async () => {
    await app.close();
  });

  it("reports health", async () => {
    const response = await request(baseURL, {
      method: "GET",
      path: "/health"
    });

    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), { ok: true });
  });

  it("registers OpenAPI JSON, YAML, and docs routes", async () => {
    const jsonResponse = await request(baseURL, {
      method: "GET",
      path: "/openapi.json"
    });
    assert.equal(jsonResponse.statusCode, 200);
    assert.match(jsonResponse.headers["content-type"] ?? "", /application\/json/);

    const document = jsonResponse.json();
    assert.equal(document.openapi, "3.1.0");
    assert.equal(document.info.title, "TheBrowser Sync API");
    assert.ok(document.paths["/health"]);
    assert.ok(document.paths["/v1/sync/push"]);
    assert.deepEqual(document.paths["/v1/sync/push"].post.security, [{ bearerAuth: [] }]);

    const yamlResponse = await request(baseURL, {
      method: "GET",
      path: "/openapi.yaml"
    });
    assert.equal(yamlResponse.statusCode, 200);
    assert.match(yamlResponse.headers["content-type"] ?? "", /application\/yaml/);
    assert.match(yamlResponse.body, /openapi: 3\.0\.3/);
    assert.match(yamlResponse.body, /\/v1\/sync\/push:/);

    const docsResponse = await request(baseURL, {
      method: "GET",
      path: "/docs"
    });
    assert.ok([200, 301, 302].includes(docsResponse.statusCode));
    assert.match(docsResponse.headers["content-type"] ?? docsResponse.headers.location ?? "", /html|\/docs/);
  });

  it("requires auth before sync push reaches storage", async () => {
    const response = await request(baseURL, {
      method: "POST",
      path: "/v1/sync/push",
      payload: {
        deviceID: "00000000-0000-4000-8000-000000000001",
        changes: []
      }
    });

    assert.equal(response.statusCode, 401);
    assert.deepEqual(response.json(), { error: "unauthorized" });
  });

  it("validates sync pull request bodies", async () => {
    const response = await request(baseURL, {
      method: "POST",
      path: "/v1/sync/pull",
      headers: {
        authorization: "Bearer invalid-token"
      },
      payload: {
        deviceID: "not-a-uuid",
        cursor: -1,
        limit: 1001
      }
    });

    assert.equal(response.statusCode, 400);
    assert.match(response.json().message, /deviceID|cursor|limit/);
  });

  it("decompresses gzipped JSON request bodies before auth handling", async () => {
    const payload = Buffer.from(
      JSON.stringify({
        deviceID: "00000000-0000-4000-8000-000000000001",
        changes: []
      })
    );

    const response = await request(baseURL, {
      method: "POST",
      path: "/v1/sync/push",
      headers: {
        "content-encoding": "gzip",
        "content-type": "application/json"
      },
      payload: gzipSync(payload)
    });

    assert.equal(response.statusCode, 401);
    assert.deepEqual(response.json(), { error: "unauthorized" });
  });
});

async function request(
  baseURL: string,
  options: {
    method: string;
    path: string;
    headers?: Record<string, string>;
    payload?: unknown;
  }
): Promise<{
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  json: () => unknown;
}> {
  const headers = new Headers(options.headers);
  let body: BodyInit | undefined;

  if (Buffer.isBuffer(options.payload)) {
    body = options.payload;
  } else if (options.payload !== undefined) {
    headers.set("content-type", headers.get("content-type") ?? "application/json");
    body = JSON.stringify(options.payload);
  }

  const response = await fetch(new URL(options.path, baseURL), {
    method: options.method,
    headers,
    body,
    redirect: "manual"
  });
  const text = await response.text();

  return {
    statusCode: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body: text,
    json: () => JSON.parse(text)
  };
}
