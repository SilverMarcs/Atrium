# Atrium relay

The Cloudflare Worker that joins the Atrium iPhone app to a Mac and sends the
Mac's task alerts to phones through APNs. It runs at
`wss://atrium-relay.lynksphere.com`, which both apps have built in
(`CompanionProtocol.relayURL`). See `src/index.ts` for the protocol.

## Deploy

```sh
npm ci
npx wrangler deploy
```

APNs needs a token-based key (`.p8`) from the J52QUTREBS team that can send
to `com.SilverMarcs.Atrium`. Set it once as Worker secrets:

```sh
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_PRIVATE_KEY < /path/to/AuthKey_XXXXXXXXXX.p8
```

The MCP gateway ChatGPT connects to (`/mcp`, with OAuth at `/oauth/*`) seals its tokens with `GATEWAY_KEY`, 32 random bytes as base64url:

```sh
openssl rand 32 | basenc --base64url | tr -d = | npx wrangler secret put GATEWAY_KEY
```

`APNS_TEAM_ID`, `APNS_TOPIC` and `REDIRECT_HOSTS` (where the gateway's OAuth may send ChatGPT back) are plain variables in `wrangler.toml`. Each
push names the environment its token came from (debug builds use sandbox), and
the relay retries the other environment if APNs rejects the token.

`npm run check` type-checks the Worker.
