/**
 * The MCP gateway: ChatGPT's way to a Mac's Atrium tools, over HTTPS with OAuth.
 *
 *   GET  /.well-known/oauth-protected-resource   What protects /mcp, for ChatGPT to find the server below.
 *   GET  /.well-known/oauth-authorization-server The OAuth server: dynamic registration, PKCE codes, refresh.
 *   POST /oauth/register                         Registers ChatGPT as a client.
 *   GET  /oauth/authorize                        A page that opens Atrium on the Mac to approve the connection.
 *   POST /oauth/approve                          Atrium, once the user approved, hands over the device it paired.
 *   POST /oauth/token                            Codes and refresh tokens for access tokens.
 *   POST /mcp                                    One MCP message, answered by the Mac.
 *
 * The gateway keeps nothing. What it issues (client IDs, codes and tokens) is
 * sealed with its own key and carries what it stands for: the Mac's ID and
 * public key, and the device and token Atrium paired for ChatGPT. Each MCP
 * message opens a connection to the Mac's relay room as that device, the way
 * an iPhone does, encrypted against the Mac's key from here on; the Mac
 * decides what the device may call and answers, and the connection closes.
 * The gateway itself reads ChatGPT's messages and acts as the device, which
 * is why the Mac bounds the device by the access the user approved. Removing
 * the device in Atrium's Settings revokes every token for it.
 */

import { NoiseInitiator, type CipherState } from "./noise";

export interface GatewayEnv {
  ROOMS: DurableObjectNamespace;
  /** 32 random bytes, base64url, that seal what the gateway issues. */
  GATEWAY_KEY: string;
  /** Comma-separated hosts OAuth may redirect to: ChatGPT's. */
  REDIRECT_HOSTS: string;
}

