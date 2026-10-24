import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { it } from "node:test";
import type pg from "pg";
import type { SyncOperationV4 } from "./sync-types.js";

type Device = { id: string; token: string };
type Ref = { entityType: "space" | "tab" | "folder"; entityID: string };
type Event = Ref & { serverSeq: number; op: "upsert" | "delete"; data: Record<string, unknown> };
type Response = {
  cursor: number; events: Event[]; protocolVersion: number; mutationID?: string;
  outcomes?: { operationIndex: number; status: string; reason?: string }[];
};
type Context = {
  pool: () => pg.Pool;
  account: () => Promise<{ id: string; devices: [Device, Device] }>;
  register: (id: string, name: string) => Promise<Device>;
  post: <T>(path: string, token: string, body: unknown, status?: number, url?: string) => Promise<T>;
  startServerProcess: () => Promise<{ url: string; stop: () => Promise<void> }>;
};

/** Shares the existing disposable database, migrations and authenticated HTTP fixture. */
export function registerFolderSyncTests(context: Context) {
  const { pool, account, register, post, startServerProcess } = context;
  const push = (device: Device, operations: SyncOperationV4[], mutationID = randomUUID(), url?: string) =>
    post<Response>("/v1/sync/push", device.token, { deviceID: device.id, protocolVersion: 4, mutationID, operations }, 201, url);
  const pull = (device: Device, cursor = 0, limit = 2, version?: 4) =>
    post<Response>("/v1/sync/pull", device.token, { deviceID: device.id, cursor, limit, ...(version ? { protocolVersion: version } : {}) });
  const legacy = (device: Device, changes: unknown[], mutationID = randomUUID()) =>
    post<Response>("/v1/sync/push", device.token, { deviceID: device.id, protocolVersion: 2, mutationID, changes });
  const v3 = (device: Device, operations: unknown[], mutationID = randomUUID()) =>
    post<Response>("/v1/sync/push", device.token, { deviceID: device.id, protocolVersion: 3, mutationID, operations });

  async function events(device: Device, version?: 4, initialCursor = 0): Promise<Event[]> {
    const result: Event[] = [];
    let cursor = initialCursor;
    for (let page = 0; page < 1000; page++) {
      const response = await pull(device, cursor, 2, version);
      assert.equal(response.protocolVersion, version ?? 2);
      if (!response.events.length) {
        assert.equal(response.cursor, cursor, "Empty pages leave the cursor unchanged");
        return result;
      }
      for (const event of response.events) {
        assert.ok(event.serverSeq > cursor);
        cursor = event.serverSeq;
        result.push(event);
      }
      assert.equal(response.cursor, cursor);
    }
    assert.fail("Folder history did not drain");
  }

  async function state(userID: string) {
    const folders = await pool().query(`SELECT id, space_id AS "spaceID", parent_folder_id AS "parentFolderID",
      title, system_image_name AS "systemImageName", rank FROM folders WHERE user_id=$1 AND deleted_at IS NULL ORDER BY id`, [userID]);
    const tabs = await pool().query(`SELECT id, space_id AS "spaceID", pinned_folder_id AS "pinnedFolderID", placement,
      rank, url_string AS "urlString", pinned_url_string AS "pinnedURLString", user_title_override AS "userTitleOverride"
      FROM tabs WHERE user_id=$1 AND deleted_at IS NULL ORDER BY id`, [userID]);
    return { folders: folders.rows, tabs: tabs.rows };
  }

  async function order(userID: string, spaceID: string, parent: string | null = null): Promise<string[]> {
    const stored = await state(userID);
    return [
      ...stored.folders.filter((row) => row.spaceID === spaceID && row.parentFolderID === parent).map((row) => ({ ...row, type: "folder" })),
      ...stored.tabs.filter((row) => row.spaceID === spaceID && row.placement === "spacePinned" && row.pinnedFolderID === parent)
        .map((row) => ({ ...row, type: "tab" }))
    ].sort((a, b) => a.rank - b.rank || a.type.localeCompare(b.type) || a.id.localeCompare(b.id)).map((row) => `${row.type}:${row.id}`);
  }

  it("v4 bootstraps nested folder identities, mixed ranks and membership through paged HTTP on two clients", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID(), nested = randomUUID(), one = randomUUID(), two = randomUUID();
    await push(a, [space(s), folder(f, s), tab(one, s, f), folder(nested, s, f), tab(two, s, nested),
      tab(f, s), { ...folder("first", s), before: ref("folder", f) }]);
    await push(a, [{ kind: "patch", entityType: "folder", entityID: nested,
      fields: { title: "Nested renamed", systemImageName: "star" } }]);
    const first = await events(a, 4), second = await events(b, 4);
    assert.deepEqual(first, second);
    const latest = project(second);
    assert.equal(latest.get(`folder:${nested}`)?.data.parentFolderID, f);
    assert.equal(latest.get(`folder:${nested}`)?.data.title, "Nested renamed");
    assert.equal(latest.get(`folder:${nested}`)?.data.systemImageName, "star");
    assert.equal(latest.get(`tab:${two}`)?.data.pinnedFolderID, nested);
    assert.ok(latest.has(`folder:${f}`) && latest.has(`tab:${f}`), "Typed IDs never collide");
    assert.deepEqual(await order(id, s), ["folder:first", `folder:${f}`, `tab:${f}`]);
    assert.deepEqual(await order(id, s, f), [`tab:${one}`, `folder:${nested}`]);
    assert.deepEqual((await pull(b, second.at(-1)!.serverSeq, 1, 4)).events, []);
  });

  it("v4 moves mixed roots as one ordered block and resolves typed/deleted anchors only in the target list", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID(), tail = randomUUID(), other = randomUUID();
    await push(a, [space(s), folder(f, s), tab(f, s), tab(t, s), tab(tail, s), folder(other, s), tab("member", s, f)]);
    await push(a, [move([ref("tab", t), ref("folder", f)], s, null, ref("tab", f))]);
    assert.deepEqual(await order(id, s), [`tab:${t}`, `folder:${f}`, `tab:${f}`, `tab:${tail}`, `folder:${other}`]);
    await push(b, [remove("tab", tail)]);
    await push(a, [move([ref("folder", f), ref("tab", t)], s, null, ref("tab", tail), ref("folder", other))]);
    assert.deepEqual(await order(id, s), [`tab:${f}`, `folder:${other}`, `folder:${f}`, `tab:${t}`]);
    assert.deepEqual(await order(id, s, f), ["tab:member"]);
    assert.deepEqual(await events(a, 4), await events(b, 4));
  });

  it("v4 moves and deletes a subtree larger than one thousand events without losing paged history", { timeout: 90_000 }, async () => {
    const { id, devices: [a, b] } = await account();
    const source = randomUUID(), target = randomUUID(), root = randomUUID();
    const tabIDs = Array.from({ length: 1001 }, (_, index) => `large-tab-${String(index).padStart(4, "0")}`);
    await push(a, [space(source), space(target)]);
    // Seed through the legacy snapshot API before folders exist, avoiding a
    // thousand semantic creates that would each read the growing sibling list.
    for (let offset = 0; offset < tabIDs.length; offset += 1000) {
      await legacy(a, tabIDs.slice(offset, offset + 1000).map((entityID, index) => ({
        entityType: "tab", entityID, op: "upsert", data: {
          spaceID: source, placement: "spacePinned", rank: offset + index,
          urlString: `https://example.test/current/${entityID}`,
          pinnedURLString: `https://example.test/home/${entityID}`, userTitleOverride: entityID
        }
      }))).catch((error: unknown) => { throw new Error(`Large folder fixture: legacy seed at ${offset}`, { cause: error }); });
    }
    await push(a, [folder(root, source)]);
    for (let offset = 0; offset < tabIDs.length; offset += 1000) {
      const grouped = await push(a, [move(tabIDs.slice(offset, offset + 1000).map((entityID) => ref("tab", entityID)), source, root)]);
      assert.equal(grouped.outcomes?.[0].status, "applied");
    }

    async function drain(cursor: number) {
      const history: Event[] = [], pageSizes: number[] = [];
      for (let page = 0; page < 16; page++) {
        const response = await pull(b, cursor, 500, 4);
        assert.equal(response.protocolVersion, 4);
        if (!response.events.length) {
          assert.equal(response.cursor, cursor);
          return { history, pageSizes, cursor };
        }
        pageSizes.push(response.events.length);
        for (const event of response.events) {
          assert.ok(event.serverSeq > cursor, "Every event must advance beyond the previous page's cursor");
          cursor = event.serverSeq;
          history.push(event);
        }
        assert.equal(response.cursor, cursor);
      }
      assert.fail("Large subtree history did not drain within sixteen pages");
    }

    // This first pull negotiates v4 at cursor zero before incremental reads.
    const baseline = await drain(0);
    assert.equal(project(baseline.history).size, tabIDs.length + 3);
    assert.deepEqual(await order(id, source, root), tabIDs.map((entityID) => `tab:${entityID}`));

    const moved = await push(a, [move([ref("folder", root)], target)]);
    assert.equal(moved.outcomes?.[0].status, "applied");
    assert.equal(moved.events.length, tabIDs.length + 1);
    assert.ok(moved.events.every((event) => event.op === "upsert" && event.data.spaceID === target));
    const movedPull = await drain(baseline.cursor);
    assert.deepEqual(movedPull.pageSizes, [500, 500, 2]);
    assert.equal(movedPull.cursor, moved.cursor);
    assert.deepEqual(movedPull.history, moved.events);
    const movedState = project([...baseline.history, ...movedPull.history]);
    assert.deepEqual(movedState, project([...baseline.history, ...moved.events]));
    for (const [rank, entityID] of tabIDs.entries()) {
      const data = movedState.get(`tab:${entityID}`)?.data;
      assert.equal(data?.spaceID, target);
      assert.equal(data?.pinnedFolderID, root);
      assert.equal(data?.rank, rank);
      assert.equal(data?.urlString, `https://example.test/current/${entityID}`);
      assert.equal(data?.pinnedURLString, `https://example.test/home/${entityID}`);
      assert.equal(data?.userTitleOverride, entityID);
    }
    assert.deepEqual(await order(id, source), []);
    assert.deepEqual(await order(id, target, root), tabIDs.map((entityID) => `tab:${entityID}`));

    const deleted = await push(a, [remove("folder", root)]);
    assert.equal(deleted.outcomes?.[0].status, "applied");
    assert.equal(deleted.events.length, tabIDs.length + 1);
    assert.ok(deleted.events.every((event) => event.op === "delete"));
    const deletedPull = await drain(movedPull.cursor);
    assert.deepEqual(deletedPull.pageSizes, [500, 500, 2]);
    assert.equal(deletedPull.cursor, deleted.cursor);
    assert.deepEqual(deletedPull.history, deleted.events);
    const finalHistory = [...baseline.history, ...movedPull.history, ...deletedPull.history];
    assert.deepEqual(project(finalHistory), project([...baseline.history, ...moved.events, ...deleted.events]));
    assert.deepEqual(new Set(project(finalHistory).keys()), new Set([`space:${source}`, `space:${target}`]));
    assert.deepEqual(await state(id), { folders: [], tabs: [] });
    const tombstones = await pool().query(
      "SELECT entity_type, entity_id, server_seq FROM sync_tombstones WHERE user_id=$1", [id]
    );
    assert.deepEqual(new Map(tombstones.rows.map((row) => [`${row.entity_type}:${row.entity_id}`, Number(row.server_seq)])),
      new Map(deleted.events.map((event) => [`${event.entityType}:${event.entityID}`, event.serverSeq])));
  });

  it("v4 folder moves carry the current subtree across Spaces while metadata edits commute and moved-out children survive", async () => {
    for (const patchFirst of [true, false]) {
      const { id, devices: [a, b] } = await account();
      const source = randomUUID(), target = randomUUID(), f = randomUUID(), child = randomUUID(), t = randomUUID(), escaped = randomUUID();
      await push(a, [space(source), space(target), folder(f, source), folder(child, source, f),
        tab(t, source, child), tab(escaped, source, f), tab("later", source, f)]);
      await push(b, [move([ref("tab", escaped)], source)]);
      const patch: SyncOperationV4 = { kind: "patch", entityType: "folder", entityID: f, fields: { title: "Concurrent title", systemImageName: null } };
      if (patchFirst) await push(b, [patch]);
      await push(a, [move([ref("folder", f)], target)]);
      if (!patchFirst) await push(b, [patch]);
      const saved = await state(id);
      assert.equal(saved.folders.find((row) => row.id === f)?.title, "Concurrent title");
      assert.ok(saved.folders.every((row) => row.spaceID === target));
      assert.equal(saved.tabs.find((row) => row.id === t)?.spaceID, target);
      assert.equal(saved.tabs.find((row) => row.id === t)?.pinnedFolderID, child);
      assert.equal(saved.tabs.find((row) => row.id === "later")?.spaceID, target);
      assert.equal(saved.tabs.find((row) => row.id === escaped)?.spaceID, source);
      assert.equal(saved.tabs.find((row) => row.id === escaped)?.pinnedFolderID, null);
      assert.deepEqual(await events(a, 4), await events(b, 4));
    }
  });

  it("v4 deletion dominates stale folder/tab creates, patches and moves without deleting moved-out children or Favorites", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), target = randomUUID(), root = randomUUID(), nested = randomUUID(), t = randomUUID(), escaped = randomUUID();
    await push(a, [space(s), space(target), folder(root, s), folder(nested, s, root), tab(t, s, nested),
      folder(escaped, s, root), tab("escape-member", s, escaped), tab("favorite", s, null, "app")]);
    await events(b, 4);
    await push(b, [move([ref("folder", escaped)], target)]);
    await push(a, [remove("folder", root)]);
    const stale = await push(b, [folder(root, s), folder(nested, s, root), tab(t, s, nested),
      { kind: "patch", entityType: "folder", entityID: root, fields: { title: "Offline" } }, move([ref("tab", t)], target)]);
    const deletedIDs = new Set<string>([root, nested, t]);
    assert.ok(stale.events.filter((event) => deletedIDs.has(event.entityID)).every((event) => event.op === "delete"));
    await push(a, [remove("space", s)]);
    const saved = await state(id);
    assert.deepEqual(saved.folders.map((row) => row.id), [escaped]);
    assert.deepEqual(saved.tabs.map((row) => row.id), ["escape-member", "favorite"]);
    const unknown = randomUUID();
    await push(a, [remove("folder", unknown)]);
    const recreate = await push(b, [folder(unknown, target)]);
    assert.equal(recreate.outcomes?.[0].status, "deleted");
    assert.deepEqual(await events(a, 4), await events(b, 4));
  });

  it("v4 distinguishes an omitted pinned home from explicit null through metadata and folder moves", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), f = randomUUID();
    await push(a, [space(s), folder(f, s),
      { kind: "create", entityType: "tab", entityID: "derived", data: {
        spaceID: s, placement: "spacePinned", pinnedFolderID: f, urlString: "https://home.test/derived"
      } },
      { kind: "create", entityType: "tab", entityID: "cleared", data: {
        spaceID: s, placement: "spacePinned", pinnedFolderID: f, urlString: "https://current.test/cleared", pinnedURLString: null
      } }
    ]);
    await push(a, [{ kind: "patch", entityType: "tab", entityID: "derived", fields: { urlString: "https://current.test/derived" } },
      move([ref("tab", "derived"), ref("tab", "cleared")], s)]);
    let saved = await state(id);
    assert.equal(saved.tabs.find((row) => row.id === "derived")?.pinnedURLString, "https://home.test/derived");
    assert.equal(saved.tabs.find((row) => row.id === "cleared")?.pinnedURLString, null);
    await push(a, [{ kind: "patch", entityType: "tab", entityID: "derived", fields: { pinnedURLString: null } }]);
    saved = await state(id);
    assert.ok(saved.tabs.every((row) => row.pinnedURLString === null && row.pinnedFolderID === null));
  });

  it("v4 rejects cycles, overlapping subtrees, wrong-Space parents and missing/deleted targets atomically", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), second = randomUUID(), f = randomUUID(), nested = randomUUID(), t = randomUUID(), dead = randomUUID();
    await push(a, [space(s), space(second), folder(f, s), folder(nested, s, f), tab(t, s), folder(dead, s), remove("folder", dead)]);
    const before = await state(id);
    const invalid: SyncOperationV4[] = [
      move([ref("tab", t), ref("folder", f)], s, nested),
      move([ref("folder", f), ref("folder", nested)], second),
      move([ref("tab", t)], second, nested), move([ref("tab", t)], s, dead),
      move([ref("tab", t)], s, "missing"), folder("invalid", second, nested)
    ];
    for (const operation of invalid) {
      const result = await push(a, [operation]);
      assert.equal(result.outcomes?.[0].status, "rejected");
      assert.deepEqual(await state(id), before, "Invalid operation must not partially move any root");
    }
    const removed = await push(a, [remove("tab", t)]);
    const survivorMove = await push(a, [move([ref("tab", t), ref("folder", nested)], second)]);
    assert.equal(survivorMove.outcomes?.[0].status, "applied");
    assert.ok(survivorMove.events.some((event) => event.serverSeq === removed.events.find((item) => item.op === "delete")?.serverSeq));
    assert.equal((await state(id)).folders.find((row) => row.id === nested)?.spaceID, second);
  });

  it("v4 folder deletion and an offline child move resolve by their actual commit order", async () => {
    for (const moveFirst of [true, false]) {
      const { id, devices: [a, b] } = await account();
      const source = randomUUID(), target = randomUUID(), parent = randomUUID(), child = randomUUID();
      await push(a, [space(source), space(target), folder(parent, source), tab(child, source, parent)]);
      await events(b, 4);
      const moveChild = move([ref("tab", child)], target);
      if (moveFirst) await push(b, [moveChild]);
      const deletion = await push(a, [remove("folder", parent)]);
      if (!moveFirst) {
        const lateMove = await push(b, [moveChild]);
        const tombstone = deletion.events.find((event) => event.entityType === "tab" && event.entityID === child && event.op === "delete");
        assert.ok(tombstone);
        assert.equal(lateMove.outcomes?.[0].status, "deleted");
        assert.ok(lateMove.events.some((event) => event.serverSeq === tombstone.serverSeq));
      }
      const saved = await state(id);
      assert.deepEqual(saved.folders, []);
      if (moveFirst) {
        assert.equal(saved.tabs.length, 1);
        assert.equal(saved.tabs[0].id, child);
        assert.equal(saved.tabs[0].spaceID, target);
        assert.equal(saved.tabs[0].pinnedFolderID, null);
        assert.ok(!deletion.events.some((event) => event.entityType === "tab" && event.entityID === child));
      } else assert.deepEqual(saved.tabs, []);
      assert.deepEqual(await events(a, 4), await events(b, 4));
    }
  });

  it("v4 mixed moves and target folder or Space deletion never leave a partially moved subtree", async () => {
    for (const targetType of ["folder", "space"] as const) {
      for (const moveFirst of [true, false]) {
        const { id, devices: [a, b] } = await account();
        const source = randomUUID(), target = randomUUID(), parent = randomUUID();
        const root = randomUUID(), nested = randomUUID(), child = randomUUID(), sibling = randomUUID();
        await push(a, [space(source), space(target), folder(parent, target), folder(root, source),
          folder(nested, source, root), tab(child, source, nested), tab(sibling, source)]);
        await events(b, 4);
        const before = await state(id);
        const operation = move([ref("folder", root), ref("tab", sibling)], target, parent);
        if (moveFirst) {
          const moved = await push(b, [operation]);
          assert.equal(moved.outcomes?.[0].status, "applied");
          assert.deepEqual(await order(id, target, parent), [`folder:${root}`, `tab:${sibling}`]);
        }
        const deletedID = targetType === "space" ? target : parent;
        const deletion = await push(a, [remove(targetType, deletedID)]);
        if (!moveFirst) {
          const rejected = await push(b, [operation]);
          assert.equal(rejected.outcomes?.[0].status, "rejected");
          assert.equal(rejected.outcomes?.[0].reason, "target_deleted");
          assert.deepEqual(await state(id), {
            folders: before.folders.filter((row) => row.id !== parent), tabs: before.tabs
          });
          const tombstone = deletion.events.find((event) => event.entityType === targetType && event.entityID === deletedID);
          assert.ok(tombstone && rejected.events.some((event) => event.serverSeq === tombstone.serverSeq));
          assert.ok(rejected.events.some((event) => event.entityType === "folder" && event.entityID === root && event.op === "upsert"));
          assert.ok(rejected.events.some((event) => event.entityType === "tab" && event.entityID === sibling && event.op === "upsert"));
        } else {
          assert.deepEqual(await state(id), { folders: [], tabs: [] });
          const deletes = new Set(deletion.events.filter((event) => event.op === "delete").map((event) => `${event.entityType}:${event.entityID}`));
          for (const key of [`folder:${root}`, `folder:${nested}`, `tab:${child}`, `tab:${sibling}`]) assert.ok(deletes.has(key));
        }
        assert.deepEqual(await events(a, 4), await events(b, 4));
      }
    }
  });

  it("v4 simultaneous opposite folder moves serialize so exactly one move can create the parent relation", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), left = randomUUID(), right = randomUUID(), leftTab = randomUUID(), rightTab = randomUUID();
    await push(a, [space(s), folder(left, s), folder(right, s), tab(leftTab, s, left), tab(rightTab, s, right)]);
    await events(b, 4);
    const results = await Promise.all([
      push(a, [move([ref("folder", left)], s, right)]),
      push(b, [move([ref("folder", right)], s, left)])
    ]);
    assert.deepEqual(results.map((response) => response.outcomes?.[0].status).sort(), ["applied", "rejected"]);
    assert.equal(results.find((response) => response.outcomes?.[0].status === "rejected")?.outcomes?.[0].reason, "cycle");
    const saved = await state(id);
    const leftRow = saved.folders.find((row) => row.id === left), rightRow = saved.folders.find((row) => row.id === right);
    assert.ok(leftRow && rightRow);
    assert.ok((leftRow.parentFolderID === right && rightRow.parentFolderID === null)
      || (rightRow.parentFolderID === left && leftRow.parentFolderID === null));
    assert.equal(saved.tabs.find((row) => row.id === leftTab)?.pinnedFolderID, left);
    assert.equal(saved.tabs.find((row) => row.id === rightTab)?.pinnedFolderID, right);
    assert.deepEqual(await events(a, 4), await events(b, 4));
  });

  it("v4 converts a pinned folder member to a global Favorite that survives parent and historical Space deletion", async () => {
    for (const spaceFirst of [true, false]) {
      const { id, devices: [a, b] } = await account();
      const s = randomUUID(), parent = randomUUID(), child = randomUUID();
      await push(a, [space(s), folder(parent, s), tab(child, s, parent)]);
      await events(b, 4);
      const madeGlobal = await push(b, [{ kind: "move", items: [ref("tab", child)],
        destination: { kind: "tabs", spaceID: s, placement: "app", pinnedFolderID: null } }]);
      assert.equal(madeGlobal.outcomes?.[0].status, "applied");
      const deletions: SyncOperationV4[] = spaceFirst
        ? [remove("space", s), remove("folder", parent)] : [remove("folder", parent), remove("space", s)];
      const removed = await push(a, deletions);
      assert.ok(!removed.events.some((event) => event.entityType === "tab" && event.entityID === child));
      const saved = await state(id);
      assert.deepEqual(saved.folders, []);
      assert.equal(saved.tabs.length, 1);
      assert.equal(saved.tabs[0].id, child);
      assert.equal(saved.tabs[0].placement, "app");
      assert.equal(saved.tabs[0].pinnedFolderID, null);
      assert.equal(saved.tabs[0].pinnedURLString, null);
      assert.equal(saved.tabs[0].spaceID, s);
      const staleMove = await push(a, [move([ref("tab", child)], s, parent)]);
      assert.equal(staleMove.outcomes?.[0].reason, "target_deleted");
      assert.deepEqual(await state(id), saved);
      assert.deepEqual(await events(a, 4), await events(b, 4));
    }
  });

  it("v4 Space and temporary-tab reorder preserve distinct rank domains and metadata", async () => {
    const { id, devices: [a, b] } = await account();
    const one = randomUUID(), two = randomUUID(), three = randomUUID();
    const first = randomUUID(), second = randomUUID(), third = randomUUID(), pinned = randomUUID(), favorite = randomUUID();
    await push(a, [space(one), space(two), space(three), tab(first, one, null, "temporary"),
      tab(second, one, null, "temporary"), tab(third, one, null, "temporary"), tab(pinned, one), tab(favorite, one, null, "app")]);
    await push(b, [{ kind: "patch", entityType: "tab", entityID: third, fields: { userTitleOverride: "Concurrent metadata" } }]);
    const unchanged = await state(id);
    await push(a, [{ kind: "move", items: [ref("space", three), ref("space", one)], destination: { kind: "spaces" }, before: ref("space", two) },
      { kind: "move", items: [ref("tab", third), ref("tab", first)],
        destination: { kind: "tabs", spaceID: one, placement: "temporary", pinnedFolderID: null }, before: ref("tab", second) }]);
    const spaces = await pool().query("SELECT id,rank FROM spaces WHERE user_id=$1 AND deleted_at IS NULL ORDER BY rank,id", [id]);
    assert.deepEqual(spaces.rows.map((row) => row.id), [three, one, two]);
    assert.deepEqual(spaces.rows.map((row) => row.rank), [0, 1, 2]);
    const saved = await state(id);
    assert.deepEqual(saved.tabs.filter((row) => row.placement === "temporary").sort((a, b) => a.rank - b.rank).map((row) => row.id), [third, first, second]);
    assert.equal(saved.tabs.find((row) => row.id === third)?.userTitleOverride, "Concurrent metadata");
    assert.deepEqual(saved.tabs.filter((row) => row.placement !== "temporary"), unchanged.tabs.filter((row) => row.placement !== "temporary"));
    assert.deepEqual(await events(a, 4), await events(b, 4));
  });

  it("v4 requires a cursor-zero upgrade, hides folder-only pages from legacy clients and reboots after a downgrade", async () => {
    const { devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID();
    const seeded = await push(a, [space(s), folder(f, s), folder("nested", s, f)]);
    await post("/v1/sync/pull", b.token, { protocolVersion: 4, deviceID: b.id, cursor: seeded.cursor, limit: 1 }, 409);
    const visible = await events(b);
    assert.deepEqual(visible.map((event) => event.entityType), ["space"]);
    const legacyCursor = visible.at(-1)!.serverSeq;
    assert.deepEqual((await pull(b, legacyCursor, 1)).events, []);
    assert.equal((await pull(b, legacyCursor, 1)).cursor, legacyCursor);
    const full = await events(b, 4);
    assert.ok(full.some((event) => event.entityID === "nested"));
    await pull(b, full.at(-1)!.serverSeq, 1, 4);
    await pull(b, legacyCursor);
    await post("/v1/sync/pull", b.token, { protocolVersion: 4, deviceID: b.id, cursor: full.at(-1)!.serverSeq }, 409);
    assert.deepEqual(await events(b, 4), full);
    await push(a, [tab("later", s)]);
    assert.equal((await events(b, undefined, legacyCursor)).at(-1)?.entityID, "later");
  });

  it("legacy metadata/deletes preserve a v4 tree and old reorder cannot flatten its mixed ranks", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID(), root = randomUUID();
    await push(a, [space(s), folder(f, s), tab(t, s, f), tab(root, s)]);
    const originalOrder = await order(id, s);
    const oldRecord = { entityType: "tab", entityID: t, op: "upsert",
      data: { spaceID: s, placement: "spacePinned", rank: 999, urlString: "https://example.test/legacy", userTitleOverride: "Old client" } };
    const receipt = await legacy(b, [oldRecord]);
    assert.ok(receipt.events.every((event) => event.entityType !== "folder" && !("pinnedFolderID" in event.data)));
    await v3(b, [{ kind: "patch", entityType: "tab", entityID: t, fields: { userTitleOverride: "v3 rename" } }]);
    assert.deepEqual(await order(id, s), originalOrder);
    assert.equal((await state(id)).tabs.find((row) => row.id === t)?.pinnedFolderID, f);
    assert.equal((await state(id)).tabs.find((row) => row.id === t)?.userTitleOverride, "v3 rename");
    const blocked = await v3(b, [{ kind: "move", entityType: "tab", entityIDs: [t], destination: { spaceID: s, placement: "spacePinned" }, beforeID: root }]);
    assert.equal(blocked.outcomes?.[0].reason, "upgrade_required");
    await legacy(b, [{ ...oldRecord, entityID: "legacy-new" }]);
    assert.deepEqual(await order(id, s), [...originalOrder, "tab:legacy-new"]);
    await v3(b, [{ kind: "move", entityType: "tab", entityIDs: [t], destination: { spaceID: s, placement: "temporary" } }]);
    assert.equal((await state(id)).tabs.find((row) => row.id === t)?.pinnedFolderID, null);
    assert.equal((await state(id)).tabs.find((row) => row.id === t)?.placement, "temporary");
    await legacy(b, [oldRecord]);
    assert.equal((await state(id)).tabs.find((row) => row.id === t)?.placement, "temporary", "Old snapshot cannot restore old structural state");
    const deleted = await legacy(b, [{ entityType: "space", entityID: s, op: "delete" }]);
    assert.ok(deleted.events.every((event) => event.entityType !== "folder"));
    assert.deepEqual(await state(id), { folders: [], tabs: [] });
    const second = randomUUID();
    await push(a, [space(second), folder("second-folder", second)]);
    const cascade = await v3(b, [
      { kind: "delete", entityType: "space", entityID: second },
      { kind: "create", entityType: "tab", entityID: "late-child", data: {
        spaceID: second, placement: "spacePinned", urlString: "https://example.test/late"
      } }
    ]);
    assert.equal(cascade.outcomes?.[1].reason, "target_deleted", "Same-request capability checks must observe the prior Space cascade");
    assert.ok(cascade.events.every((event) => event.entityType !== "folder"));
    assert.deepEqual(await state(id), { folders: [], tabs: [] });
    const full = await events(a, 4);
    assert.equal(project(full).size, 0, "V4 must still receive folder tombstones from a legacy Space delete");
  });

  it("v4 receipts survive server restart, lost ACK, device rotation and newer changes with the original response payload", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID(), mutationID = randomUUID();
    const operations = [space(s), folder(f, s), tab(t, s, f)];
    let server = await startServerProcess();
    let original: Response;
    try { original = await push(a, operations, mutationID, server.url); }
    finally { await server.stop(); }
    await push(b, [remove("folder", f)]);
    const rotated = await register(id, "rotated v4 device");
    server = await startServerProcess();
    try { assert.deepEqual(await push(rotated, operations, mutationID, server.url), original); }
    finally { await server.stop(); }
    assert.deepEqual(await state(id), { folders: [], tabs: [] });
    await post("/v1/sync/push", a.token, { deviceID: a.id, protocolVersion: 4, mutationID, operations: [folder(f, s)] }, 409);
    await post("/v1/sync/push", a.token, { deviceID: a.id, protocolVersion: 3, mutationID, operations: [] }, 409);
    assert.equal(project(await events(rotated, 4)).size, 1);
  });

  it("v4 concurrent inserts and folder moves converge by account commit order without duplicate identities", async () => {
    const { id, devices: [a, b] } = await account();
    const s = randomUUID(), left = randomUUID(), right = randomUUID(), f = randomUUID(), t = randomUUID(), anchor = randomUUID();
    await push(a, [space(s), space(left), space(right), folder(f, s), tab(t, s, f), tab(anchor, s)]);
    const inserted = await Promise.all([
      push(a, [{ ...folder("inserted-folder", s), before: ref("tab", anchor) }]),
      push(b, [{ ...tab("inserted-tab", s), before: ref("tab", anchor) }])
    ]);
    assert.deepEqual(await order(id, s), [`folder:${f}`,
      ...(inserted[0].cursor < inserted[1].cursor ? ["folder:inserted-folder", "tab:inserted-tab"] : ["tab:inserted-tab", "folder:inserted-folder"]), `tab:${anchor}`]);
    const moved = await Promise.all([push(a, [move([ref("folder", f)], left)]), push(b, [move([ref("folder", f)], right)])]);
    const winner = moved[0].cursor > moved[1].cursor ? left : right;
    const saved = await state(id);
    assert.equal(saved.folders.find((row) => row.id === f)?.spaceID, winner);
    assert.equal(saved.tabs.find((row) => row.id === t)?.spaceID, winner);
    assert.deepEqual(await events(a, 4), await events(b, 4));
  });

  it("v4 rollback removes partially written tree/events/receipt and the identical request remains retryable", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID(), mutationID = randomUUID();
    const operations = [space(s), folder(f, s), tab(t, s, f)];
    await pool().query(`CREATE FUNCTION sync_folder_test_abort() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN IF NEW.entity_id = '${t}' THEN RAISE EXCEPTION 'folder test rollback'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER sync_folder_test_abort AFTER INSERT ON sync_events FOR EACH ROW EXECUTE FUNCTION sync_folder_test_abort()`);
    try {
      await post("/v1/sync/push", a.token, { deviceID: a.id, protocolVersion: 4, mutationID, operations }, 500);
      assert.deepEqual(await state(id), { folders: [], tabs: [] });
      assert.equal((await pool().query("SELECT count(*) FROM sync_events WHERE user_id=$1", [id])).rows[0].count, "0");
      assert.equal((await pool().query("SELECT count(*) FROM sync_mutation_receipts WHERE user_id=$1", [id])).rows[0].count, "0");
    } finally {
      await pool().query("DROP TRIGGER sync_folder_test_abort ON sync_events; DROP FUNCTION sync_folder_test_abort()");
    }
    await push(a, operations, mutationID);
    assert.equal((await state(id)).tabs[0].pinnedFolderID, f);
  });

  it("v4 isolates matching IDs, parents, anchors, tombstones and devices between accounts", async () => {
    const one = await account(), two = await account();
    const s = randomUUID(), f = randomUUID(), t = randomUUID(), foreign = randomUUID();
    await push(one.devices[0], [space(s), folder(f, s), tab(t, s, f)]);
    await push(two.devices[0], [space(s), folder(f, s), folder(foreign, s), tab(t, s, f)]);
    const before = await state(two.id);
    const blocked = await push(one.devices[0], [move([ref("folder", f)], s, foreign),
      { kind: "patch", entityType: "folder", entityID: foreign, fields: { title: "Forbidden" } }]);
    assert.ok(blocked.outcomes?.every((outcome) => outcome.status === "rejected"));
    assert.ok(blocked.events.every((event) => event.entityID !== foreign));
    await push(one.devices[0], [remove("folder", f)]);
    assert.deepEqual(await state(two.id), before);
    await post("/v1/sync/pull", one.devices[0].token, { deviceID: two.devices[0].id, protocolVersion: 4 }, 403);
    await post("/v1/sync/push", one.devices[0].token, { deviceID: two.devices[0].id, protocolVersion: 4, mutationID: randomUUID(), operations: [] }, 403);
  });

  it("v4 rejects malformed structural patches and invalid typed blocks before writing any receipt", async () => {
    const { id, devices: [a] } = await account();
    const s = randomUUID(), f = randomUUID();
    const invalid = [
      { kind: "patch", entityType: "folder", entityID: f, fields: { parentFolderID: null } },
      { kind: "patch", entityType: "tab", entityID: f, fields: { pinnedFolderID: null } },
      move([ref("folder", f), ref("folder", f)], s),
      move([ref("folder", f)], s, null, ref("folder", f)),
      { ...move([ref("folder", f)], s), destination: { kind: "tabs", spaceID: s, placement: "temporary", pinnedFolderID: null } },
      { ...tab(f, s), data: { spaceID: s, placement: "spacePinned", urlString: "https://example.test" } }
    ];
    for (const operation of invalid) {
      await post("/v1/sync/push", a.token, { deviceID: a.id, protocolVersion: 4, mutationID: randomUUID(), operations: [space(s), operation] }, 400);
    }
    assert.equal((await pool().query("SELECT count(*) FROM sync_mutation_receipts WHERE user_id=$1", [id])).rows[0].count, "0");
    assert.deepEqual(await events(a, 4), []);
  });

  it("folder migration preserves legacy receipt JSON/digests and rows while enabling typed tombstones", async () => {
    const client = await pool().connect();
    const schema = `folder_migration_${randomUUID().replaceAll("-", "")}`;
    try {
      await client.query("BEGIN");
      await client.query(`CREATE SCHEMA ${schema}; SET LOCAL search_path TO ${schema}, public`);
      for (const file of ["001_init.sql", "002_sync_tombstones.sql", "003_sync_mutation_receipts.sql", "004_pinned_tab_urls.sql"]) {
        await client.query(await readFile(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
      }
      const userID = randomUUID(), mutationID = randomUUID();
      await client.query("INSERT INTO app_users (id, apple_subject) VALUES ($1,'migration')", [userID]);
      await client.query("INSERT INTO tabs (id,user_id,space_id,placement,rank,url_string,pinned_url_string) VALUES ('legacy',$1,'space','spacePinned',9,'https://now.test','https://home.test')", [userID]);
      const response = { protocolVersion: 2, mutationID, cursor: 1, events: [{ data: { title: "exact old data" } }] };
      await client.query("INSERT INTO sync_mutation_receipts (user_id,mutation_id,payload_digest,response) VALUES ($1,$2,'unchanged-digest',$3)", [userID, mutationID, response]);
      const before = await client.query("SELECT payload_digest,response::text AS bytes FROM sync_mutation_receipts WHERE user_id=$1", [userID]);
      await client.query(await readFile(new URL("../migrations/005_sync_folders.sql", import.meta.url), "utf8"));
      assert.deepEqual((await client.query("SELECT payload_digest,response::text AS bytes FROM sync_mutation_receipts WHERE user_id=$1", [userID])).rows, before.rows);
      const row = (await client.query("SELECT rank,pinned_url_string,pinned_folder_id FROM tabs WHERE user_id=$1", [userID])).rows[0];
      assert.deepEqual(row, { rank: 9, pinned_url_string: "https://home.test", pinned_folder_id: null });
      const event = await client.query("INSERT INTO sync_events (user_id,entity_type,entity_id,op,payload) VALUES ($1,'folder','deleted','delete','{}') RETURNING server_seq", [userID]);
      await client.query("INSERT INTO sync_tombstones (user_id,entity_type,entity_id,server_seq) VALUES ($1,'folder','deleted',$2)", [userID, event.rows[0].server_seq]);
    } finally {
      await client.query("ROLLBACK");
      client.release();
    }
  });
}

function ref(entityType: Ref["entityType"], entityID: string): Ref { return { entityType, entityID }; }
function space(entityID: string): Extract<SyncOperationV4, { kind: "create"; entityType: "space" }> {
  return { kind: "create", entityType: "space", entityID, data: { title: "Folder space", systemImageName: "globe", isPinnedSectionCollapsed: false } };
}
function folder(entityID: string, spaceID: string, parentFolderID: string | null = null): Extract<SyncOperationV4, { kind: "create"; entityType: "folder" }> {
  return { kind: "create", entityType: "folder", entityID, data: { spaceID, parentFolderID, title: "Folder", systemImageName: null } };
}
function tab(entityID: string, spaceID: string, pinnedFolderID: string | null = null, placement: "spacePinned" | "app" | "temporary" = "spacePinned"): Extract<SyncOperationV4, { kind: "create"; entityType: "tab" }> {
  return { kind: "create", entityType: "tab", entityID, data: { spaceID, placement, pinnedFolderID, urlString: "https://example.test/folder", pinnedURLString: placement === "spacePinned" ? "https://example.test/home" : null } };
}
function remove(entityType: Ref["entityType"], entityID: string): SyncOperationV4 { return { kind: "delete", entityType, entityID }; }
function move(items: Ref[], spaceID: string, pinnedFolderID: string | null = null, before?: Ref, after?: Ref): SyncOperationV4 {
  return { kind: "move", items, destination: { kind: "tabs", spaceID, placement: "spacePinned", pinnedFolderID }, before, after };
}
function project(events: Event[]) {
  const latest = new Map<string, Event>();
  for (const event of events) {
    const key = `${event.entityType}:${event.entityID}`;
    if (event.op === "delete") latest.delete(key);
    else latest.set(key, event);
  }
  return latest;
}
