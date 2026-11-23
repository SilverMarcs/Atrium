/**
 * The client side of the Noise NK handshake the Mac answers
 * (`Noise_NK_25519_ChaChaPoly_SHA256`, as in the apps' NoiseHandshake),
 * so the gateway reaches the Mac through the relay like any paired device:
 * end-to-end encrypted against the Mac's key, with the relay passing only
 * ciphertext.
 */

import { chacha20poly1305 } from "@noble/ciphers/chacha.js";

const protocolName = new TextEncoder().encode("Noise_NK_25519_ChaChaPoly_SHA256");

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const imported = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", imported, data));
}

/** Noise's HKDF: HMAC-SHA256 extract, then two expand blocks. */
async function hkdf(chainingKey: Uint8Array, input: Uint8Array): Promise<[Uint8Array, Uint8Array]> {
  const temp = await hmac(chainingKey, input);
  const first = await hmac(temp, new Uint8Array([1]));
  const second = await hmac(temp, concat(first, new Uint8Array([2])));
  return [first, second];
}

/** A ChaCha20-Poly1305 key with Noise's counter nonce: four zero bytes, then the counter little-endian. */
export class CipherState {
  private nonce = 0n;
  constructor(private readonly key?: Uint8Array) {}

  private nextNonce(): Uint8Array {
    const bytes = new Uint8Array(12);
    new DataView(bytes.buffer).setBigUint64(4, this.nonce, true);
    this.nonce += 1n;
    return bytes;
  }

  encrypt(plaintext: Uint8Array, associatedData: Uint8Array = new Uint8Array()): Uint8Array {
    if (!this.key) return plaintext;
    return chacha20poly1305(this.key, this.nextNonce(), associatedData).encrypt(plaintext);
  }

  decrypt(ciphertext: Uint8Array, associatedData: Uint8Array = new Uint8Array()): Uint8Array {
    if (!this.key) return ciphertext;
    return chacha20poly1305(this.key, this.nextNonce(), associatedData).decrypt(ciphertext);
  }
}

/** The initiator's handshake with a Mac whose static key it knows. */
export class NoiseInitiator {
  private hash = protocolName;
  private chainingKey = protocolName;
  private cipher = new CipherState();
  private ephemeral?: CryptoKeyPair;

  private constructor(private readonly remoteStatic: Uint8Array) {}

  static async start(remoteStatic: Uint8Array, prologue: Uint8Array): Promise<NoiseInitiator> {
    const noise = new NoiseInitiator(remoteStatic);
    await noise.mixHash(prologue);
    await noise.mixHash(remoteStatic);
    return noise;
  }

  private async mixHash(data: Uint8Array): Promise<void> {
    this.hash = await sha256(concat(this.hash, data));
  }

  private async mixKey(input: Uint8Array): Promise<void> {
    const [chainingKey, key] = await hkdf(this.chainingKey, input);
    this.chainingKey = chainingKey;
    this.cipher = new CipherState(key);
  }

  private async dh(publicKey: Uint8Array): Promise<Uint8Array> {
    const remote = await crypto.subtle.importKey("raw", publicKey, { name: "X25519" }, false, []);
    // Workers name the algorithm's public key `$public` in their types; the runtime takes `public`.
    const algorithm = { name: "X25519", public: remote } as unknown as SubtleCryptoDeriveKeyAlgorithm;
    const bits = await crypto.subtle.deriveBits(algorithm, this.ephemeral!.privateKey, 256);
    return new Uint8Array(bits);
  }

  /** -> e, es: the ephemeral key and an empty encrypted payload. */
  async firstMessage(): Promise<Uint8Array> {
    this.ephemeral = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]) as CryptoKeyPair;
    const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", this.ephemeral.publicKey) as ArrayBuffer);
    await this.mixHash(publicKey);
    await this.mixKey(await this.dh(this.remoteStatic));
    const payload = this.cipher.encrypt(new Uint8Array(), this.hash);
    await this.mixHash(payload);
    return concat(publicKey, payload);
  }

  /** <- e, ee: reads the Mac's reply and returns the transport ciphers (send, receive). */
  async finish(reply: Uint8Array): Promise<[CipherState, CipherState]> {
    if (reply.length < 32) throw new Error("The Mac's handshake reply is too short.");
    const remoteEphemeral = reply.slice(0, 32);
    await this.mixHash(remoteEphemeral);
    await this.mixKey(await this.dh(remoteEphemeral));
    const payload = reply.slice(32);
    this.cipher.decrypt(payload, this.hash);
    await this.mixHash(payload);
    const [send, receive] = await hkdf(this.chainingKey, new Uint8Array());
    return [new CipherState(send), new CipherState(receive)];
  }
}
