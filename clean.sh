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
  GHCR_TOKEN             GitHub token with delete:packages scope

  # Optional filters:
  IMAGE_PREFIX           Only delete tags starting with this prefix
  MAX_AGE_DAYS           Only delete tags older than this number of days

Examples:

  Delete all old GHCR images with prefix "myapp-" older than 10 days:
    GHCR_REPO=ghcr.io/org/repo \
    GHCR_TOKEN=ghp_... \
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


# === LOGGING ===
log_info()  { echo ":: $*"; }
log_warn()  { echo "!! $*" >&2; }

# === GLOBAL CONFIG ===
DOCKERHUB_API="https://hub.docker.com/v2"
GHCR_API="https://ghcr.io/v2"

# === FILTERS ===
cutoff_ts=""
if [[ -n "${MAX_AGE_DAYS:-}" ]]; then
  cutoff_ts=$(date -d "-$MAX_AGE_DAYS days" +%s)
  log_info "Age filter: older than $MAX_AGE_DAYS days"
else
  log_info "No age filter (MAX_AGE_DAYS not set)"
fi

if [[ -n "${IMAGE_PREFIX:-}" ]]; then
  log_info "Tag prefix filter: \"$IMAGE_PREFIX\""
else
  log_info "No prefix filter (IMAGE_PREFIX not set)"
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

delete_dockerhub_tag() {
  local token="$1"
  local tag_name="$2"
  log_info "Deleting Docker Hub tag: $tag_name"
  curl -s -X DELETE -H "Authorization: JWT $token" \
    "$DOCKERHUB_API/repositories/$DOCKERHUB_REPO/tags/$tag_name/" > /dev/null
}

delete_ghcr_tag() {
  local digest="$1"
  local tag="$2"
  log_info "Deleting GHCR tag: $tag ($digest)"
  curl -s -X DELETE -H "Authorization: Bearer $GHCR_TOKEN" \
    "$GHCR_API/$repo_path/manifests/$digest" > /dev/null
}

# === DOCKER HUB ===

delete_from_dockerhub() {
  log_info "Docker Hub cleanup: $DOCKERHUB_REPO"

  local login_url="$DOCKERHUB_API/users/login/"
  local token=$(curl -s -X POST "$login_url" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DOCKERHUB_USERNAME\",\"password\":\"$DOCKERHUB_PASSWORD\"}" |
    jq -r .token)

  local next="$DOCKERHUB_API/repositories/$DOCKERHUB_REPO/tags?page_size=100"

  while [[ "$next" != "null" ]]; do
    response=$(curl -s -H "Authorization: JWT $token" "$next")
    next=$(echo "$response" | jq -r .next)

    echo "$response" | jq -c '.results[]' | while read -r tag; do
      name=$(echo "$tag" | jq -r .name)
      updated=$(echo "$tag" | jq -r .last_updated)
      ts=$(date -d "$updated" +%s)

      is_prefix_match "$name" || continue
      is_old_enough "$ts" || continue

      delete_dockerhub_tag "$token" "$name"
    done
  done
}

# === GHCR ===

delete_from_ghcr() {
  log_info "GHCR cleanup: $GHCR_REPO"

  repo_path="${GHCR_REPO#ghcr.io/}"
  tags_url="$GHCR_API/$repo_path/tags/list"
  tags=$(curl -s -H "Authorization: Bearer $GHCR_TOKEN" "$tags_url" | jq -r '.tags[]')

  for tag in $tags; do
    is_prefix_match "$tag" || continue
    log_info "Checking GHCR tag: $tag"

    manifest_url="$GHCR_API/$repo_path/manifests/$tag"
    manifest=$(curl -s -H "Authorization: Bearer $GHCR_TOKEN" \
      -H "Accept: application/vnd.oci.image.index.v1+json" "$manifest_url")

    created=$(echo "$manifest" | jq -r '.manifests[0].annotations."org.opencontainers.image.created" // empty')
    digest=$(echo "$manifest" | jq -r '.manifests[0].digest')

    [[ -z "$digest" || "$digest" == "null" ]] && {
      log_warn "No digest for tag: $tag"
      continue
    }

    if [[ -n "$created" && "$created" != "null" ]]; then
      ts=$(date -d "$created" +%s)
      is_old_enough "$ts" || {
        log_info "Skipping $tag (newer than cutoff)"
        continue
      }
    fi

    delete_ghcr_tag "$digest" "$tag"
  done
}

# === MAIN ===

if [[ -n "${DOCKERHUB_REPO:-}" && -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  delete_from_dockerhub
else
  log_info "Docker Hub cleanup skipped (missing env)"
fi

if [[ -n "${GHCR_REPO:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  delete_from_ghcr
else
  log_info "GHCR cleanup skipped (missing env)"
fi

log_info "Cleanup complete"
