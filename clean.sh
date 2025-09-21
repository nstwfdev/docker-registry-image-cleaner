#!/usr/bin/env bash
set -euo pipefail

# === HELP ===
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: clean.sh [--help]

Environment Variables:

  # Required for Docker Hub cleanup:
  DOCKERHUB_REPO         e.g. "username/repo"
  DOCKERHUB_USERNAME     Docker Hub username
  DOCKERHUB_PASSWORD     Docker Hub password

  # Required for GHCR cleanup:
  GHCR_REPO              e.g. "ghcr.io/org/repo"
  GHCR_USERNAME          GitHub username
  GHCR_TOKEN             GitHub token with delete:packages scope

  # Optional filters:
  IMAGE_PREFIX           Only delete tags starting with this prefix
  MAX_AGE_DAYS           Only delete tags older than this number of days

Examples:

  Delete all old GHCR images with prefix "myapp-" older than 10 days:
    GHCR_REPO=ghcr.io/org/repo \
    GHCR_USERNAME=nstwf \
    GHCR_TOKEN=ghp_ \
    IMAGE_PREFIX=myapp- \
    MAX_AGE_DAYS=10 \
    ./clean.sh

  Delete all Docker Hub images without filters:
    DOCKERHUB_REPO=username/repo \
    DOCKERHUB_USERNAME=username \
    DOCKERHUB_PASSWORD=password \
    ./clean.sh

EOF
  exit 0
fi


# === LOGGING (standardized events) ===
# Usage:
#   log_event <level> <provider> <repo> <action> <resource> <identifier> [<http_code>] [<message>]
# level: info|warn|error
# provider: dockerhub|ghcr
# action: delete_attempt|delete_success|delete_failed|skip|auth|pager
# resource: tag|manifest|package-version|untagged
# identifier: tag name / digest / package-version id
# --- Logging: dual-format (JSON or plain text) ---
# Set LOG_FMT=json  for machine-readable JSON logs
# Set LOG_FMT=text  for classic human-readable logs (default)
LOG_FMT="${LOG_FMT:-text}"

# log_event:
#   Usage: log_event <level> <provider> <repo> <action> <resource> <identifier> [<http_code>] [<message>]
# Example:
#   log_event info dockerhub "username/repo" delete_attempt tag "8.0" 204 "deleted"
log_event() {
  local level="$1"; shift
  local provider="$1"; shift
  local repo="$1"; shift
  local action="$1"; shift
  local resource="$1"; shift
  local identifier="$1"; shift
  local http_code="${1:-}"; shift || true
  local message="${1:-}"; shift || true

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ "$LOG_FMT" == "json" ]]; then
    # prefer jq for safe JSON, but fall back to manual escaping
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg ts "$ts" \
           --arg level "$level" \
           --arg provider "$provider" \
           --arg repo "$repo" \
           --arg action "$action" \
           --arg resource "$resource" \
           --arg identifier "$identifier" \
           --arg http_code "$http_code" \
           --arg message "$message" \
           '{timestamp:$ts,level:$level,provider:$provider,repo:$repo,action:$action,resource:$resource,identifier:$identifier,http_code:$http_code,message:$message}' >&2
    else
      # rudimentary JSON escaping for quotes/backslashes/newlines
      esc() { printf '%s' "$1" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' | awk '{printf "\"%s\"",$0}'; }
      printf '{"timestamp":"%s","level":"%s","provider":"%s","repo":"%s","action":"%s","resource":"%s","identifier":"%s","http_code":"%s","message":%s}\n' \
        "$ts" "$(esc "$level")" "$(esc "$provider")" "$(esc "$repo")" "$(esc "$action")" "$(esc "$resource")" "$(esc "$identifier")" "$(esc "$http_code")" "$(esc "$message")" >&2
    fi
  else
    # plain text: concise single-line human readable
    # Format: TIMESTAMP [LEVEL] provider/repo action resource identifier (http_code) - message
    if [[ -n "$http_code" ]]; then
      printf '%s [%s] %s/%s %s %s %s - %s\n' "$ts" "${level^^}" "$provider" "$repo" "$action" "$resource" "$identifier" "$http_code ${message:-}" >&2
    else
      printf '%s [%s] %s/%s %s %s %s - %s\n' "$ts" "${level^^}" "$provider" "$repo" "$action" "$resource" "$identifier" "$message" >&2
    fi
  fi
}

