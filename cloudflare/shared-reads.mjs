const database = "https://kuxghmfeqzmrggkuiwys.supabase.co";
const frontend = "https://jaedenguo128.github.io";
const jwksPath = "/auth/v1/.well-known/jwks.json";
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

// These projections have the same rows for every authenticated player.
// A route not on this list never reaches Supabase through the Worker.
const sharedReads = new Map([
  ["/rest/v1/stock_quotes?select=symbol,name,price,base_price,depth,price_24h", 15],
  ["/rest/v1/land_claims?select=country_key,country_name,owner_id,owner_name,paid,area_km2&order=country_key.asc&limit=1000", 10],
  ["/rest/v1/warfare_marches?select=unit_id,owner_id,current_plot_key,target_plot_key,last_step_at,active,mode", 8],
  ["/rest/v1/warfare_assets?select=id,owner_id,kind,plot_key,expires_at&order=id.asc", 10],
]);
const history = /^\/rest\/v1\/stock_history\?symbol=eq\.(XERG|FERN|BTC|AMMO|XPPL|TXLA|NVDX|MXDF|SPCX|R6S|BMH|FRNW|XIKY|STBX|MCX)&select=price&order=created_at.desc&limit=120$/;

function decode(segment) {
  return Uint8Array.from(atob(segment.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
}

async function validToken(token, keyset) {
  if (!token || token.length > 8192) return false;
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some(part => !/^[a-zA-Z0-9_-]+$/.test(part))) return false;
  try {
    const header = JSON.parse(new TextDecoder().decode(decode(parts[0])));
    const claims = JSON.parse(new TextDecoder().decode(decode(parts[1])));
    const now = Math.floor(Date.now() / 1000);
    if (header.alg !== "ES256" || typeof header.kid !== "string" || header.crit ||
        claims.iss !== database + "/auth/v1" || claims.aud !== "authenticated" ||
        claims.role !== "authenticated" || claims.is_anonymous === true ||
        typeof claims.sub !== "string" || !uuid.test(claims.sub) ||
        !Number.isInteger(claims.exp) || claims.exp <= now ||
        (claims.nbf !== undefined && (!Number.isInteger(claims.nbf) || claims.nbf > now))) return false;
    const jwk = (await keyset()).keys?.find(key => key.kid === header.kid &&
      key.kty === "EC" && key.crv === "P-256" && key.alg === "ES256");
    if (!jwk) return false;
    const publicKey = await crypto.subtle.importKey("jwk", jwk, {name:"ECDSA", namedCurve:"P-256"}, false, ["verify"]);
    return await crypto.subtle.verify({name:"ECDSA", hash:"SHA-256"}, publicKey, decode(parts[2]),
      new TextEncoder().encode(parts[0] + "." + parts[1]));
  } catch {
    return false;
  }
}

const cors = {
  "access-control-allow-origin": frontend,
  "access-control-expose-headers": "x-xern-cache",
  "cache-control": "private, no-store",
};

function failure(status) {
  return new Response(null, {status, headers:cors});
}

async function readKeys(cache, key) {
  const hit = await cache.match(key);
  if (hit) return hit.json();
  const upstream = await fetch(database + jwksPath, {redirect:"manual", signal:AbortSignal.timeout(4000)});
  if (!upstream.ok) throw Error("JWKS unavailable");
  const keyset = await upstream.json();
  try {
    await cache.put(key, Response.json(keyset, {headers:{"cache-control":"public, max-age=60"}}));
  } catch {
    // A cache failure does not make a valid key unusable.
  }
  return keyset;
}

function playerResponse(response, cacheStatus) {
  return new Response(response.body, {
    headers: {...cors, "content-type":"application/json; charset=utf-8", "x-xern-cache":cacheStatus},
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const route = url.pathname + url.search;
    const ttl = sharedReads.get(route) ?? (history.test(route) ? 30 : 0);
    if (!ttl) return failure(404);
    const origin = request.headers.get("origin");
    if (origin && origin !== frontend) return failure(403);
    if (request.method === "OPTIONS") return new Response(null, {status:204, headers:{
      ...cors, "access-control-allow-methods":"GET, OPTIONS",
      "access-control-allow-headers":"authorization, content-type, apikey", "access-control-max-age":"600",
    }});
    if (request.method !== "GET") return failure(405);
    if (!env.SUPABASE_PUBLISHABLE_KEY?.startsWith("sb_publishable_")) return failure(503);

    const token = request.headers.get("authorization")?.match(/^Bearer ([^ ]+)$/i)?.[1];
    const cache = caches.default;
    const key = new Request(url.origin + "/_xern-shared-v1" + route);
    const keyset = new Request(url.origin + "/_xern-shared-v1/jwks");
    if (!await validToken(token, () => readKeys(cache, keyset))) return failure(401);

    try {
      const hit = await cache.match(key);
      if (hit) return playerResponse(hit, "HIT");
      const upstream = await fetch(database + route, {
        headers:{apikey:env.SUPABASE_PUBLISHABLE_KEY, authorization:"Bearer " + token},
        redirect:"manual", signal:AbortSignal.timeout(5000),
      });
      if (!upstream.ok) return failure(upstream.status);
      if (!upstream.headers.get("content-type")?.includes("application/json")) return failure(502);
      const stored = new Response(upstream.body, {headers:{
        "content-type":"application/json; charset=utf-8", "cache-control":"public, max-age=" + ttl,
      }});
      ctx.waitUntil(cache.put(key, stored.clone()).catch(() => {}));
      return playerResponse(stored, "MISS");
    } catch {
      return failure(502);
    }
  },
};
