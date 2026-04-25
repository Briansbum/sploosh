// Minimal AWS SigV4 signer for Workers (no aws-sdk dependency).
// Supports: EC2 (query API) and any service that uses the standard header auth.

const enc = new TextEncoder();

async function hmac(key: ArrayBuffer | Uint8Array, msg: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return crypto.subtle.sign("HMAC", k, enc.encode(msg));
}

async function sha256(data: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", enc.encode(data));
  return hex(buf);
}

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export interface AwsCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
  service: string;
}

export async function signRequest(
  req: Request,
  creds: AwsCredentials,
): Promise<Request> {
  const url = new URL(req.url);
  const now = new Date();
  const date = now.toISOString().slice(0, 10).replace(/-/g, ""); // YYYYMMDD
  const datetime = now.toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z"; // YYYYMMDDTHHmmssZ

  // Collect headers we'll sign
  const body = req.body ? await req.arrayBuffer() : new ArrayBuffer(0);
  const bodyHex = hex(await crypto.subtle.digest("SHA-256", body));

  const headers: Record<string, string> = {
    host: url.hostname,
    "x-amz-date": datetime,
    "x-amz-content-sha256": bodyHex,
  };

  // Copy existing headers
  req.headers.forEach((v, k) => {
    if (!["host", "x-amz-date", "x-amz-content-sha256"].includes(k.toLowerCase())) {
      headers[k.toLowerCase()] = v;
    }
  });

  const signedHeaderNames = Object.keys(headers).sort().join(";");
  const canonicalHeaders =
    Object.entries(headers)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${k}:${v.trim()}`)
      .join("\n") + "\n";

  // Canonical query string
  const sortedParams = [...url.searchParams.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");

  const canonicalRequest = [
    req.method,
    url.pathname || "/",
    sortedParams,
    canonicalHeaders,
    signedHeaderNames,
    bodyHex,
  ].join("\n");

  const credentialScope = `${date}/${creds.region}/${creds.service}/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    datetime,
    credentialScope,
    await sha256(canonicalRequest),
  ].join("\n");

  // Derive signing key
  const kDate = await hmac(enc.encode(`AWS4${creds.secretAccessKey}`), date);
  const kRegion = await hmac(kDate, creds.region);
  const kService = await hmac(kRegion, creds.service);
  const kSigning = await hmac(kService, "aws4_request");
  const signature = hex(await hmac(kSigning, stringToSign));

  const authHeader =
    `AWS4-HMAC-SHA256 ` +
    `Credential=${creds.accessKeyId}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaderNames}, ` +
    `Signature=${signature}`;

  const newHeaders = new Headers(req.headers);
  for (const [k, v] of Object.entries(headers)) {
    newHeaders.set(k, v);
  }
  newHeaders.set("Authorization", authHeader);

  return new Request(req.url, {
    method: req.method,
    headers: newHeaders,
    body: body.byteLength > 0 ? body : undefined,
  });
}
