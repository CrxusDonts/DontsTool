export const MAX_BLOB_BYTES = 20 * 1024 * 1024;
export const INLINE_PAYLOAD_LIMIT = 65_536;
export const MAX_MUTATIONS_PER_PUSH = 200;
export const MAX_PULL_LIMIT = 200;
export const SHA256_HEX_RE = /^[0-9a-f]{64}$/;
export const ENTITY_KEY_RE = /^(config:(websites|searchEngines|settings)|note:[0-9A-Fa-f-]{36})$/;

export type SyncEntityKind = "config" | "note";

export interface SyncMutationInput {
  entityKey: string;
  kind: SyncEntityKind;
  deleted: boolean;
  updatedAt: string;
  contentHash: string;
  payload?: string | null;
  payloadBlobSha256?: string | null;
}

export interface SyncItemRecord {
  entityKey: string;
  kind: SyncEntityKind;
  revision: number;
  deleted: boolean;
  updatedAt: string;
  contentHash: string;
  deviceId: string;
  payload?: string | null;
  payloadBlobSha256?: string | null;
}

export interface PushRequest {
  deviceId: string;
  mutations: SyncMutationInput[];
}

export interface PushResponse {
  revision: number;
  appliedKeys: string[];
}

export interface PullResponse {
  changes: SyncItemRecord[];
  latestRevision: number;
  hasMore: boolean;
}

export interface HealthResponse {
  ok: true;
  revision: number;
  itemCount: number;
  serverTime: string;
}

export class SyncRequestError extends Error {
  readonly statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.statusCode = statusCode;
  }
}

const textEncoder = new TextEncoder();

export function utf8ByteLength(text: string): number {
  return textEncoder.encode(text).byteLength;
}

export function isValidSha256(value: unknown): value is string {
  return typeof value === "string" && SHA256_HEX_RE.test(value);
}

export function expectedKindForEntityKey(entityKey: string): SyncEntityKind | null {
  if (!ENTITY_KEY_RE.test(entityKey)) {
    return null;
  }
  return entityKey.startsWith("note:") ? "note" : "config";
}

export function validatePushRequest(req: unknown): PushRequest {
  if (!req || typeof req !== "object") {
    throw new SyncRequestError(400, "Invalid JSON request body.");
  }
  const candidate = req as Partial<PushRequest>;
  if (typeof candidate.deviceId !== "string" || !candidate.deviceId.trim() || candidate.deviceId.length > 128) {
    throw new SyncRequestError(400, "Invalid deviceId.");
  }
  if (!Array.isArray(candidate.mutations) || candidate.mutations.length > MAX_MUTATIONS_PER_PUSH) {
    throw new SyncRequestError(400, `mutations must be an array of at most ${MAX_MUTATIONS_PER_PUSH} items.`);
  }
  for (const item of candidate.mutations) {
    validateMutation(item);
  }
  return {
    deviceId: candidate.deviceId.trim(),
    mutations: candidate.mutations,
  };
}

function validateMutation(item: unknown): asserts item is SyncMutationInput {
  if (!item || typeof item !== "object") {
    throw new SyncRequestError(400, "Each mutation must be an object.");
  }
  const m = item as Partial<SyncMutationInput>;
  if (typeof m.entityKey !== "string") {
    throw new SyncRequestError(400, "entityKey is required.");
  }
  const expectedKind = expectedKindForEntityKey(m.entityKey);
  if (!expectedKind || m.kind !== expectedKind) {
    throw new SyncRequestError(400, `Invalid entityKey or kind for "${m.entityKey}".`);
  }
  if (typeof m.deleted !== "boolean") {
    throw new SyncRequestError(400, `deleted must be a boolean for "${m.entityKey}".`);
  }
  if (typeof m.updatedAt !== "string" || !m.updatedAt.trim() || m.updatedAt.length > 64) {
    throw new SyncRequestError(400, `Invalid updatedAt for "${m.entityKey}".`);
  }
  if (!isValidSha256(m.contentHash)) {
    throw new SyncRequestError(400, `Invalid contentHash for "${m.entityKey}".`);
  }

  const hasInline = typeof m.payload === "string";
  const hasBlobRef = typeof m.payloadBlobSha256 === "string" && m.payloadBlobSha256.length > 0;

  if (m.deleted) {
    if (hasInline || hasBlobRef) {
      throw new SyncRequestError(400, `Deleted item "${m.entityKey}" must not include payload.`);
    }
    return;
  }

  if (hasInline === hasBlobRef) {
    throw new SyncRequestError(
      400,
      `Active item "${m.entityKey}" must include exactly one of inline payload or payloadBlobSha256.`,
    );
  }
  if (hasInline && utf8ByteLength(m.payload as string) > INLINE_PAYLOAD_LIMIT) {
    throw new SyncRequestError(
      400,
      `Inline payload for "${m.entityKey}" exceeds ${INLINE_PAYLOAD_LIMIT} bytes; upload as blob instead.`,
    );
  }
  if (hasBlobRef && !isValidSha256(m.payloadBlobSha256)) {
    throw new SyncRequestError(400, `Invalid payloadBlobSha256 for "${m.entityKey}".`);
  }
}
