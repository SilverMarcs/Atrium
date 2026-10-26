/**
 * Sends alerts through Apple Push Notification service with a token-based
 * (.p8) provider key. Workers reach APNs over HTTP/2, which it requires.
 */

export interface APNsEnv {
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC: string;
}

export type APNsEnvironment = "sandbox" | "production";
export type DeliveryResult = "sent" | "unregistered" | "failed";

const encoder = new TextEncoder();
const maxPayloadBytes = 4096;

// Apple rejects provider tokens older than an hour and throttles ones
// refreshed more often than every 20 minutes, so one is kept per isolate.
let cachedToken: { token: string; expires: number } | undefined;

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function providerToken(env: APNsEnv): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now < cachedToken.expires) return cachedToken.token;
  const pem = env.APNS_PRIVATE_KEY?.replaceAll("\\n", "\n");
  if (!pem || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) throw new Error("APNs credentials are missing");
  const der = Uint8Array.from(atob(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "")), char => char.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const unsigned = `${header}.${claims}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(unsigned));
  const token = `${unsigned}.${base64url(signature)}`;
  cachedToken = { token, expires: now + 50 * 60 };
  return token;
}

/**
 * Delivers one alert. A token from the other environment (a debug build's
 * token sent to production, say) is retried there before giving up on it.
 */
export async function deliver(
  env: APNsEnv,
  deviceToken: string,
  environment: APNsEnvironment,
  payload: object,
  collapseID?: string,
): Promise<DeliveryResult> {
  const body = JSON.stringify(payload);
  if (encoder.encode(body).length > maxPayloadBytes) throw new Error("APNs payload exceeds 4096 bytes");
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken(env)}`,
    "apns-topic": env.APNS_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  };
  if (collapseID) headers["apns-collapse-id"] = collapseID;

  for (const attempt of [environment, environment === "sandbox" ? "production" : "sandbox"]) {
    const host = attempt === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST", headers, body, redirect: "manual", signal: AbortSignal.timeout(15000),
    });
    if (response.ok) return "sent";
    const reason = ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
    if (response.status === 410) return "unregistered";
    if (response.status === 400 && reason === "BadDeviceToken") continue;
    console.error("APNs delivery failed", response.status, reason ?? "unknown");
    return "failed";
  }
  return "unregistered";
}