/** What a token stands for: a device Atrium paired, on one Mac. */
interface Grant {
  hostID: string;
  publicKey: string;
  deviceID: string;
  token: string;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const accessLifetime = 30 * 24 * 3600;
const requestLifetime = 15 * 60;
const codeLifetime = 5 * 60;
/** Longer than the longest wait a tool takes, a minute. */
const macTimeout = 90_000;
const hostIDPattern = /^[A-Za-z0-9_-]{16,64}$/;

export function isGatewayPath(pathname: string): boolean {
  return pathname === "/mcp" || pathname.startsWith("/oauth/") || pathname.startsWith("/.well-known/oauth-");
}

export async function handleGateway(request: Request, env: GatewayEnv): Promise<Response> {
  const url = new URL(request.url);
  const origin = url.origin;
  try {
    switch (`${request.method} ${url.pathname}`) {
      case "GET /.well-known/oauth-protected-resource":
      case "GET /.well-known/oauth-protected-resource/mcp":
        return json({ resource: `${origin}/mcp`, authorization_servers: [origin], bearer_methods_supported: ["header"] });
      case "GET /.well-known/oauth-authorization-server":
        return json({
          issuer: origin,
          authorization_endpoint: `${origin}/oauth/authorize`,
          token_endpoint: `${origin}/oauth/token`,
          registration_endpoint: `${origin}/oauth/register`,
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"],
        });
      case "POST /oauth/register":
        return await register(request, env);
      case "GET /oauth/authorize":
        return await authorize(url, env);
      case "POST /oauth/approve":
        return await approve(request, env);
      case "POST /oauth/token":
        return await token(request, env);
      case "POST /mcp":
        return await mcp(request, env, origin);
      case "GET /mcp":
        return new Response("Send MCP messages with POST.", { status: 405, headers: { Allow: "POST" } });
      default:
        return new Response("Not found", { status: 404 });
    }
  } catch (error) {
    if (error instanceof OAuthError) return json({ error: error.code, error_description: error.message }, error.status);
    console.error("Gateway error", error instanceof Error ? error.message : "unknown");
    return json({ error: "server_error" }, 500);
  }
}

// MARK: - OAuth

class OAuthError extends Error {
  constructor(readonly code: string, message: string, readonly status = 400) { super(message); }
}

function allowedRedirect(uri: string, env: GatewayEnv): boolean {
  try {
    const url = new URL(uri);
    const hosts = env.REDIRECT_HOSTS.split(",").map(host => host.trim()).filter(Boolean);
    const isLocal = url.hostname === "127.0.0.1" || url.hostname === "localhost";
    return (url.protocol === "https:" || (isLocal && url.protocol === "http:")) && hosts.includes(url.hostname);
  } catch {
    return false;
  }
}

async function register(request: Request, env: GatewayEnv): Promise<Response> {
  const body = await request.json<{ redirect_uris?: unknown; client_name?: unknown }>().catch(() => ({}) as Record<string, unknown>);
  const uris = Array.isArray(body.redirect_uris) ? body.redirect_uris.filter((uri): uri is string => typeof uri === "string") : [];
  if (!uris.length || !uris.every(uri => allowedRedirect(uri, env))) {
    throw new OAuthError("invalid_redirect_uri", "Only ChatGPT can connect to Atrium.");
  }
  const name = typeof body.client_name === "string" ? body.client_name.slice(0, 100) : "ChatGPT";
  const clientID = await seal(env, { kind: "client", uris, name });
  return json({
    client_id: clientID, client_name: name, redirect_uris: uris, client_id_issued_at: Math.floor(Date.now() / 1000),
    token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"],
  }, 201);
}

async function client(env: GatewayEnv, clientID: string | null): Promise<{ uris: string[]; name: string }> {
  const sealed = clientID ? await unseal(env, clientID, "client") : undefined;
  if (!sealed) throw new OAuthError("invalid_client", "Unknown client.", 401);
  return sealed as { uris: string[]; name: string };
}

/** The page ChatGPT opens to connect: it hands the request to Atrium on the Mac. */
async function authorize(url: URL, env: GatewayEnv): Promise<Response> {
  const params = url.searchParams;
  const registered = await client(env, params.get("client_id"));
  const redirect = params.get("redirect_uri") ?? "";
  if (!registered.uris.includes(redirect)) throw new OAuthError("invalid_request", "That redirect isn't registered.");
  if (params.get("response_type") !== "code") throw new OAuthError("unsupported_response_type", "Only codes are issued.");
  const challenge = params.get("code_challenge");
  if (!challenge || params.get("code_challenge_method") !== "S256") throw new OAuthError("invalid_request", "PKCE with S256 is required.");
  const sealed = await seal(env, {
    kind: "request", redirect, state: params.get("state"), challenge, name: registered.name,
    expires: now() + requestLifetime,
  });
  const link = `atrium://agent?request=${encodeURIComponent(sealed)}`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect ${escapeHTML(registered.name)} to Atrium</title>
<style>body{font:16px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#222}
@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}}a.button{display:inline-block;padding:.6rem 1.2rem;border-radius:.6rem;background:#2f7d4f;color:#fff;text-decoration:none}</style>
</head><body><h1>Connect ${escapeHTML(registered.name)} to Atrium</h1>
<p>Open Atrium on your Mac, choose what ${escapeHTML(registered.name)} may do there, from reading sessions to handing them work, and approve. You can remove it any time in Atrium Settings → Remote.</p>
<p><a class="button" href="${escapeHTML(link)}">Open Atrium</a></p>
<p><small>Open this page on the Mac where Atrium runs. The request expires in 15 minutes.</small></p></body></html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
}

/** Atrium approved: it sends the device it paired for the request, and opens the redirect it gets back. */
async function approve(request: Request, env: GatewayEnv): Promise<Response> {
  const body = await request.json<{ request?: string; grant?: Partial<Grant> }>().catch(() => ({}) as { request?: string; grant?: Partial<Grant> });
  const pending = body.request ? await unseal(env, body.request, "request") : undefined;
  if (!pending || (pending.expires as number) < now()) throw new OAuthError("invalid_request", "This request has expired. Connect again from ChatGPT.");
  const grant = body.grant;
  if (!grant || typeof grant.hostID !== "string" || !hostIDPattern.test(grant.hostID) || typeof grant.publicKey !== "string"
      || typeof grant.deviceID !== "string" || typeof grant.token !== "string") {
    throw new OAuthError("invalid_request", "The approval is missing its device.");
  }
  const code = await seal(env, {
    kind: "code", grant: { hostID: grant.hostID, publicKey: grant.publicKey, deviceID: grant.deviceID, token: grant.token },
    redirect: pending.redirect, challenge: pending.challenge, expires: now() + codeLifetime,
  });
  const redirect = new URL(pending.redirect as string);
  redirect.searchParams.set("code", code);
  if (typeof pending.state === "string") redirect.searchParams.set("state", pending.state);
  return json({ redirect: redirect.toString() });
}

async function token(request: Request, env: GatewayEnv): Promise<Response> {
  const form = await request.formData();
  const field = (name: string) => { const value = form.get(name); return typeof value === "string" ? value : null; };
  let grant: Grant;
  let refresh: string;
  switch (field("grant_type")) {
    case "authorization_code": {
      const code = await unseal(env, field("code") ?? "", "code");
      if (!code || (code.expires as number) < now()) throw new OAuthError("invalid_grant", "The code has expired.");
      if (field("redirect_uri") !== null && field("redirect_uri") !== code.redirect) throw new OAuthError("invalid_grant", "The redirect doesn't match.");
      const verifier = field("code_verifier") ?? "";
      const challenge = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(verifier))));
      if (challenge !== code.challenge) throw new OAuthError("invalid_grant", "The code verifier doesn't match.");
      grant = code.grant as Grant;
      refresh = await seal(env, { kind: "refresh", grant });
      break;
    }
    case "refresh_token": {
      refresh = field("refresh_token") ?? "";
      const sealed = await unseal(env, refresh, "refresh");
      if (!sealed) throw new OAuthError("invalid_grant", "Unknown refresh token.");
      grant = sealed.grant as Grant;
      break;
    }
    default:
      throw new OAuthError("unsupported_grant_type", "Use authorization_code or refresh_token.");
  }
  const access = await seal(env, { kind: "access", grant, expires: now() + accessLifetime });
  return json({ access_token: access, token_type: "Bearer", expires_in: accessLifetime, refresh_token: refresh });
}

