// OIDC JWT verification for nginx njs.
//
// Validates a bearer token against an OIDC issuer's JWKS, checks the
// standard claims and an operator-supplied subject allowlist, and
// returns 204 on success so nginx `auth_request` lets the request
// through. Stateless: nothing is written, the JWKS is cached only
// for the lifetime of the nginx worker.
//
// Tested against GitHub Actions tokens (RS256). Other issuers using
// RS256/RS384/RS512 should work; ES256 is not implemented because
// njs's WebCrypto lacks raw ECDSA signature import as of 0.9.

const ALG_HASH = {
  RS256: "SHA-256",
  RS384: "SHA-384",
  RS512: "SHA-512",
};

// JWKS fetched once per worker. nginx restarts on config change,
// which also picks up rotated keys; for long-lived workers a key
// not present in the cache triggers a refresh.
let jwksCache = null;

// njs ships Node.js-style Buffer with native base64url support;
// avoids round-tripping through `atob` and per-byte charCodeAt.
function b64urlDecode(s) {
  return Buffer.from(s, "base64url").toString("utf8");
}

function b64urlToBytes(s) {
  return Buffer.from(s, "base64url");
}

async function fetchJwks(r, jwksUrl, force) {
  if (jwksCache && !force) return jwksCache;
  const reply = await ngx.fetch(jwksUrl);
  if (reply.status !== 200) throw new Error(`JWKS fetch ${reply.status}`);
  jwksCache = await reply.json();
  return jwksCache;
}

async function importKey(jwk, alg) {
  // The token header's `alg` is attacker-controlled. Pin it to the
  // JWK's own `alg` (when present) so a downgrade to a weaker hash
  // cannot be requested.
  if (jwk.alg && jwk.alg !== alg)
    throw new Error(`alg ${alg} does not match JWK ${jwk.alg}`);
  const hash = ALG_HASH[alg];
  if (!hash) throw new Error(`unsupported alg ${alg}`);
  return crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash },
    false,
    ["verify"],
  );
}

async function verifyToken(r, token, opts) {
  // njs (as of 0.9) does not support array destructuring assignment.
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("malformed JWT");
  const h64 = parts[0];
  const p64 = parts[1];
  const s64 = parts[2];
  const header = JSON.parse(b64urlDecode(h64));
  const payload = JSON.parse(b64urlDecode(p64));
  const signature = b64urlToBytes(s64);
  const data = Buffer.from(`${h64}.${p64}`, "utf8");

  // Find the signing key, refetching the JWKS once if the kid is
  // unknown so a rotation does not require an nginx reload.
  let jwks = await fetchJwks(r, opts.jwksUrl, false);
  let jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    jwks = await fetchJwks(r, opts.jwksUrl, true);
    jwk = jwks.keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) throw new Error(`unknown kid ${header.kid}`);

  const key = await importKey(jwk, header.alg);
  const ok = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5", hash: ALG_HASH[header.alg] },
    key,
    signature,
    data,
  );
  if (!ok) throw new Error("signature invalid");

  const now = Math.floor(Date.now() / 1000);
  if (payload.exp && now > payload.exp) throw new Error("expired");
  if (payload.nbf && now < payload.nbf) throw new Error("not yet valid");
  if (opts.issuer && payload.iss !== opts.issuer)
    throw new Error(`bad issuer ${payload.iss}`);
  if (opts.audience) {
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(opts.audience))
      throw new Error(`bad audience ${payload.aud}`);
  }

  // Subject allowlist: glob-ish matching with `*` as a wildcard,
  // so `repo:org/*:ref:refs/heads/main` covers an org. Anchored to
  // the whole subject. An empty allowlist denies everything; a
  // misconfiguration must fail closed, not silently grant access.
  const sub = payload.sub || "";
  const allowed = (opts.subjects || []).some((pat) => {
    const re = new RegExp(
      "^" + pat.split("*").map(escapeRegExp).join(".*") + "$",
    );
    return re.test(sub);
  });
  if (!allowed) throw new Error(`subject not allowed: ${sub}`);
}

function escapeRegExp(s) {
  return s.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
}

// auth_request handler. Configuration arrives via njs variables set
// from nginx config (`set $...`):
//   $oidc_jwks_url, $oidc_issuer, $oidc_audience
//   $oidc_read_subjects, $oidc_write_subjects (JSON array strings)
// auth_request issues an internal GET, so the original request's
// method is read from the parent request to pick a subject list.
async function auth(r) {
  try {
    const m = (r.headersIn.Authorization || "").match(/^Bearer\s+(.+)$/);
    if (!m) {
      r.return(401, "missing bearer token");
      return;
    }
    // auth_request issues an internal GET; nginx's $request_method
    // is computed from r->main, so it reports the original method
    // even inside the subrequest.
    const method = r.variables.request_method;
    const subjects =
      method === "GET" || method === "HEAD"
        ? r.variables.oidc_read_subjects
        : r.variables.oidc_write_subjects;
    await verifyToken(r, m[1], {
      jwksUrl: r.variables.oidc_jwks_url,
      issuer: r.variables.oidc_issuer,
      audience: r.variables.oidc_audience,
      subjects: JSON.parse(subjects || "[]"),
    });
    r.return(204);
  } catch (e) {
    // Log the reason but return a bare status: error strings can
    // leak the parsed subject or allowlist shape to the client.
    r.error(`oidc auth: ${e}`);
    r.return(403);
  }
}

export default { auth };
