#!/bin/sh
# Retention pass for Docker Registry v2.
#
# Walks every repository in /v2/_catalog, keeps the newest KEEP_LAST tags
# (version-sorted, falling back to lexicographic), and DELETEs the rest
# via the manifests API. Finally runs `registry garbage-collect` against
# the shared storage volume to reclaim disk from untagged manifests and
# orphaned blobs.
#
# Env:
#   REGISTRY_URL       internal URL of the registry service (default http://registry:5000)
#   KEEP_LAST          how many tags to keep per repo (default 10)
#   ADMIN_USERNAME     htpasswd user with full perms
#   ADMIN_PASSWORD     htpasswd password

set -eu

REGISTRY_URL="${REGISTRY_URL:-http://registry:5000}"
KEEP_LAST="${KEEP_LAST:-10}"
AUTH="${ADMIN_USERNAME}:${ADMIN_PASSWORD}"

log() { echo "[retention] $*"; }

log "starting cycle (registry=$REGISTRY_URL keep_last=$KEEP_LAST)"

# --- list repositories ------------------------------------------------------
REPOS=$(curl -fsS -u "$AUTH" "$REGISTRY_URL/v2/_catalog?n=10000" 2>/dev/null \
  | jq -r '.repositories[]?' || true)

if [ -z "${REPOS:-}" ]; then
  log "no repositories found"
else
  printf '%s\n' "$REPOS" | while IFS= read -r repo; do
    [ -z "$repo" ] && continue

    TAGS=$(curl -fsS -u "$AUTH" "$REGISTRY_URL/v2/$repo/tags/list" 2>/dev/null \
      | jq -r '.tags[]?' || true)

    if [ -z "${TAGS:-}" ]; then
      log "$repo: no tags"
      continue
    fi

    TAG_COUNT=$(printf '%s\n' "$TAGS" | wc -l | tr -d ' ')

    if [ "$TAG_COUNT" -le "$KEEP_LAST" ]; then
      log "$repo: $TAG_COUNT tag(s), keeping all"
      continue
    fi

    log "$repo: $TAG_COUNT tag(s), pruning to $KEEP_LAST newest"

    # Version-sort descending (GNU sort -V from coreutils), then drop the
    # first KEEP_LAST lines — what remains is the delete list.
    TAGS_TO_DELETE=$(printf '%s\n' "$TAGS" | sort -rV | awk -v n="$KEEP_LAST" 'NR > n')

    printf '%s\n' "$TAGS_TO_DELETE" | while IFS= read -r tag; do
      [ -z "$tag" ] && continue

      # HEAD the manifest to capture its digest. Send Accept headers for
      # every manifest media type so we get the canonical digest the
      # registry uses internally (otherwise the DELETE may 404).
      DIGEST=$(curl -fsS -I -u "$AUTH" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        "$REGISTRY_URL/v2/$repo/manifests/$tag" 2>/dev/null \
        | awk 'tolower($1) == "docker-content-digest:" { gsub(/\r/, ""); print $2 }' \
        | head -n1)

      if [ -z "${DIGEST:-}" ]; then
        log "  $repo:$tag — could not resolve digest, skipping"
        continue
      fi

      if curl -fsS -u "$AUTH" -X DELETE \
           "$REGISTRY_URL/v2/$repo/manifests/$DIGEST" >/dev/null 2>&1; then
        log "  deleted $repo:$tag ($DIGEST)"
      else
        log "  failed to delete $repo:$tag"
      fi
    done
  done
fi

# --- garbage collect --------------------------------------------------------
log "running garbage collection"
registry garbage-collect /etc/docker/registry/config.yml --delete-untagged 2>&1 \
  | sed 's/^/[retention-gc] /' \
  || log "gc exited non-zero (continuing)"

log "cycle complete"
