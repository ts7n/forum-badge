const BASE = "https://flow.snosites.com";
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

export class FlowClient {
  constructor(initialCookie) {
    this.jar = parseCookieString(initialCookie);
  }

  cookieHeader() {
    return Array.from(this.jar.entries())
      .map(([k, v]) => `${k}=${v}`)
      .join("; ");
  }

  xsrfToken() {
    const raw = this.jar.get("XSRF-TOKEN");
    if (!raw) return null;
    try {
      return decodeURIComponent(raw);
    } catch {
      return raw;
    }
  }

  absorbSetCookie(res) {
    // node's fetch exposes Set-Cookie via headers.getSetCookie() on Node 20+.
    const list =
      typeof res.headers.getSetCookie === "function"
        ? res.headers.getSetCookie()
        : res.headers.raw?.()["set-cookie"] || [];
    for (const line of list) {
      const firstPair = line.split(";")[0];
      const eq = firstPair.indexOf("=");
      if (eq <= 0) continue;
      const name = firstPair.slice(0, eq).trim();
      const value = firstPair.slice(eq + 1).trim();
      if (!name) continue;
      this.jar.set(name, value);
    }
  }

  async request(path) {
    const xsrf = this.xsrfToken();
    if (!xsrf) throw new Error("no XSRF-TOKEN in cookie jar");
    const res = await fetch(BASE + path, {
      method: "GET",
      headers: {
        Cookie: this.cookieHeader(),
        "x-xsrf-token": xsrf,
        Accept: "application/json, text/plain, */*",
        Referer: `${BASE}/assignments/home`,
        "x-requested-with": "XMLHttpRequest",
        "User-Agent": USER_AGENT,
      },
    });
    this.absorbSetCookie(res);
    // FLOW returns 406 for some JSON endpoints; body is still valid JSON.
    if (res.status !== 200 && res.status !== 406) {
      const preview = (await res.text()).slice(0, 300);
      throw new Error(`FLOW ${path} HTTP ${res.status}: ${preview}`);
    }
    const text = await res.text();
    try {
      return JSON.parse(text);
    } catch {
      throw new Error(`FLOW ${path} non-JSON body: ${text.slice(0, 200)}`);
    }
  }

  async listGroups() {
    const body = await this.request("/api/v1/groups");
    if (!Array.isArray(body)) throw new Error("/api/v1/groups not array");
    return body
      .filter((g) => g && typeof g.id === "number" && typeof g.title === "string")
      .map((g) => ({ id: g.id, name: g.title }));
  }

  async dashboardAssignments() {
    const body = await this.request("/api/v1/dashboard/groups");
    const a = body?.assignments;
    if (!a || typeof a !== "object") throw new Error("no assignments object");
    return a;
  }

  async assignmentDetails(id) {
    const body = await this.request(`/api/v1/assignment/${id}`);
    return {
      title: typeof body?.title === "string" ? body.title : null,
      googleDocId:
        typeof body?.google_doc_id === "string"
          ? body.google_doc_id
          : typeof body?.google_doc_id === "number"
            ? String(body.google_doc_id)
            : null,
    };
  }
}

function parseCookieString(s) {
  const jar = new Map();
  if (!s) return jar;
  for (const part of s.split(";")) {
    const p = part.trim();
    if (!p) continue;
    const eq = p.indexOf("=");
    if (eq <= 0) continue;
    jar.set(p.slice(0, eq).trim(), p.slice(eq + 1).trim());
  }
  return jar;
}
