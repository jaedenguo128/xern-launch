import assert from "node:assert/strict";
import {test} from "node:test";
import worker from "./shared-reads.mjs";

test("only verified sessions can share the allowed cached reads", async () => {
  const db = "https://kuxghmfeqzmrggkuiwys.supabase.co";
  const keypair = await crypto.subtle.generateKey({name:"ECDSA", namedCurve:"P-256"}, true, ["sign", "verify"]);
  const jwk = {...await crypto.subtle.exportKey("jwk", keypair.publicKey), kid:"unit-test", alg:"ES256"};
  const encode = v => Buffer.from(JSON.stringify(v)).toString("base64url");
  async function token(sub, extra={}) {
    const signed = encode({alg:"ES256", kid:jwk.kid}) + "." + encode({
      iss:db+"/auth/v1", aud:"authenticated", role:"authenticated", sub,
      exp:Math.floor(Date.now()/1000)+600, ...extra,
    });
    const signature = await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},keypair.privateKey,new TextEncoder().encode(signed));
    return signed + "." + Buffer.from(signature).toString("base64url");
  }
  const a = "8399c1c6-98e5-417a-b16e-e96b9fcf17b7";
  const b = "bf41d641-9128-4628-a3c1-a3262951dd77";
  const first = await token(a);
  const second = await token(b);
  const stored = new Map();
  const oldFetch = globalThis.fetch;
  const oldCaches = globalThis.caches;
  let originReads = 0, upstreamError = false;
  const tasks = [];
  globalThis.caches = {default:{
    match: async request => stored.get(request.url)?.clone(),
    put: async (request,response) => stored.set(request.url, response),
  }};
  globalThis.fetch = async (url, opts) => {
    assert(url.startsWith(db + "/"));
    if (url.endsWith("/jwks.json")) return Response.json({keys:[jwk]});
    assert.equal(opts.headers.apikey, "sb_publishable_test");
    assert.equal(opts.redirect, "error");
    originReads++;
    return upstreamError ? Response.json({error:"unavailable"},{status:503}) : Response.json([{symbol:"FERN"}]);
  };
  const quotes = "/rest/v1/stock_quotes?select=symbol,name,price,base_price,depth,price_24h";
  const run = (path, bearer, method="GET", origin="https://jaedenguo128.github.io") => worker.fetch(
    new Request("https://xern.test"+path,{method,headers:{origin,...(bearer?{authorization:"Bearer "+bearer}:{})}}),
    {SUPABASE_PUBLISHABLE_KEY:"sb_publishable_test"}, {waitUntil(task){tasks.push(task);}},
  );
  try {
    const miss = await run(quotes, first);
    assert.equal(miss.headers.get("x-xern-cache"),"MISS");
    assert.equal(miss.headers.get("cache-control"),"private, no-store");
    assert.deepEqual(await miss.json(),[{symbol:"FERN"}]);
    await Promise.all(tasks);
    const hit = await run(quotes, second);
    assert.equal(hit.headers.get("x-xern-cache"),"HIT");
    assert.equal(originReads,1);
    assert.equal((await run(quotes)).status,401);
    assert.equal((await run(quotes, first.replace(/\.[^.]+$/, "."+"A".repeat(86)))).status,401);
    assert.equal((await run(quotes, await token(a,{exp:1}))).status,401);
    assert.equal((await run(quotes, await token(a,{iss:"https://wrong.test"}))).status,401);
    assert.equal((await run(quotes, await token(a,{role:"service_role"}))).status,401);
    assert.equal((await run(quotes, first,"GET","https://wrong.test")).status,403);
    assert.equal((await run(quotes, first,"POST")).status,405);
    assert.equal((await run(quotes+"%26extra=1", first)).status,404);
    assert.equal((await run("/rest/v1/profiles?select=money", first)).status,404);
    assert.equal((await run("/rest/v1/rpc/stock_trade", first,"POST")).status,404);
    assert.equal((await run(quotes, null,"OPTIONS")).status,204);
    assert.equal(originReads,1);
    upstreamError = true;
    const chart = "/rest/v1/stock_history?symbol=eq.FERN&select=price&order=created_at.desc&limit=120";
    assert.equal((await run(chart, first)).status,503);
    assert.equal((await run(chart, second)).status,503);
    assert.equal(originReads,3);
  } finally {
    globalThis.fetch=oldFetch;
    globalThis.caches=oldCaches;
  }
});
