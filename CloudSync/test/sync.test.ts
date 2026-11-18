import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { sha256Hex, verifyBearerToken } from "../src/auth.ts";
import { INLINE_PAYLOAD_LIMIT, SyncRequestError } from "../src/protocol.ts";
import { type SqlCursor, type SqlExecutor, type SqlValue, SyncStore } from "../src/sync-store.ts";

function makeSQLiteStore(): SyncStore {
  const db = new DatabaseSync(":memory:");
  const executor: SqlExecutor = {
    exec<T extends Record<string, SqlValue>>(query: string, ...bindings: SqlValue[]): SqlCursor<T> {
      const trimmed = query.trim();
      const params = bindings.map((value) =>
        value instanceof ArrayBuffer ? new Uint8Array(value) : value,
      ) as Array<null | number | bigint | string | Uint8Array>;
      // Handle multi-statement migrations separately from parameterized single queries.
      if (params.length === 0 && trimmed.includes(";") && !/^SELECT\b/i.test(trimmed)) {
        db.exec(trimmed);
        return {
          one: () => ({}) as T,
          toArray: () => [],
        };
      }
      const stmt = db.prepare(trimmed);
      if (/^(SELECT|WITH|PRAGMA)\b/i.test(trimmed)) {
        const rows = stmt.all(...params) as T[];
        return {
          one: () => {
            if (rows.length !== 1) {
              throw new Error(`Expected 1 row, got ${rows.length}`);
            }
            return rows[0];
          },
          toArray: () => rows,
        };
      }
      stmt.run(...params);
      return {
        one: () => ({}) as T,
        toArray: () => [],
      };
    },
  };
  const store = new SyncStore(executor);
  store.migrate();
  return store;
}

test("verifyBearerToken enforces constant-time exact bearer matching", async () => {
  assert.equal(await verifyBearerToken("Bearer super-secret-token", "super-secret-token"), true);
  assert.equal(await verifyBearerToken("bearer super-secret-token", "super-secret-token"), true);
  assert.equal(await verifyBearerToken("Bearer wrong-token", "super-secret-token"), false);
  assert.equal(await verifyBearerToken("Basic c2VjcmV0", "c2VjcmV0"), false);
  assert.equal(await verifyBearerToken(null, "super-secret-token"), false);
  assert.equal(await verifyBearerToken("Bearer anything", undefined), false);
});

