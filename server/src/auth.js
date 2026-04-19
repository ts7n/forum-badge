import crypto from "node:crypto";

function sha256(s) {
  return crypto.createHash("sha256").update(s, "utf8").digest();
}

export function requireBearer(password) {
  const expected = sha256(password);
  return (req, res, next) => {
    const header = req.get("authorization") || "";
    const match = /^Bearer\s+(.+)$/i.exec(header);
    if (!match) {
      res.status(401).json({ error: "missing bearer token" });
      return;
    }
    const got = sha256(match[1]);
    if (got.length !== expected.length || !crypto.timingSafeEqual(got, expected)) {
      console.log(`[auth] rejected request from ${req.ip}`);
      res.status(401).json({ error: "invalid bearer token" });
      return;
    }
    next();
  };
}
