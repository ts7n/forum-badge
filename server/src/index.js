import express from "express";
import dotenv from "dotenv";
import { FlowClient } from "./flow.js";
import { Cache } from "./cache.js";
import { requireBearer } from "./auth.js";

dotenv.config();

const {
  FLOW_COOKIE,
  FORUM_BADGE_PASSWORD,
  PORT = "8787",
  REFRESH_INTERVAL_SECONDS = "60",
} = process.env;

if (!FLOW_COOKIE) {
  console.error("FLOW_COOKIE is required");
  process.exit(1);
}
if (!FORUM_BADGE_PASSWORD) {
  console.error("FORUM_BADGE_PASSWORD is required");
  process.exit(1);
}

const flow = new FlowClient(FLOW_COOKIE);
const refreshMs = Math.max(5, Number(REFRESH_INTERVAL_SECONDS)) * 1000;
const cache = new Cache({ flow, refreshMs });
cache.start();

const app = express();
app.disable("x-powered-by");

app.get("/healthz", (_req, res) => {
  const { lastRefreshedAt, lastRefreshError, consecutiveFailures, groups } =
    cache.snapshot;
  res.json({
    ok: !!lastRefreshedAt && !lastRefreshError,
    lastRefreshedAt,
    lastRefreshError,
    consecutiveFailures,
    groups: groups.length,
    stories: cache.storyCount(),
  });
});

const auth = requireBearer(FORUM_BADGE_PASSWORD);

app.get("/api/verify", auth, (_req, res) => {
  res.json({ ok: true });
});

app.get("/api/groups", auth, (_req, res) => {
  res.json(cache.snapshot.groups);
});

app.get("/api/stories", auth, (req, res) => {
  const idsParam = String(req.query.ids || "").trim();
  if (!idsParam) {
    res.status(400).json({ error: "ids query param required" });
    return;
  }
  const ids = idsParam
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isInteger(n));
  const groupNameById = new Map(
    cache.snapshot.groups.map((g) => [g.id, g.name]),
  );
  const out = [];
  for (const id of ids) {
    const name = groupNameById.get(id);
    if (!name) continue; // unknown id -> silent omit
    out.push({
      groupId: id,
      groupName: name,
      stories: cache.snapshot.storiesByGroupId.get(id) || [],
    });
  }
  res.json(out);
});

const port = Number(PORT);
app.listen(port, () => {
  console.log(`[server] forum-badge listening on :${port}`);
});