# legacy convenience wrappers kept for compatibility with existing calls that
# pass a simple message. They will emit provider inferred from envs (prefer GHCR_REPO,
# then DOCKERHUB_REPO), and use action "info"/"warn".
_infer_repo() {
  if [[ -n "${GHCR_REPO:-}" ]]; then
    echo "ghcr" "$GHCR_REPO"
  elif [[ -n "${DOCKERHUB_REPO:-}" ]]; then
    echo "dockerhub" "$DOCKERHUB_REPO"
  else
    echo "script" "<global>"
  fi
}

log_info() {
  local provider repo
  read -r provider repo <<<"$(_infer_repo)"
  local msg="$*"
  log_event info "$provider" "$repo" "info" "script" "" "" "$msg"
}

log_warn() {
  local provider repo
  read -r provider repo <<<"$(_infer_repo)"
  local msg="$*"
  log_event warn "$provider" "$repo" "warning" "script" "" "" "$msg"
}

# === GLOBAL CONFIG ===
DOCKERHUB_API="https://hub.docker.com/v2"
GHCR_API="https://ghcr.io/v2"

# === FILTERS ===
cutoff_ts=""
if [[ -n "${MAX_AGE_DAYS:-}" ]]; then
  cutoff_ts=$(date -d "-$MAX_AGE_DAYS days" +%s)
  log_event info script "<global>" "filter" "max_age" "$MAX_AGE_DAYS" "" "Age filter enabled"
else
  log_event info script "<global>" "filter" "max_age" "" "" "No age filter (MAX_AGE_DAYS not set)"
fi

if [[ -n "${IMAGE_PREFIX:-}" ]]; then
  log_event info script "<global>" "filter" "prefix" "$IMAGE_PREFIX" "" "Tag prefix filter active"
else
  log_event info script "<global>" "filter" "prefix" "" "" "No prefix filter (IMAGE_PREFIX not set)"
fi

# === HELPERS ===

is_prefix_match() {
  local tag="$1"
  [[ -z "${IMAGE_PREFIX:-}" || "$tag" == "$IMAGE_PREFIX"* ]]
}

is_old_enough() {
  local ts="$1"
  [[ -z "$cutoff_ts" || "$ts" -lt "$cutoff_ts" ]]
}