// MARK: - MCP

async function mcp(request: Request, env: GatewayEnv, origin: string): Promise<Response> {
  const bearer = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const access = bearer ? await unseal(env, bearer, "access") : undefined;
  const unauthorized = () => new Response(JSON.stringify({ error: "invalid_token" }), {
    status: 401,
    headers: {
      "Content-Type": "application/json",
      "WWW-Authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource", error="invalid_token"`,
    },
  });
  if (!access || (access.expires as number) < now()) return unauthorized();
  const body = await request.text();
  let message: { id?: unknown };
  try { message = JSON.parse(body); } catch { return rpcError(null, -32700, "Parse error"); }
  // Notifications need nothing from the Mac.
  if (message.id === undefined) return new Response(null, { status: 202 });
  try {
    const reply = await callMac(env, access.grant as Grant, encoder.encode(body));
    return new Response(reply, { headers: { "Content-Type": "application/json" } });
  } catch (error) {
    if (error instanceof MacError && error.revoked) return unauthorized();
    if (!(error instanceof MacError)) console.error("Reaching the Mac failed", error instanceof Error ? error.message : "unknown");
    return rpcError(message.id, -32000, error instanceof MacError ? error.message : "Atrium on the Mac didn't answer.");
  }
}

class MacError extends Error {
  constructor(message: string, readonly revoked = false) { super(message); }
}

const offline = "Atrium on the Mac isn't reachable. Make sure the Mac is awake, with Atrium running and remote access on.";

/** Sends one MCP message to the Mac as the paired device, and returns its answer. */
async function callMac(env: GatewayEnv, grant: Grant, message: Uint8Array): Promise<Uint8Array> {
  if (!hostIDPattern.test(grant.hostID)) throw new MacError("This connection names no Mac.", true);
  const room = env.ROOMS.get(env.ROOMS.idFromName(grant.hostID));
  const upgrade = await room.fetch(`https://relay/v1/phone/${grant.hostID}`, { headers: { Upgrade: "websocket" } });
  const socket = upgrade.webSocket;
  if (!socket) throw new MacError(offline);
  socket.accept();
  const inbox = new Inbox(socket);
  const timer = setTimeout(() => inbox.fail(new MacError(offline)), macTimeout);
  try {
    // The relay says "ready" once the Mac picks the connection up, or "offline" when it isn't there.
    for (;;) {
      const next = await inbox.next();
      if (next === "ready") break;
      if (next === "offline") throw new MacError(offline);
    }
    const noise = await NoiseInitiator.start(decodeBase64url(grant.publicKey), encoder.encode(`atrium-companion-relay-v1:${grant.hostID}`));
    socket.send(await noise.firstMessage());
    const [send, receive] = await noise.finish(await inbox.nextBinary());
    const frames = new Frames(socket, inbox, send, receive);
    const authentication = await frames.request({ authenticate: { token: grant.token, deviceID: grant.deviceID } });
    if (authentication.failed) throw new MacError(String(authentication.failed.message ?? "Revoked"), true);
    const reply = await frames.request({ mcp: { message: base64(message) } });
    if (reply.failed) throw new MacError(String(reply.failed.message ?? "Atrium couldn't answer."));
    if (typeof reply.mcp?.message !== "string") throw new MacError("Atrium on the Mac needs an update to answer ChatGPT.");
    return decodeBase64(reply.mcp.message);
  } finally {
    clearTimeout(timer);
    try { socket.close(1000, "Done"); } catch { /* Already closed. */ }
  }
}

/** A WebSocket's messages, one at a time. */
class Inbox {
  private queue: (string | Uint8Array)[] = [];
  private waiting?: { resolve: (value: string | Uint8Array) => void; reject: (error: Error) => void };
  private error?: Error;

  constructor(socket: WebSocket) {
    // A socket from a room's fetch can deliver binary messages as Blobs, read in turn so they keep their order.
    let reading = Promise.resolve();
    socket.addEventListener("message", event => {
      const raw = event.data as string | ArrayBuffer | Blob;
      reading = reading.then(async () => {
        const data = typeof raw === "string" ? raw : new Uint8Array(raw instanceof Blob ? await raw.arrayBuffer() : raw);
        if (this.waiting) { this.waiting.resolve(data); this.waiting = undefined; } else this.queue.push(data);
      });
    });
    socket.addEventListener("close", () => this.fail(new MacError(offline)));
    socket.addEventListener("error", () => this.fail(new MacError(offline)));
  }

  fail(error: Error): void {
    this.error ??= error;
    this.waiting?.reject(this.error);
    this.waiting = undefined;
  }

  next(): Promise<string | Uint8Array> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    if (this.error) return Promise.reject(this.error);
    return new Promise((resolve, reject) => { this.waiting = { resolve, reject }; });
  }

  /** The next sealed message, past any keep-alive answers. */
  async nextBinary(): Promise<Uint8Array> {
    for (;;) {
      const next = await this.next();
      if (typeof next !== "string") return next;
    }
  }
}

// deno-lint-ignore no-explicit-any
type Reply = Record<string, any>;

/** Requests and replies as Atrium frames them: JSON, one per sealed message. */
class Frames {
  private nextID = 0;

  constructor(
    private readonly socket: WebSocket, private readonly inbox: Inbox,
    private readonly send: CipherState, private readonly receive: CipherState,
  ) {}

  async request(request: object): Promise<Reply> {
    const id = ++this.nextID;
    this.socket.send(this.send.encrypt(encoder.encode(JSON.stringify({ id, request }))));
    for (;;) {
      const frame = JSON.parse(decoder.decode(this.receive.decrypt(await this.inbox.nextBinary())));
      // Events, such as the hello every connection starts with, carry no ID.
      if (frame.id === id) return frame.reply ?? {};
    }
  }
}

// MARK: - Sealing

async function key(env: GatewayEnv): Promise<CryptoKey> {
  const bytes = decodeBase64url(env.GATEWAY_KEY ?? "");
  if (bytes.length !== 32) throw new Error("GATEWAY_KEY must be 32 bytes, base64url.");
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function seal(env: GatewayEnv, value: { kind: string } & Record<string, unknown>): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(env), encoder.encode(JSON.stringify(value))));
  const out = new Uint8Array(iv.length + sealed.length);
  out.set(iv);
  out.set(sealed, iv.length);
  return base64url(out);
}

async function unseal(env: GatewayEnv, text: string, kind: string): Promise<Record<string, unknown> | undefined> {
  try {
    const bytes = decodeBase64url(text);
    const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, await key(env), bytes.slice(12));
    const value = JSON.parse(decoder.decode(opened));
    return value?.kind === kind ? value : undefined;
  } catch {
    return undefined;
  }
}

// MARK: - Helpers

function now(): number {
  return Math.floor(Date.now() / 1000);
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

function rpcError(id: unknown, code: number, message: string): Response {
  return json({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
}

function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, char => `&#${char.charCodeAt(0)};`);
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

function base64url(bytes: Uint8Array): string {
  return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function decodeBase64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), char => char.charCodeAt(0));
}

function decodeBase64url(text: string): Uint8Array {
  const padded = text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return decodeBase64(padded);
}
