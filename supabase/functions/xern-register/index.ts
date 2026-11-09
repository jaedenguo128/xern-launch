const apiUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
function reply(status: number, message: string) {
  return new Response(JSON.stringify({ message }), { status, headers });
}
Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (request.method !== "POST") return reply(405, "Method not allowed");
  try {
    const body = await request.text();
    if (body.length > 2048) return reply(413, "Registration request is too large");
    let input;
    try { input = JSON.parse(body); } catch { return reply(400, "Invalid registration request"); }
    const { username, password } = input ?? {};
    if (typeof username !== "string" || !/^[A-Za-z0-9_]{3,24}$/.test(username) ||
        typeof password !== "string" || password.length < 8 || new TextEncoder().encode(password).length > 72) {
      return reply(400, "Use a 3–24 character username and a password of 8–72 bytes.");
    }
    const adminHeaders = {
      apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json",
    };
    const address = request.headers.get("cf-connecting-ip") ??
      request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() ?? "unknown";
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(serviceKey + ":" + address));
    const client = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const limit = await fetch(apiUrl + "/rest/v1/rpc/xern_signup_rate_limit", {
      method: "POST", headers: adminHeaders, body: JSON.stringify({ p_client: client }),
    });
    if (!limit.ok) return reply(503, "Registration is temporarily unavailable.");
    if (!(await limit.json())) return reply(429, "Too many registrations. Try again later.");
    const proof = crypto.randomUUID();
    const reservation = await fetch(apiUrl + "/rest/v1/rpc/xern_prepare_signup", {
      method: "POST", headers: adminHeaders, body: JSON.stringify({ p_username: username, p_proof: proof }),
    });
    if (!reservation.ok || !(await reservation.json())) return reply(503, "Registration is temporarily unavailable.");
    // The game uses private username aliases in place of a real email address.
    const user = await fetch(apiUrl + "/auth/v1/admin/users", {
      method: "POST", headers: adminHeaders,
      body: JSON.stringify({
        email: username.toLowerCase() + "@players.example.com",
        password, email_confirm: true, user_metadata: { username, xern_proof: proof },
      }),
    });
    if (user.ok) return reply(201, "Account created");
    if (user.status === 429) return reply(429, "Too many registrations. Try again later.");
    const data = await user.json().catch(() => ({}));
    if (data.error_code === "email_exists" || data.error_code === "user_already_exists") {
      return reply(409, "That username is taken.");
    }
    if (data.error_code === "weak_password") return reply(400, "Choose a stronger password.");
    return reply(503, "Registration is temporarily unavailable.");
  } catch {
    return reply(503, "Registration is temporarily unavailable.");
  }
});