test("SyncStore enforces idempotency, blob dependencies, pagination, and tombstones", async () => {
  const store = makeSQLiteStore();
  assert.equal(store.getHealth().revision, 0);

  const noteId = "11111111-1111-4111-8111-111111111111";
  const noteKey = `note:${noteId}`;
  const notePayload = JSON.stringify({ title: "Hello", content: "World" });
  const noteHash = await sha256Hex(notePayload);

  const push1 = store.pushMutations({
    deviceId: "mac-a",
    mutations: [
      {
        entityKey: noteKey,
        kind: "note",
        deleted: false,
        updatedAt: "2026-11-19T00:00:00Z",
        contentHash: noteHash,
        payload: notePayload,
      },
      {
        entityKey: "config:websites",
        kind: "config",
        deleted: false,
        updatedAt: "2026-11-19T00:00:01Z",
        contentHash: await sha256Hex('{"version":3}'),
        payload: '{"version":3}',
      },
    ],
  });

  assert.equal(push1.revision, 2);
  assert.equal(push1.changed, true);
  assert.deepEqual(push1.appliedKeys, [noteKey, "config:websites"]);

  // Re-pushing identical contentHash does not advance revision.
  const pushDuplicate = store.pushMutations({
    deviceId: "mac-a",
    mutations: [
      {
        entityKey: noteKey,
        kind: "note",
        deleted: false,
        updatedAt: "2026-11-19T00:00:05Z",
        contentHash: noteHash,
        payload: notePayload,
      },
    ],
  });
  assert.equal(pushDuplicate.revision, 2);
  assert.equal(pushDuplicate.changed, false);
  assert.deepEqual(pushDuplicate.appliedKeys, []);

  // Referencing an unregistered blob fails with 409.
  const blobHash = await sha256Hex("large-note-payload");
  assert.deepEqual(store.missingBlobs([blobHash, blobHash]), [blobHash]);
  assert.throws(
    () =>
      store.pushMutations({
        deviceId: "mac-b",
        mutations: [
          {
            entityKey: noteKey,
            kind: "note",
            deleted: false,
            updatedAt: "2026-11-19T00:01:00Z",
            contentHash: blobHash,
            payloadBlobSha256: blobHash,
          },
        ],
      }),
    (err: unknown) => err instanceof SyncRequestError && err.statusCode === 409,
  );

  // Registering the blob allows pushing the reference.
  store.registerBlob(blobHash, 18);
  assert.deepEqual(store.missingBlobs([blobHash]), []);
  const pushBlobRef = store.pushMutations({
    deviceId: "mac-b",
    mutations: [
      {
        entityKey: noteKey,
        kind: "note",
        deleted: false,
        updatedAt: "2026-11-19T00:01:00Z",
        contentHash: blobHash,
        payloadBlobSha256: blobHash,
      },
    ],
  });
  assert.equal(pushBlobRef.revision, 3);

  // Pull pagination works with limit = 1.
  const page1 = store.pullChanges(0, 1);
  assert.equal(page1.hasMore, true);
  assert.equal(page1.latestRevision, 3);
  assert.equal(page1.changes.length, 1);
  assert.equal(page1.changes[0].entityKey, "config:websites");
  assert.equal(page1.changes[0].revision, 2);

  const page2 = store.pullChanges(page1.changes[0].revision, 1);
  assert.equal(page2.hasMore, false);
  assert.equal(page2.changes.length, 1);
  assert.equal(page2.changes[0].entityKey, noteKey);
  assert.equal(page2.changes[0].payloadBlobSha256, blobHash);

  // Tombstone deletion clears payload and advances revision.
  const delHash = await sha256Hex("deleted:" + noteKey);
  const delPush = store.pushMutations({
    deviceId: "mac-a",
    mutations: [
      {
        entityKey: noteKey,
        kind: "note",
        deleted: true,
        updatedAt: "2026-11-19T00:02:00Z",
        contentHash: delHash,
      },
    ],
  });
  assert.equal(delPush.revision, 4);
  const afterDelete = store.pullChanges(3, 10);
  assert.equal(afterDelete.changes.length, 1);
  assert.equal(afterDelete.changes[0].deleted, true);
  assert.equal(afterDelete.changes[0].payload, null);
  assert.equal(afterDelete.changes[0].payloadBlobSha256, null);
});

test("SyncStore rejects oversized inline payloads and invalid entity keys", async () => {
  const store = makeSQLiteStore();
  const huge = "a".repeat(INLINE_PAYLOAD_LIMIT + 1);
  const hugeHash = await sha256Hex(huge);

  assert.throws(
    () =>
      store.pushMutations({
        deviceId: "mac-a",
        mutations: [
          {
            entityKey: "note:11111111-1111-4111-8111-111111111111",
            kind: "note",
            deleted: false,
            updatedAt: "2026-11-19T00:00:00Z",
            contentHash: hugeHash,
            payload: huge,
          },
        ],
      }),
    (err: unknown) => err instanceof SyncRequestError && err.statusCode === 400,
  );

  assert.throws(
    () =>
      store.pushMutations({
        deviceId: "mac-a",
        mutations: [
          {
            entityKey: "secret:apiKey",
            kind: "config",
            deleted: false,
            updatedAt: "2026-11-19T00:00:00Z",
            contentHash: hugeHash,
            payload: "{}",
          },
        ],
      }),
    (err: unknown) => err instanceof SyncRequestError && err.statusCode === 400,
  );
});
