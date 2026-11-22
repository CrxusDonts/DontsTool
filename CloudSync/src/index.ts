import { sha256Bytes, sha256Hex, verifyBearerToken } from "./auth.ts";
import { MAX_BLOB_BYTES, SyncRequestError, isValidSha256 } from "./protocol.ts";
import { SyncHub } from "./sync-hub.ts";

export { SyncHub };

function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

async function readJsonBody(request: Request, maxBytes = 8 * 1024 * 1024): Promise<unknown> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader) {
    const parsed = Number(lengthHeader);
    if (Number.isFinite(parsed) && parsed > maxBytes) {
      throw new SyncRequestError(413, "Request payload too large.");
    }
  }
  const buffer = await request.arrayBuffer();
  if (buffer.byteLength > maxBytes) {
    throw new SyncRequestError(413, "Request payload too large.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(buffer));
  } catch {
    throw new SyncRequestError(400, "Invalid JSON body.");
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const authorized = await verifyBearerToken(
        request.headers.get("authorization"),
        env.SYNC_TOKEN,
      );
      if (!authorized) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }

      const url = new URL(request.url);
      const stub = env.SYNC_HUB.getByName("default");

      if (request.method === "GET" && url.pathname === "/v1/health") {
        return jsonResponse(await stub.getHealth());
      }

      if (request.method === "POST" && url.pathname === "/v1/blobs/check") {
        const body = (await readJsonBody(request, 256 * 1024)) as { hashes?: unknown };
        const missing = await stub.missingBlobs(body?.hashes);
        return jsonResponse({ missing });
      }

      const blobMatch = /^\/v1\/blobs\/([0-9a-f]{64})$/.exec(url.pathname);
      if (blobMatch) {
        const sha256 = blobMatch[1];
        if (!isValidSha256(sha256)) {
          throw new SyncRequestError(400, "Invalid blob SHA-256.");
        }

        if (request.method === "PUT") {
          const lengthHeader = request.headers.get("content-length");
          if (lengthHeader) {
            const declared = Number(lengthHeader);
            if (Number.isFinite(declared) && declared > MAX_BLOB_BYTES) {
              throw new SyncRequestError(413, "Blob exceeds maximum size.");
            }
          }
          const data = await request.arrayBuffer();
          if (data.byteLength === 0 || data.byteLength > MAX_BLOB_BYTES) {
            throw new SyncRequestError(413, "Blob size must be between 1 byte and 20 MiB.");
          }
          const actualDigest = await sha256Bytes(data);
          const actualHex = await sha256Hex(data);
          if (actualHex !== sha256) {
            throw new SyncRequestError(400, "Blob SHA-256 mismatch.");
          }
          await env.SYNC_BUCKET.put(`blobs/${sha256}`, data, {
            sha256: actualDigest,
            httpMetadata: { contentType: "application/octet-stream" },
          });
          await stub.registerBlob(sha256, data.byteLength);
          return jsonResponse({ ok: true, sha256, size: data.byteLength });
        }

        if (request.method === "GET") {
          const object = await env.SYNC_BUCKET.get(`blobs/${sha256}`);
          if (!object) {
            return jsonResponse({ error: "Blob not found" }, 404);
          }
          return new Response(object.body, {
            status: 200,
            headers: {
              "content-type": "application/octet-stream",
              "cache-control": "private, max-age=31536000, immutable",
            },
          });
        }
      }

      if (request.method === "POST" && url.pathname === "/v1/sync/push") {
        const body = await readJsonBody(request);
        const result = await stub.pushMutations(body);
        return jsonResponse(result);
      }

      if (request.method === "GET" && url.pathname === "/v1/sync/pull") {
        const since = Number(url.searchParams.get("since") ?? "0");
        const limit = Number(url.searchParams.get("limit") ?? "100");
        const result = await stub.pullChanges(since, limit);
        return jsonResponse(result);
      }

      if (request.method === "GET" && url.pathname === "/v1/ws") {
        return await stub.fetch(request);
      }

      return jsonResponse({ error: "Not found" }, 404);
    } catch (error) {
      if (error instanceof SyncRequestError) {
        return jsonResponse({ error: error.message, ...(error.details ?? {}) }, error.statusCode);
      }
      console.error("CloudSync worker error:", error);
      return jsonResponse({ error: "Internal server error" }, 500);
    }
  },
};
