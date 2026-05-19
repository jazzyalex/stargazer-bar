#!/usr/bin/env bash

# Shared notarytool authentication resolver for Stargazer Bar release scripts.
# Supported modes, in precedence order:
# 1. App Store Connect API key:
#      NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#    Aliases:
#      ASC_PRIVATE_KEY / ASC_PRIVATE_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
# 2. Apple ID app-specific password:
#      NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID or TEAM_ID
#    Aliases:
#      APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
# 3. notarytool keychain profile:
#      NOTARY_PROFILE, default GHMenuStarsNotary
#    Alias:
#      NOTARY_KEYCHAIN_PROFILE

NOTARY_PROFILE=${NOTARY_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-GHMenuStarsNotary}}
NOTARY_KEY_PATH=${NOTARY_KEY_PATH:-${NOTARY_KEY:-${ASC_PRIVATE_KEY:-${ASC_PRIVATE_KEY_PATH:-}}}}
NOTARY_KEY_ID=${NOTARY_KEY_ID:-${ASC_KEY_ID:-}}
NOTARY_ISSUER=${NOTARY_ISSUER:-${NOTARY_ISSUER_ID:-${ASC_ISSUER_ID:-}}}
NOTARY_APPLE_ID=${NOTARY_APPLE_ID:-${APPLE_ID:-}}
NOTARY_TEAM_ID=${NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}
NOTARY_PASSWORD=${NOTARY_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}
TEAM_ID=${TEAM_ID:-}

NOTARY_AUTH_ARGS=()
NOTARY_AUTH_LABEL=""

notary_auth_warn() {
  if declare -F yellow >/dev/null 2>&1; then
    yellow "$*"
  else
    printf 'WARNING: %s\n' "$*" >&2
  fi
}

notary_auth_error() {
  if declare -F red >/dev/null 2>&1; then
    red "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
}

using_api_key_notary_credentials() {
  [[ -n "$NOTARY_KEY_PATH" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]
}

using_explicit_notary_credentials() {
  [[ -n "$NOTARY_APPLE_ID" || -n "$NOTARY_TEAM_ID" || -n "$NOTARY_PASSWORD" ]]
}

build_notary_auth_args() {
  NOTARY_AUTH_ARGS=()
  NOTARY_AUTH_LABEL=""

  if using_api_key_notary_credentials; then
    local missing=()
    [[ -n "$NOTARY_KEY_PATH" ]] || missing+=("NOTARY_KEY_PATH or ASC_PRIVATE_KEY")
    [[ -n "$NOTARY_KEY_ID" ]] || missing+=("NOTARY_KEY_ID or ASC_KEY_ID")

    if [[ ${#missing[@]} -gt 0 ]]; then
      notary_auth_error "Incomplete App Store Connect API key credentials. Missing: ${missing[*]}"
      return 2
    fi
    if [[ ! -f "$NOTARY_KEY_PATH" ]]; then
      notary_auth_error "Notary API key file does not exist: $NOTARY_KEY_PATH"
      return 2
    fi

    NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
    if [[ -n "$NOTARY_ISSUER" ]]; then
      NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_ISSUER")
      NOTARY_AUTH_LABEL="App Store Connect API key (${NOTARY_KEY_ID}, issuer ${NOTARY_ISSUER})"
    else
      NOTARY_AUTH_LABEL="App Store Connect API key (${NOTARY_KEY_ID})"
    fi
  elif using_explicit_notary_credentials; then
    local team="${NOTARY_TEAM_ID:-${TEAM_ID:-}}"
    local missing=()
    [[ -n "$NOTARY_APPLE_ID" ]] || missing+=("NOTARY_APPLE_ID")
    [[ -n "$team" ]] || missing+=("NOTARY_TEAM_ID or TEAM_ID")
    [[ -n "$NOTARY_PASSWORD" ]] || missing+=("NOTARY_PASSWORD")

    if [[ ${#missing[@]} -gt 0 ]]; then
      notary_auth_error "Incomplete explicit notary credentials. Missing: ${missing[*]}"
      return 2
    fi

    NOTARY_AUTH_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$team" --password "$NOTARY_PASSWORD")
    NOTARY_AUTH_LABEL="Apple ID credentials (${NOTARY_APPLE_ID}, team ${team})"
  else
    NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_LABEL="keychain profile '${NOTARY_PROFILE}'"
  fi
}

check_notary_credentials() {
  local attempts="${1:-3}"
  local sleep_s=2

  build_notary_auth_args || return $?

  for ((i=1; i<=attempts; i++)); do
    if xcrun notarytool history "${NOTARY_AUTH_ARGS[@]}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ $i -lt $attempts ]]; then
      notary_auth_warn "Notary credential check failed (attempt $i/$attempts). Retrying in ${sleep_s}s..."
      sleep "$sleep_s"
      sleep_s=$((sleep_s * 2))
    fi
  done

  return 1
}

print_notary_recovery_hint() {
  notary_auth_error "Notary credentials are not configured or not accessible."
  if [[ -n "$NOTARY_AUTH_LABEL" ]]; then
    notary_auth_error "Tried: $NOTARY_AUTH_LABEL"
  fi
  notary_auth_error "Preferred durable setup: put an App Store Connect API key in tools/release/.env:"
  notary_auth_error "  NOTARY_KEY_PATH=/absolute/path/AuthKey_<KEY_ID>.p8"
  notary_auth_error "  NOTARY_KEY_ID=<KEY_ID>"
  notary_auth_error "  NOTARY_ISSUER=<issuer-uuid>  # omit only for individual API keys"
  notary_auth_error "Fallback keychain profile:"
  notary_auth_error "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <TEAM> --password <app-specific-password> --validate"
}
