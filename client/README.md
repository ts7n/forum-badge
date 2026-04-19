# Forum Badge client

> **For developers building the app from source.** If you just want to
> *use* Forum Badge, grab the latest release from the
> [homepage](https://ts7n.github.io/forum-badge/) — you don't need anything
> on this page.

Menu-bar macOS app that shows how many stories have been submitted to your
FLOW groups. Click the badge for a dropdown of story titles that open the
Google Doc. Talks to the [`server/`](../server/) proxy — one server per FLOW
account, any number of clients point at it.

## Build (dev)

```bash
./build.sh
open build/ForumBadge.app
```

`build.sh` ad-hoc-signs the binary, which is fine for running on your own
Mac.

The server URL is user-configurable in Preferences. The default is
`https://api.forumbadge.tml.sh` — if you're pointing at your own server
(e.g. `http://localhost:8787` for local dev), change it there. To ship a
build with a different baked-in default, edit `AppConfig.defaultServerURL`
in `ForumBadge/Config.swift`.

## First launch

On first launch the app auto-moves itself into `/Applications` (so login-item
registration works and Gatekeeper won't translocate future launches), then
opens a preferences window asking for the user's password. Once the password
checks out against the server, the rest unlocks:

- **Enabled** toggle
- **Reload groups**
- Per-group picker: Off / Count only / Menu + count

**Save** and the app goes silent in the menu bar.

- **Left-click** the menu-bar icon → story list + Open FLOW + Refresh.
- **Right-click** the menu-bar icon → Preferences… + Quit.
- Disabling in Preferences unregisters the login item and quits. The icon
  disappears entirely when disabled.

During repeated dev builds you can skip the auto-move to `/Applications`:

```bash
FORUMBADGE_SKIP_RELOCATE=1 open build/ForumBadge.app
```

## Distributing a signed, notarized build

For the `.app` to open without a Gatekeeper warning on other people's Macs,
`build.sh` will sign and notarize when two env vars are set:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export NOTARY_KEYCHAIN_PROFILE="forum-badge-notary"
# one-time setup:
#   xcrun notarytool store-credentials forum-badge-notary \
#       --apple-id you@example.com --team-id TEAMID --password app-specific-pw
./build.sh
# build/ForumBadge.zip is the distributable artifact
```

The script produces a universal (arm64 + x86_64) binary, signs with hardened
runtime + secure timestamp, submits to Apple for notarization, staples the
ticket, and re-zips the stapled bundle. Set `SKIP_X86=1` for a faster
Apple-Silicon-only build during development.

## Logging

Writes to `~/Library/Logs/ForumBadge.log` — fetch failures, login-item
reconciliation errors, Keychain problems.
