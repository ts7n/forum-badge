#!/usr/bin/env bash
# Convenience launcher: build and open the app.
# For distribution builds, invoke ./build.sh directly with the
# DEVELOPER_ID_APPLICATION / NOTARY_KEYCHAIN_PROFILE env vars set.
set -e
cd "$(dirname "$0")"

./build.sh

open build/ForumBadge.app
echo "Built and launched."
echo "Press any key to close this window."
read -n 1 -s
