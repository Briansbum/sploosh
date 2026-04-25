// Discord interaction signature verification using ed25519 (Web Crypto API).

export async function verifyDiscordRequest(
  req: Request,
  publicKey: string,
): Promise<{ valid: boolean; body: string }> {
  const signature = req.headers.get("x-signature-ed25519");
  const timestamp = req.headers.get("x-signature-timestamp");

  if (!signature || !timestamp) {
    return { valid: false, body: "" };
  }

  const body = await req.text();

  const keyBytes = hexToUint8Array(publicKey);
  const sigBytes = hexToUint8Array(signature);
  const message = new TextEncoder().encode(timestamp + body);

  try {
    const key = await crypto.subtle.importKey(
      "raw",
      keyBytes,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify("Ed25519", key, sigBytes, message);
    return { valid, body };
  } catch {
    return { valid: false, body: "" };
  }
}

function hexToUint8Array(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}
