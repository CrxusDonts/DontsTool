import { timingSafeEqual } from "node:crypto";

const encoder = new TextEncoder();

export async function sha256Bytes(value: string | ArrayBuffer | Uint8Array): Promise<ArrayBuffer> {
  const input = typeof value === "string" ? encoder.encode(value) : value;
  return await crypto.subtle.digest("SHA-256", input);
}

export async function sha256Hex(value: string | ArrayBuffer | Uint8Array): Promise<string> {
  const digest = new Uint8Array(await sha256Bytes(value));
  let hex = "";
  for (const byte of digest) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}

export async function verifyBearerToken(
  authHeader: string | null,
  expectedToken: string | undefined,
): Promise<boolean> {
  if (!expectedToken || !authHeader) {
    return false;
  }
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  if (!match) {
    return false;
  }
  const provided = match[1].trim();
  if (!provided) {
    return false;
  }
  const [actualDigest, expectedDigest] = await Promise.all([
    sha256Bytes(provided),
    sha256Bytes(expectedToken),
  ]);
  return timingSafeEqual(new Uint8Array(actualDigest), new Uint8Array(expectedDigest));
}
