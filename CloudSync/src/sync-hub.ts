import { DurableObject } from "cloudflare:workers";
import type { HealthResponse, PullResponse, PushResponse } from "./protocol.ts";
import { type SqlCursor, type SqlExecutor, type SqlValue, SyncStore } from "./sync-store.ts";

export class SyncHub extends DurableObject<Env> {
  private readonly store: SyncStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const executor: SqlExecutor = {
      exec: <T extends Record<string, SqlValue>>(query: string, ...bindings: SqlValue[]): SqlCursor<T> => {
        const cursor = this.ctx.storage.sql.exec<T>(query, ...bindings);
        return {
          one: () => cursor.one(),
          toArray: () => cursor.toArray(),
        };
      },
    };
    this.store = new SyncStore(executor);
    ctx.blockConcurrencyWhile(async () => {
      this.store.migrate();
    });
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  getHealth(): HealthResponse {
    return this.store.getHealth();
  }

  missingBlobs(hashes: unknown): string[] {
    return this.store.missingBlobs(hashes);
  }

  registerBlob(sha256: string, size: number): void {
    this.store.registerBlob(sha256, size);
  }

  hasBlob(sha256: string): boolean {
    return this.store.hasBlob(sha256);
  }

  pushMutations(rawRequest: unknown): PushResponse {
    const result = this.store.pushMutations(rawRequest);
    if (result.changed) {
      const sourceDeviceId =
        typeof (rawRequest as { deviceId?: unknown })?.deviceId === "string"
          ? (rawRequest as { deviceId: string }).deviceId
          : "";
      const notification = JSON.stringify({
        type: "sync",
        revision: result.revision,
        sourceDeviceId,
      });
      for (const socket of this.ctx.getWebSockets()) {
        try {
          socket.send(notification);
        } catch {
          // Ignore sockets already closing.
        }
      }
    }
    return { revision: result.revision, appliedKeys: result.appliedKeys };
  }

  pullChanges(since: number, limit: number): PullResponse {
    return this.store.pullChanges(since, limit);
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.send(
      JSON.stringify({
        type: "hello",
        revision: this.store.getRevision(),
      }),
    );
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    // Heartbeat "ping" -> "pong" is handled automatically via setWebSocketAutoResponse.
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, "WebSocket error");
    } catch {
      // Already closed.
    }
  }
}
