const FLOW_FALLBACK_URL =
  "https://flow.snosites.com/assignments/home#submitted-to-my-groups";

export class Cache {
  constructor({ flow, refreshMs }) {
    this.flow = flow;
    this.refreshMs = refreshMs;
    this.assignmentDetails = new Map(); // assignment_id -> {title, googleDocId}
    this.snapshot = {
      groups: [],
      storiesByGroupId: new Map(),
      lastRefreshedAt: null,
      lastRefreshError: null,
      consecutiveFailures: 0,
    };
    this.refreshing = false;
    this.stopped = false;
  }

  start() {
    const tick = async () => {
      if (this.stopped) return;
      await this.refresh();
      if (this.stopped) return;
      setTimeout(tick, this.refreshMs);
    };
    tick();
  }

  stop() {
    this.stopped = true;
  }

  storyCount() {
    let n = 0;
    for (const list of this.snapshot.storiesByGroupId.values()) n += list.length;
    return n;
  }

  async refresh() {
    if (this.refreshing) return;
    this.refreshing = true;
    const started = Date.now();
    try {
      const groups = await this.flow.listGroups();
      groups.sort((a, b) => a.name.localeCompare(b.name));
      const nameToId = new Map(groups.map((g) => [g.name, g.id]));

      const assignmentsByName = await this.flow.dashboardAssignments();
      const storiesByGroupId = new Map();
      const needDetails = [];

      for (const [groupName, rawList] of Object.entries(assignmentsByName)) {
        if (!Array.isArray(rawList)) continue;
        // Prefer name -> id lookup; fall back to submitted_groups[0].id
        let groupId = nameToId.get(groupName);
        for (const item of rawList) {
          const assignmentId = pickAssignmentId(item);
          if (assignmentId == null) continue;
          const submitted = Array.isArray(item?.submitted_groups)
            ? item.submitted_groups
            : [];
          const fromSubmitted = submitted.find(
            (g) => typeof g?.id === "number" && g?.title === groupName,
          );
          const resolvedGroupId = groupId ?? fromSubmitted?.id;
          if (resolvedGroupId == null) continue;
          if (!storiesByGroupId.has(resolvedGroupId)) {
            storiesByGroupId.set(resolvedGroupId, []);
          }
          storiesByGroupId.get(resolvedGroupId).push({
            assignmentId,
            fallbackTitle:
              typeof item?.title === "string" && item.title
                ? item.title
                : "Assignment",
          });
          if (!this.assignmentDetails.has(assignmentId)) {
            needDetails.push(assignmentId);
          }
        }
      }

      for (const id of needDetails) {
        try {
          const details = await this.flow.assignmentDetails(id);
          this.assignmentDetails.set(id, details);
        } catch (e) {
          console.log(`[refresh] assignment ${id} details failed: ${e.message}`);
        }
      }

      // Materialize final stories (title + url) from the long-cache
      const finalStories = new Map();
      for (const [groupId, list] of storiesByGroupId) {
        finalStories.set(
          groupId,
          list.map(({ assignmentId, fallbackTitle }) => {
            const d = this.assignmentDetails.get(assignmentId);
            const title = d?.title || fallbackTitle;
            const url = d?.googleDocId
              ? `https://docs.google.com/document/d/${d.googleDocId}/edit`
              : FLOW_FALLBACK_URL;
            return { id: assignmentId, title, url };
          }),
        );
      }

      this.snapshot = {
        groups,
        storiesByGroupId: finalStories,
        lastRefreshedAt: new Date().toISOString(),
        lastRefreshError: null,
        consecutiveFailures: 0,
      };
      const ms = Date.now() - started;
      console.log(
        `[refresh] ok groups=${groups.length} stories=${this.storyCount()} new_details=${needDetails.length} in ${ms}ms`,
      );
    } catch (e) {
      this.snapshot = {
        ...this.snapshot,
        lastRefreshError: e.message,
        consecutiveFailures: (this.snapshot.consecutiveFailures || 0) + 1,
      };
      console.log(`[refresh] failed: ${e.message}`);
    } finally {
      this.refreshing = false;
    }
  }
}

function pickAssignmentId(item) {
  const raw =
    item?.assignment_id ??
    item?.id ??
    item?.project?.id ??
    null;
  if (typeof raw === "number") return raw;
  if (typeof raw === "string" && /^\d+$/.test(raw)) return Number(raw);
  return null;
}
