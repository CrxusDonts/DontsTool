import {
  type HealthResponse,
  MAX_BLOB_BYTES,
  MAX_PULL_LIMIT,
  type PullResponse,
  type PushRequest,
  type PushResponse,
  type SyncEntityKind,
  type SyncItemRecord,
  SyncRequestError,
  type SyncRevisionConflict,
  isValidSha256,
  validatePushRequest,
} from "./protocol.ts";

export type SqlValue = ArrayBuffer | string | number | null;

export interface SqlCursor<T extends Record<string, SqlValue> = Record<string, SqlValue>> {
  one(): T;
  toArray(): T[];
}

export interface SqlExecutor {
  exec<T extends Record<string, SqlValue> = Record<string, SqlValue>>(
    query: string,
    ...bindings: SqlValue[]
  ): SqlCursor<T>;
}

interface ExistingItemRow extends Record<string, SqlValue> {
  revision: number;
  content_hash: string;
  deleted: number;
}

interface ItemRow extends Record<string, SqlValue> {
  entity_key: string;
  kind: string;
  revision: number;
  deleted: number;
  updated_at: string;
  content_hash: string;
  device_id: string;
  payload_inline: string | null;
  payload_blob_sha256: string | null;
}

export class SyncStore {
  private readonly sql: SqlExecutor;

  constructor(sql: SqlExecutor) {
    this.sql = sql;
  }

  migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS _sql_schema_migrations (
        id INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    `);
    const current = this.sql
      .exec<{ version: number }>(
        "SELECT COALESCE(MAX(id), 0) AS version FROM _sql_schema_migrations",
      )
      .one().version;

    if (current < 1) {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          int_value INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO meta (key, int_value) VALUES ('revision', 0);

        CREATE TABLE IF NOT EXISTS blobs (
          sha256 TEXT PRIMARY KEY,
          size INTEGER NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS items (
          entity_key TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          revision INTEGER NOT NULL,
          deleted INTEGER NOT NULL,
          updated_at TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          device_id TEXT NOT NULL,
          payload_inline TEXT,
          payload_blob_sha256 TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_items_revision ON items(revision);
        INSERT INTO _sql_schema_migrations (id) VALUES (1);
      `);
    }
  }

  getRevision(): number {
    return this.sql
      .exec<{ int_value: number }>("SELECT int_value FROM meta WHERE key = 'revision'")
      .one().int_value;
  }

  getHealth(): HealthResponse {
    const revision = this.getRevision();
    const itemCount = this.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM items")
      .one().count;
    return {
      ok: true,
      revision,
      itemCount,
      serverTime: new Date().toISOString(),
    };
  }

  hasBlob(sha256: string): boolean {
    if (!isValidSha256(sha256)) {
      return false;
    }
    const rows = this.sql
      .exec<{ sha256: string }>("SELECT sha256 FROM blobs WHERE sha256 = ?", sha256)
      .toArray();
    return rows.length > 0;
  }

  missingBlobs(hashes: unknown): string[] {
    if (!Array.isArray(hashes) || hashes.length > 500) {
      throw new SyncRequestError(400, "hashes must be an array of at most 500 SHA-256 strings.");
    }
    const missing: string[] = [];
    const seen = new Set<string>();
    for (const hash of hashes) {
      if (!isValidSha256(hash)) {
        throw new SyncRequestError(400, "Invalid SHA-256 hash in missingBlobs check.");
      }
      if (seen.has(hash)) {
        continue;
      }
      seen.add(hash);
      if (!this.hasBlob(hash)) {
        missing.push(hash);
      }
    }
    return missing;
  }

  registerBlob(sha256: string, size: number): void {
    if (!isValidSha256(sha256)) {
      throw new SyncRequestError(400, "Invalid blob SHA-256.");
    }
    if (!Number.isInteger(size) || size <= 0 || size > MAX_BLOB_BYTES) {
      throw new SyncRequestError(400, "Invalid blob size.");
    }
    this.sql.exec(
      "INSERT OR IGNORE INTO blobs (sha256, size, created_at) VALUES (?, ?, ?)",
      sha256,
      size,
      new Date().toISOString(),
    );
  }

  pushMutations(rawRequest: unknown): PushResponse & { changed: boolean } {
    const req: PushRequest = validatePushRequest(rawRequest);

    for (const mutation of req.mutations) {
      if (!mutation.deleted && mutation.payloadBlobSha256 && !this.hasBlob(mutation.payloadBlobSha256)) {
        throw new SyncRequestError(
          409,
          `Referenced blob ${mutation.payloadBlobSha256} must be uploaded before pushing "${mutation.entityKey}".`,
          { code: "missing_blob", missingBlobSha256: mutation.payloadBlobSha256 },
        );
      }
    }

    const existingByKey = new Map<string, ExistingItemRow | undefined>();
    const revisionConflicts: SyncRevisionConflict[] = [];
    for (const mutation of req.mutations) {
      const existing = this.sql
        .exec<ExistingItemRow>(
          "SELECT revision, content_hash, deleted FROM items WHERE entity_key = ?",
          mutation.entityKey,
        )
        .toArray()[0];
      existingByKey.set(mutation.entityKey, existing);

      const isIdempotent =
        existing &&
        existing.content_hash === mutation.contentHash &&
        Boolean(existing.deleted) === mutation.deleted;
      if (isIdempotent) {
        continue;
      }

      if (mutation.baseRevision !== undefined && mutation.baseRevision !== null) {
        const currentRevision = existing ? existing.revision : 0;
        if (currentRevision > mutation.baseRevision) {
          revisionConflicts.push({
            entityKey: mutation.entityKey,
            expectedRevision: mutation.baseRevision,
            currentRevision,
          });
        }
      }
    }

    if (revisionConflicts.length > 0) {
      throw new SyncRequestError(
        409,
        `Revision conflict on ${revisionConflicts.map((c) => c.entityKey).join(", ")}.`,
        { code: "revision_conflict", conflicts: revisionConflicts },
      );
    }

    const startRevision = this.getRevision();
    let nextRevision = startRevision;
    const appliedKeys: string[] = [];
    const itemRevisions: Record<string, number> = {};

    for (const mutation of req.mutations) {
      const existing = existingByKey.get(mutation.entityKey);

      if (
        existing &&
        existing.content_hash === mutation.contentHash &&
        Boolean(existing.deleted) === mutation.deleted
      ) {
        itemRevisions[mutation.entityKey] = existing.revision;
        continue;
      }

      nextRevision += 1;
      this.sql.exec(
        `INSERT INTO items (
          entity_key, kind, revision, deleted, updated_at, content_hash, device_id, payload_inline, payload_blob_sha256
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(entity_key) DO UPDATE SET
          kind = excluded.kind,
          revision = excluded.revision,
          deleted = excluded.deleted,
          updated_at = excluded.updated_at,
          content_hash = excluded.content_hash,
          device_id = excluded.device_id,
          payload_inline = excluded.payload_inline,
          payload_blob_sha256 = excluded.payload_blob_sha256`,
        mutation.entityKey,
        mutation.kind,
        nextRevision,
        mutation.deleted ? 1 : 0,
        mutation.updatedAt,
        mutation.contentHash,
        req.deviceId,
        mutation.deleted ? null : (mutation.payload ?? null),
        mutation.deleted ? null : (mutation.payloadBlobSha256 ?? null),
      );
      appliedKeys.push(mutation.entityKey);
      itemRevisions[mutation.entityKey] = nextRevision;
    }

    const changed = nextRevision !== startRevision;
    if (changed) {
      this.sql.exec("UPDATE meta SET int_value = ? WHERE key = 'revision'", nextRevision);
    }

    return { revision: nextRevision, appliedKeys, itemRevisions, changed };
  }

  pullChanges(since: number, limit: number): PullResponse {
    const safeSince = Number.isFinite(since) && since >= 0 ? Math.floor(since) : 0;
    const safeLimit =
      Number.isFinite(limit) && limit >= 1
        ? Math.min(Math.floor(limit), MAX_PULL_LIMIT)
        : 100;

    const latestRevision = this.getRevision();
    const rows = this.sql
      .exec<ItemRow>(
        `SELECT entity_key, kind, revision, deleted, updated_at, content_hash, device_id, payload_inline, payload_blob_sha256
         FROM items
         WHERE revision > ?
         ORDER BY revision ASC
         LIMIT ?`,
        safeSince,
        safeLimit + 1,
      )
      .toArray();

    const hasMore = rows.length > safeLimit;
    const changes: SyncItemRecord[] = rows.slice(0, safeLimit).map((row) => ({
      entityKey: row.entity_key,
      kind: row.kind as SyncEntityKind,
      revision: row.revision,
      deleted: Boolean(row.deleted),
      updatedAt: row.updated_at,
      contentHash: row.content_hash,
      deviceId: row.device_id,
      payload: row.payload_inline,
      payloadBlobSha256: row.payload_blob_sha256,
    }));

    return { changes, latestRevision, hasMore };
  }
}
