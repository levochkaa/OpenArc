import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, it } from "node:test";
import type pg from "pg";

type Device = { id: string; token: string };
type Summary = {
  id: string; kind: string; url: string; sourceID: string; title: string; excerpt: string | null;
  itemCount: number; createdAt: string; updatedAt: string;
};
type Context = {
  pool: () => pg.Pool;
  baseURL: () => string;
  account: () => Promise<{ id: string; devices: [Device, Device] }>;
  post: <T>(path: string, token: string, body: unknown, status?: number) => Promise<T>;
};

const png = `data:image/png;base64,${Buffer.from("\x89PNG\r\n\x1a\nicon", "latin1").toString("base64")}`;

function space(sourceID: string, title = "Reading") {
  return {
    kind: "space", sourceID, title, icon: "📚", colors: ["#3139FB"],
    items: [
      { type: "folder", title: "News" },
      { type: "tab", title: "Paper", url: "https://example.com/paper", favicon: png, parent: 0 },
      { type: "tab", title: "Blog", url: "https://blog.example/" }
    ]
  };
}

/** Shared links against the suite's server and disposable PostgreSQL. */
export function registerShareTests({ pool, baseURL, account, post }: Context) {
  const request = (path: string, init: RequestInit = {}) =>
    fetch(new URL(path, baseURL()), { redirect: "manual", signal: AbortSignal.timeout(15_000), ...init });
  const publish = (token: string, body: unknown, status = 201) => post<Summary>("/v1/shares", token, body, status);
  const list = async (token: string) => {
    const response = await request("/v1/shares", { headers: { authorization: `Bearer ${token}` } });
    assert.equal(response.status, 200);
    return (await response.json() as { shares: Summary[] }).shares;
  };
  const remove = (token: string, id: string) =>
    request(`/v1/shares/${id}`, { method: "DELETE", headers: { authorization: `Bearer ${token}` } });

  describe("shared links", () => {
    it("publishes a Space, serves its page and content, and updates the same link", async () => {
      const owner = (await account()).devices[0];
      const first = await publish(owner.token, space("space-1"));
      assert.match(first.id, /^[A-Za-z0-9]{10}$/);
      assert.equal(first.url, `https://openarc.su/s/${first.id}`);
      assert.deepEqual([first.kind, first.title, first.itemCount, first.sourceID], ["space", "Reading", 2, "space-1"]);

      const content = await request(`/v1/shares/${first.id}`);
      assert.equal(content.status, 200);
      const shared = await content.json() as Record<string, unknown>;
      assert.equal(shared.shareURL, first.url);
      assert.deepEqual(shared.items, space("space-1").items);
      // Nothing about the account or the sidebar it came from.
      assert.deepEqual(Object.keys(shared).sort(),
        ["colors", "createdAt", "icon", "id", "items", "kind", "shareURL", "title", "updatedAt"]);

      const page = await request(`/s/${first.id}`);
      assert.equal(page.status, 200);
      assert.equal(page.headers.get("content-type"), "text/html; charset=utf-8");
      const html = await page.text();
      assert.match(html, /<h1 id="title">Reading<\/h1>/);
      assert.match(html, new RegExp(`href="openarc://share/${first.id}"`));
      assert.match(html, /<meta property="og:title" content="Reading · OpenArc">/);
      const wrongPath = await request(`/q/${first.id}`);
      assert.equal(wrongPath.status, 301);
      assert.equal(wrongPath.headers.get("location"), first.url);

      const again = await publish(owner.token, space("space-1", "Reading list"));
      assert.equal(again.id, first.id);
      assert.equal(again.createdAt, first.createdAt);
      assert.equal(again.title, "Reading list");
      const other = await publish(owner.token, { ...space("folder-1", "News"), kind: "folder" });
      assert.notEqual(other.id, first.id);
      assert.deepEqual((await list(owner.token)).map((share) => share.id), [other.id, first.id]);
    });

    it("gives the same quote one link and a different quote another", async () => {
      const owner = (await account()).devices[0];
      const quote = { kind: "quote", text: "Words worth\nkeeping", title: "Essay", url: "https://example.com/essay#:~:text=Words", favicon: png };
      const first = await publish(owner.token, quote);
      assert.equal(first.url, `https://openarc.su/q/${first.id}`);
      assert.equal(first.excerpt, "Words worth keeping");
      assert.equal((await publish(owner.token, quote)).id, first.id);
      assert.notEqual((await publish(owner.token, { ...quote, text: "Other words" })).id, first.id);
      const html = await (await request(`/q/${first.id}`)).text();
      assert.match(html, /<p>Words worth<\/p>\n<p>keeping<\/p>/);
      assert.match(html, /Read it on example.com/);
    });

    it("lets only the owner remove a link, after which its page says so", async () => {
      const owner = (await account()).devices[0];
      const stranger = (await account()).devices[0];
      const share = await publish(owner.token, space("space-2"));
      assert.equal((await remove(stranger.token, share.id)).status, 404);
      assert.equal((await request(`/s/${share.id}`)).status, 200);
      assert.equal((await remove(owner.token, share.id)).status, 204);
      assert.equal((await remove(owner.token, share.id)).status, 404);
      const page = await request(`/s/${share.id}`);
      assert.equal(page.status, 404);
      assert.match(await page.text(), /This link was removed/);
      assert.equal((await request(`/v1/shares/${share.id}`)).status, 404);
      assert.deepEqual(await list(owner.token), []);
    });

    it("limits publishes per hour and removes links with the account", async () => {
      const owner = await account();
      const token = owner.devices[0].token;
      await pool().query(`INSERT INTO share_publishes (user_id, published_at)
        SELECT $1, now() - interval '2 hours' FROM generate_series(1, 80)`, [owner.id]);
      await pool().query(`INSERT INTO share_publishes (user_id)
        SELECT $1 FROM generate_series(1, 59)`, [owner.id]);
      const last = await publish(token, space("space-3"));
      const refused = await post<{ message: string }>("/v1/shares", token, space("space-4"), 429);
      assert.match(refused.message, /Too many shared links/);
      const counted = await pool().query("SELECT count(*)::int AS count FROM share_publishes WHERE user_id = $1", [owner.id]);
      assert.equal(counted.rows[0].count, 60, "Publishes older than an hour are dropped");

      await pool().query("DELETE FROM app_users WHERE id = $1", [owner.id]);
      assert.equal((await request(`/s/${last.id}`)).status, 404);
    });

    it("refuses unsafe content before storing it", async () => {
      const owner = (await account()).devices[0];
      const unsafe = { ...space(randomUUID()), items: [{ type: "tab", url: "javascript:alert(1)" }] };
      const error = await post<{ message: string }>("/v1/shares", owner.token, unsafe, 400);
      assert.match(error.message, /items\.0\.url/);
      assert.deepEqual(await list(owner.token), []);
    });
  });
}
