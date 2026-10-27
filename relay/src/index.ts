/**
 * Atrium relay: joins an iPhone to a Mac when neither can reach the other directly,
 * and sends the Mac's task alerts to its phones through APNs.
 *
 * Both ends connect out over WebSockets, so the Mac needs no open ports. Each Mac
 * has a room (a Durable Object named by its Mac ID):
 *
 *   GET /v1/mac/:macID            The Mac's control connection. Told of each phone,
 *                                 and carries the Mac's push requests.
 *   GET /v1/phone/:macID          A phone arriving. Gets "ready" once the Mac picks it
 *                                 up, or "offline" if the Mac isn't connected.
 *   GET /v1/mac/:macID/data/:id   The Mac's connection for that phone.
 *
 * A Mac proves it owns its ID with a secret whose hash is the ID, so nobody else
 * can take its room. After "ready", the room forwards every message between a
 * phone and its data connection unchanged. They're end-to-end encrypted (Noise
 * NK), so the relay can neither read them nor pose as the Mac. Rooms use
 * WebSocket hibernation, so idle connections cost nothing.
 */

import { type APNsEnv, type APNsEnvironment, deliver } from "./apns";

interface Env extends APNsEnv {
  ROOMS: DurableObjectNamespace;
}

/** A task alert the Mac asks the relay to send to one of its phones. */
interface PushRequest {
  type: "push";
  token: string;
  environment: APNsEnvironment;
  title: string;
  body: string;
  taskID: string;
  hostID?: string;
}

const route = /^\/v1\/(mac|phone)\/([A-Za-z0-9_-]{16,64})(?:\/data\/([A-Za-z0-9-]{1,64}))?$/;
const encoder = new TextEncoder();
/** Bounds the alerts one Mac can send, should its secret ever leak. */
const maxPushesPerHour = 300;

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function decodeBase64url(text: string): Uint8Array | undefined {
  try {
    const padded = text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (text.length % 4)) % 4);
    return Uint8Array.from(atob(padded), char => char.charCodeAt(0));
  } catch {
    return undefined;
  }
}

/** The Mac ID is the first 16 bytes of the SHA-256 of the Mac's relay secret. */
async function isOwner(request: Request, macID: string): Promise<boolean> {
  const secret = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const bytes = secret ? decodeBase64url(secret) : undefined;
  if (!bytes || bytes.length !== 32) return false;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return base64url(new Uint8Array(digest).slice(0, 16)) === macID;
}

function isPushRequest(value: unknown): value is PushRequest {
  const push = value as PushRequest;
  return !!push && push.type === "push"
    && typeof push.token === "string" && /^[0-9a-f]{32,256}$/i.test(push.token)
    && (push.environment === "sandbox" || push.environment === "production")
    && typeof push.title === "string" && push.title.length <= 1000
    && typeof push.body === "string" && push.body.length > 0 && push.body.length <= 1000
    && typeof push.taskID === "string" && push.taskID.length <= 256;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const match = new URL(request.url).pathname.match(route);
    if (!match || (match[1] === "phone" && match[3])) {
      return new Response("Atrium relay", { status: 404 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426 });
    }
    if (match[1] === "mac" && !(await isOwner(request, match[2]))) {
      return new Response("Unauthorized", { status: 401 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[2]));
    return room.fetch(request);
  },
};

export class Room implements DurableObject {
  private pushWindow = { start: 0, count: 0 };

  constructor(private readonly state: DurableObjectState, private readonly env: Env) {
    // Keep-alive pings are answered without waking the room.
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const [, role, hostID, dataID] = new URL(request.url).pathname.match(route) ?? [];
    const { 0: client, 1: server } = new WebSocketPair();

    if (role === "mac" && !dataID) {
      // A Mac reconnecting replaces its previous control connection.
      for (const old of this.state.getWebSockets("control")) old.close(1000, "Replaced");
      this.state.acceptWebSocket(server, ["control", `host:${hostID}`]);
    } else if (role === "mac" && dataID) {
      const [phone] = this.state.getWebSockets(`phone:${dataID}`);
      if (!phone) return new Response("No phone is waiting", { status: 404 });
      this.state.acceptWebSocket(server, [`data:${dataID}`]);
      phone.send("ready");
    } else {
      const [control] = this.state.getWebSockets("control");
      if (!control) {
        this.state.acceptWebSocket(server, []);
        server.send("offline");
        server.close(4004, "Mac offline");
      } else {
        const id = crypto.randomUUID();
        this.state.acceptWebSocket(server, [`phone:${id}`]);
        control.send(JSON.stringify({ type: "connect", id }));
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (this.state.getTags(socket).includes("control")) {
      await this.handleControl(socket, message);
      return;
    }
    const peer = this.peer(socket);
    if (peer && peer.readyState === WebSocket.OPEN) peer.send(message);
  }

  webSocketClose(socket: WebSocket, code: number, reason: string): void {
    this.closePeer(socket, code, reason);
  }

  webSocketError(socket: WebSocket): void {
    this.closePeer(socket, 1011, "Connection error");
  }

  /** The Mac's control connection only carries push requests. */
  private async handleControl(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    let push: unknown;
    try {
      push = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      return;
    }
    if (!isPushRequest(push) || !this.allowPush()) return;
    // Bind routing to the authenticated control socket. Older live sockets
    // predate the host tag, so updated Macs also supply their identity.
    const hostID = this.state.getTags(socket).find(tag => tag.startsWith("host:"))?.slice(5)
      ?? (typeof push.hostID === "string" && /^[A-Za-z0-9_-]{16,64}$/.test(push.hostID) ? push.hostID : undefined);
    const destination = hostID ? `${hostID}:${push.taskID}` : push.taskID;
    const collapseID = base64url(await crypto.subtle.digest("SHA-256", encoder.encode(destination)));
    const payload = {
      aps: { alert: { title: push.title, body: push.body }, sound: "default", "thread-id": destination },
      taskID: push.taskID,
      hostID,
    };
    // A long chat title now appears twice. Fit APNs' byte limit by shortening
    // only the heading, preserving the body and routing and whole code points.
    const title = Array.from(push.title);
    while (encoder.encode(JSON.stringify(payload)).length > 4096 && title.length) {
      title.pop();
      payload.aps.alert.title = title.join("");
    }
    try {
      const result = await deliver(this.env, push.token, push.environment, payload, collapseID);
      if (result === "unregistered" && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ type: "pushUnregistered", token: push.token }));
      }
    } catch (error) {
      console.error("Push failed", error instanceof Error ? error.message : "unknown");
    }
  }

  private allowPush(): boolean {
    const now = Date.now();
    if (now - this.pushWindow.start > 3_600_000) this.pushWindow = { start: now, count: 0 };
    this.pushWindow.count += 1;
    return this.pushWindow.count <= maxPushesPerHour;
  }

  /** A phone's data connection, or a data connection's phone. */
  private peer(socket: WebSocket): WebSocket | undefined {
    for (const tag of this.state.getTags(socket)) {
      const [kind, id] = tag.split(":");
      if (kind === "phone") return this.state.getWebSockets(`data:${id}`)[0];
      if (kind === "data") return this.state.getWebSockets(`phone:${id}`)[0];
    }
    return undefined;
  }

  private closePeer(socket: WebSocket, code: number, reason: string): void {
    const peer = this.peer(socket);
    if (peer && peer.readyState === WebSocket.OPEN) {
      peer.close(code >= 1000 && code < 5000 && code !== 1005 && code !== 1006 ? code : 1000, reason);
    }
  }
}