# === DOCKER HUB (improved: delete tagged + attempt to delete manifests (including untagged) by digest) ===
delete_from_dockerhub() {
  local provider="dockerhub"
  local repo="$DOCKERHUB_REPO"
  log_event info "$provider" "$repo" "start" "repo" "$repo" "" "Starting Docker Hub cleanup"

  # Hub API token (for tag listing/deletion)
  hub_token=$(curl -s -X POST "$DOCKERHUB_API/users/login/" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DOCKERHUB_USERNAME\",\"password\":\"$DOCKERHUB_PASSWORD\"}" |
    jq -r .token)

  if [[ -z "$hub_token" || "$hub_token" == "null" ]]; then
    log_event error "$provider" "$repo" "auth" "repo" "$repo" "" "Failed to obtain Hub API token"
    return 1
  fi
  log_event info "$provider" "$repo" "auth" "repo" "" "" "Obtained Hub API token"

  # Registry token (for manifest digest + DELETE via registry API)
  registry_token=$(curl -s -u "$DOCKERHUB_USERNAME:$DOCKERHUB_PASSWORD" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$DOCKERHUB_REPO:pull,delete" |
    jq -r .token)

  if [[ -z "$registry_token" || "$registry_token" == "null" ]]; then
    log_event warn "$provider" "$repo" "auth" "registry" "" "" "Failed to obtain registry token (manifest DELETE may fail)"
  else
    log_event info "$provider" "$repo" "auth" "registry" "" "" "Obtained registry token"
  fi

  next="$DOCKERHUB_API/repositories/$DOCKERHUB_REPO/tags?page_size=100"

  while [[ "$next" != "null" ]]; do
    resp=$(curl -s -H "Authorization: JWT $hub_token" "$next")
    next=$(echo "$resp" | jq -r .next)

    # iterate over results (each result corresponds to a tag/version/manifests entry)
    echo "$resp" | jq -c '.results[]' | while read -r item; do
      name=$(echo "$item" | jq -r '.name // empty')
      manifest_digest=$(echo "$item" | jq -r '.digest // empty')
      mapfile -t image_digests < <(echo "$item" | jq -r '.images[]?.digest // empty' | grep -v '^$' || true)
      last_updated=$(echo "$item" | jq -r '.last_updated // empty')

      # Age & prefix filters (if provided)
      if [[ -n "$name" ]]; then
        if ! is_prefix_match "$name"; then
          log_event info "$provider" "$repo" "skip" "tag" "$name" "" "Prefix mismatch"
          continue
        fi
      else
        # untagged entries have no name; allow prefix-match check to pass if no IMAGE_PREFIX set
        if [[ -n "${IMAGE_PREFIX:-}" ]]; then
          log_event info "$provider" "$repo" "skip" "untagged" "" "" "Skipping untagged entry because IMAGE_PREFIX set"
          continue
        fi
      fi

      if [[ -n "$last_updated" ]]; then
        ts=$(date -d "$last_updated" +%s)
        if ! is_old_enough "$ts"; then
          log_event info "$provider" "$repo" "skip" "tag" "${name:-<untagged>}" "" "Newer than cutoff"
          continue
        fi
      fi

      # Delete tag via Hub API (if it has a name)
      if [[ -n "$name" ]]; then
        log_event info "$provider" "$repo" "delete_attempt" "tag" "$name" "" "Deleting tag via Hub API"
        hub_del_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
          -H "Authorization: JWT $hub_token" \
          "$DOCKERHUB_API/repositories/$DOCKERHUB_REPO/tags/$name/" || echo "000")
        if [[ "$hub_del_status" =~ ^(200|202|204)$ ]]; then
          log_event info "$provider" "$repo" "delete_success" "tag" "$name" "$hub_del_status" "Hub API tag deleted"
        else
          log_event warn "$provider" "$repo" "delete_failed" "tag" "$name" "$hub_del_status" "Hub API delete returned non-success"
        fi
      else
        log_event info "$provider" "$repo" "delete_attempt" "untagged" "" "" "No tag name — will attempt manifest delete by digest"
      fi

      # Try registry DELETE for manifest digest (top-level digest is usually the manifest/index digest)
      if [[ -n "$manifest_digest" ]]; then
        log_event info "$provider" "$repo" "delete_attempt" "manifest" "$manifest_digest" "" "Attempting registry DELETE for manifest digest"
        del_url="https://registry-1.docker.io/v2/$DOCKERHUB_REPO/manifests/$manifest_digest"
        status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $registry_token" "$del_url" || echo "000")
        if [[ "$status" == "202" || "$status" == "200" ]]; then
          log_event info "$provider" "$repo" "delete_success" "manifest" "$manifest_digest" "$status" "Registry manifest deleted"
        else
          log_event warn "$provider" "$repo" "delete_failed" "manifest" "$manifest_digest" "$status" "Registry DELETE returned non-success (may be unsupported on Docker Hub)"
        fi
      else
        # if no top-level digest, try to HEAD manifest by tag/name to obtain Docker-Content-Digest
        if [[ -n "$name" ]]; then
          manifest_url="https://registry-1.docker.io/v2/$DOCKERHUB_REPO/manifests/$name"
          digest_hdr=$(curl -sI -H "Authorization: Bearer $registry_token" \
            -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
            "$manifest_url" | awk -F': ' '/Docker-Content-Digest/ {print $2}' | tr -d '\r' || true)
          if [[ -n "$digest_hdr" ]]; then
            log_event info "$provider" "$repo" "delete_attempt" "manifest" "$digest_hdr" "" "Found Docker-Content-Digest -> attempting DELETE"
            del_url="https://registry-1.docker.io/v2/$DOCKERHUB_REPO/manifests/$digest_hdr"
            status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $registry_token" "$del_url" || echo "000")
            if [[ "$status" == "202" || "$status" == "200" ]]; then
              log_event info "$provider" "$repo" "delete_success" "manifest" "$digest_hdr" "$status" "Registry manifest deleted"
            else
              log_event warn "$provider" "$repo" "delete_failed" "manifest" "$digest_hdr" "$status" "Registry DELETE returned non-success"
            fi
          else
            log_event warn "$provider" "$repo" "skip" "manifest" "$name" "" "Could not determine Docker-Content-Digest for tag"
          fi
        fi
      fi

      # Additionally try deleting per-architecture image manifests (best-effort)
      for imgd in "${image_digests[@]:-}"; do
        if [[ -n "$imgd" ]]; then
          log_event info "$provider" "$repo" "delete_attempt" "manifest" "$imgd" "" "Attempting registry DELETE for image/platform digest"
          del_url="https://registry-1.docker.io/v2/$DOCKERHUB_REPO/manifests/$imgd"
          status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $registry_token" "$del_url" || echo "000")
          if [[ "$status" == "202" || "$status" == "200" ]]; then
            log_event info "$provider" "$repo" "delete_success" "manifest" "$imgd" "$status" "Per-arch manifest deleted"
          else
            log_event warn "$provider" "$repo" "delete_failed" "manifest" "$imgd" "$status" "Registry DELETE returned non-success"
          fi
        fi
      done

    done
  done

  log_event info "$provider" "$repo" "finished" "repo" "$repo" "" "Docker Hub cleanup finished"
}

