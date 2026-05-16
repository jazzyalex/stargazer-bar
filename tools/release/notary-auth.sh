#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  echo "--keychain-profile ${NOTARY_KEYCHAIN_PROFILE}"
  exit 0
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  echo "--apple-id ${APPLE_ID} --team-id ${APPLE_TEAM_ID} --password ${APPLE_APP_SPECIFIC_PASSWORD}"
  exit 0
fi

echo "No notarization credentials found. Set NOTARY_KEYCHAIN_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_SPECIFIC_PASSWORD." >&2
exit 1

