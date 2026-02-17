# Forum Badge

This automation checks [FLOW](https://flow.snosites.com) every 5 minutes for your group's latest assignments. It displays the number in your menu bar, offering easy access to your effective Forum to-do list. Clicking the "TF" icon shows you the names of the stories.

## Setup

You need two things:

* The `Cookie` header your authenticated browser sends to `flow.snosites.com`. You can get this from the Network tab of Chrome DevTools under any request to the FLOW API.
* The list of group names you want to check for, all of which you must be a member of.

Save this to `~/.config/forum-badge.env` like:

```
FLOW_COOKIE="..."
GROUP_NAMES="Web Group, EIC Group"
```

The first group listed will be considered the primary group, which affects determines the badge count.

## Build and Run

Double-click **run.command** (or in Terminal: `./run.command`). It builds the app and launches it.

To stop: double-click **stop.command** (or `./stop.command`).

Manual config: create `~/.config/forum-badge.env` with `FLOW_COOKIE=...` and `GROUP_NAMES=Name One,Name Two,...` (first name = primary group).

Build output is under `build/`. The app runs in the background (menu bar only; no dock icon). It will not be configured to relaunch at login by default; you will need to configure this manually.

## Logging

The app writes errors and warnings to `~/Library/Logs/ForumBadge.log`. Config problems (missing env file, missing `FLOW_COOKIE` / `GROUP_NAMES`) and API failures (request errors, invalid JSON) will be explained here.