# === GHCR (delete both tagged and untagged via GitHub Packages API) ===
delete_from_ghcr() {
  local provider="ghcr"
  local repo="$GHCR_REPO"
  log_event info "$provider" "$repo" "start" "repo" "$repo" "" "Starting GHCR cleanup"

  repo_path="${GHCR_REPO#ghcr.io/}"
  owner=$(echo "$repo_path" | cut -d'/' -f1)
  package=$(echo "$repo_path" | cut -d'/' -f2)
  api_base="https://api.github.com"

  endpoint_org="$api_base/orgs/$owner/packages/container/$package/versions"
  endpoint_user="$api_base/users/$owner/packages/container/$package/versions"

  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GHCR_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$endpoint_org")

  if [[ "$http_status" == "200" ]]; then
    api_endpoint="$endpoint_org"
    delete_base="$api_base/orgs/$owner/packages/container/$package/versions"
    log_event info "$provider" "$repo" "auth" "repo" "$repo" "" "Package under org detected"
  else
    api_endpoint="$endpoint_user"
    delete_base="$api_base/users/$owner/packages/container/$package/versions"
    log_event info "$provider" "$repo" "auth" "repo" "$repo" "" "Package under user detected"
  fi

  page=1
  while :; do
    hdrfile=$(mktemp)
    body=$(curl -s -D "$hdrfile" -H "Authorization: Bearer $GHCR_TOKEN" -H "Accept: application/vnd.github+json" \
      "$api_endpoint?per_page=100&page=$page")

    err_msg=$(echo "$body" | jq -r 'if type=="object" then (.message // empty) else empty end')
    if [[ -n "$err_msg" ]]; then
      log_event error "$provider" "$repo" "api_error" "repo" "" "" "GitHub API error on page $page: $err_msg"
      rm -f "$hdrfile"
      return 1
    fi

    count=$(echo "$body" | jq -r 'if type=="array" then length else 0 end')
    if [[ "$count" -eq 0 ]]; then
      log_event info "$provider" "$repo" "pager" "repo" "" "" "No versions on page $page -> done"
      rm -f "$hdrfile"
      break
    fi

    log_event info "$provider" "$repo" "pager" "repo" "" "" "Processing page $page with $count versions"

    echo "$body" | jq -c '.[]' | while IFS= read -r ver_json; do
      if ! echo "$ver_json" | jq -e . >/dev/null 2>&1; then
        log_event warn "$provider" "$repo" "skip" "package-version" "" "" "Skipping unparsable version JSON"
        continue
      fi

      id=$(echo "$ver_json" | jq -r '.id // empty')
      created_at=$(echo "$ver_json" | jq -r '.created_at // empty')

      tags_json=$(echo "$ver_json" | jq -c '.metadata.container.tags // []') || {
        log_event warn "$provider" "$repo" "skip" "package-version" "$id" "" "jq failed while extracting tags; skipping id"
        continue
      }

      if [[ "$tags_json" == "[]" ]]; then
        tags=()
      else
        mapfile -t tags < <(echo "$tags_json" | jq -r '.[]' 2>/dev/null) || tags=()
      fi

      if [[ -n "$created_at" && "$created_at" != "null" ]]; then
        ts=$(date -d "$created_at" +%s)
        if ! is_old_enough "$ts"; then
          log_event info "$provider" "$repo" "skip" "package-version" "$id" "" "Skipping id (newer than cutoff)"
          continue
        fi
      fi

      should_delete=false
      if [[ ${#tags[@]} -eq 0 ]]; then
        should_delete=true
        log_event info "$provider" "$repo" "delete_attempt" "package-version" "$id" "" "Untagged package-version will be deleted"
      else
        for t in "${tags[@]}"; do
          if is_prefix_match "$t"; then
            should_delete=true
            log_event info "$provider" "$repo" "delete_attempt" "package-version" "$id" "" "Matched tag '$t' -> will delete"
            break
          fi
        done
        if ! $should_delete; then
          log_event info "$provider" "$repo" "skip" "package-version" "$id" "" "Keeping package-version (tags do not match)"
        fi
      fi

      if $should_delete; then
        del_url="$delete_base/$id"
        resp=$(curl -s -w "\n%{http_code}" -X DELETE \
          -H "Authorization: Bearer $GHCR_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          "$del_url" || echo -e "\n000")
        http_code=$(echo "$resp" | tail -n1)
        resp_body=$(echo "$resp" | sed '$d')

        if [[ "$http_code" =~ ^(200|202|204)$ ]]; then
          log_event info "$provider" "$repo" "delete_success" "package-version" "$id" "$http_code" "Deleted package-version"
        else
          log_event warn "$provider" "$repo" "delete_failed" "package-version" "$id" "$http_code" "Failed to delete; response: $resp_body"
          if [[ "$http_code" == "403" || "$http_code" == "401" ]]; then
            log_event warn "$provider" "$repo" "auth" "repo" "" "$http_code" "403/401 — проверьте права токена (delete:packages) и принадлежность токена владельцу/админу org."
          fi
        fi
      fi

    done

    link_hdr=$(grep -i '^Link:' "$hdrfile" 2>/dev/null || true)
    rm -f "$hdrfile"

    if [[ -n "$link_hdr" ]] && echo "$link_hdr" | grep -q 'rel="next"'; then
      ((page++))
      log_event info "$provider" "$repo" "pager" "repo" "" "" "Proceeding to next page: $page"
      continue
    else
      log_event info "$provider" "$repo" "pager" "repo" "" "" "No Link: rel=\"next\" header — finished (processed page $page)"
      break
    fi
  done

  log_event info "$provider" "$repo" "finished" "repo" "$repo" "" "GHCR package-versions cleanup finished"
}

# === MAIN ===

if [[ -n "${DOCKERHUB_REPO:-}" && -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  delete_from_dockerhub
else
  log_event info script "<global>" "skip" "repo" "dockerhub" "" "Docker Hub cleanup skipped (missing env)"
fi

if [[ -n "${GHCR_REPO:-}" && -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  delete_from_ghcr
else
  log_event info script "<global>" "skip" "repo" "ghcr" "" "GHCR cleanup skipped (missing env)"
fi

log_event info script "<global>" "finished" "script" "" "" "Cleanup complete"
