/**
 * Atrium relay: joins an iPhone to a Mac when neither can reach the other directly.
 *
 * Both ends connect out over WebSockets, so the Mac needs no open ports. Each Mac
 * has a room (a Durable Object named by its Mac ID):
 *
 *   GET /v1/mac/:macID            The Mac's control connection. Told of each phone.
 *   GET /v1/phone/:macID          A phone arriving. Gets "ready" once the Mac picks it
 *                                 up, or "offline" if the Mac isn't connected.
 *   GET /v1/mac/:macID/data/:id   The Mac's connection for that phone.
 *
 * After "ready", the room forwards every message between a phone and its data
 * connection unchanged. They're end-to-end encrypted (Noise NK), so the relay can
 * neither read them nor pose as the Mac. Rooms use WebSocket hibernation, so idle
 * connections cost nothing.
 */

interface Env {
  ROOMS: DurableObjectNamespace;
}

const route = /^\/v1\/(mac|phone)\/([A-Za-z0-9_-]{16,64})(?:\/data\/([A-Za-z0-9-]{1,64}))?$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const match = new URL(request.url).pathname.match(route);
    if (!match || (match[1] === "phone" && match[3])) {
      return new Response("Atrium relay", { status: 404 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[2]));
    return room.fetch(request);
  },
};

export class Room implements DurableObject {
  constructor(private readonly state: DurableObjectState) {
    // Keep-alive pings are answered without waking the room.
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const [, role, , dataID] = new URL(request.url).pathname.match(route) ?? [];
    const { 0: client, 1: server } = new WebSocketPair();

    if (role === "mac" && !dataID) {
      // A Mac reconnecting replaces its previous control connection.
      for (const old of this.state.getWebSockets("control")) old.close(1000, "Replaced");
      this.state.acceptWebSocket(server, ["control"]);
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

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    const peer = this.peer(socket);
    if (peer && peer.readyState === WebSocket.OPEN) peer.send(message);
  }

  webSocketClose(socket: WebSocket, code: number, reason: string): void {
    this.closePeer(socket, code, reason);
  }

  webSocketError(socket: WebSocket): void {
    this.closePeer(socket, 1011, "Connection error");
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
