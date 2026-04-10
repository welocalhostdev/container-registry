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
#   API_URL            internal URL of the registry service (default http://registry:5000)
#                      NOTE: must not start with REGISTRY_ — the registry:2 image
#                      intercepts REGISTRY_* env vars as config overrides.
#   KEEP_LAST          how many tags to keep per repo (default 10)
#   ADMIN_USERNAME     htpasswd user with full perms
#   ADMIN_PASSWORD     htpasswd password

set -eu

API_URL="${API_URL:-http://registry:5000}"
KEEP_LAST="${KEEP_LAST:-10}"
AUTH="${ADMIN_USERNAME}:${ADMIN_PASSWORD}"
REPO_BASE=/var/lib/registry/docker/registry/v2/repositories

log() { echo "[retention] $*"; }

log "starting cycle (registry=$API_URL keep_last=$KEEP_LAST)"

# --- list repositories ------------------------------------------------------
REPOS=$(curl -fsS -u "$AUTH" "$API_URL/v2/_catalog?n=10000" 2>/dev/null \
  | jq -r '.repositories[]?' || true)

if [ -z "${REPOS:-}" ]; then
  log "no repositories found"
else
  printf '%s\n' "$REPOS" | while IFS= read -r repo; do
    [ -z "$repo" ] && continue

    TAGS=$(curl -fsS -u "$AUTH" "$API_URL/v2/$repo/tags/list" 2>/dev/null \
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
        "$API_URL/v2/$repo/manifests/$tag" 2>/dev/null \
        | awk 'tolower($1) == "docker-content-digest:" { gsub(/\r/, ""); print $2 }' \
        | head -n1)

      if [ -z "${DIGEST:-}" ]; then
        log "  $repo:$tag — could not resolve digest, skipping"
        continue
      fi

      if curl -fsS -u "$AUTH" -X DELETE \
           "$API_URL/v2/$repo/manifests/$DIGEST" >/dev/null 2>&1; then
        log "  deleted $repo:$tag ($DIGEST)"
      else
        log "  failed to delete $repo:$tag"
      fi
    done
  done
fi

# --- garbage collect --------------------------------------------------------
# GC walks $REPO_BASE. If the registry has never had a push, that path
# won't exist yet and the registry binary aborts with "Path not found".
# Skip GC when there's nothing to collect.
if [ -d "$REPO_BASE" ] && [ -n "$(ls -A "$REPO_BASE" 2>/dev/null)" ]; then
  log "running garbage collection"
  registry garbage-collect /etc/docker/registry/config.yml --delete-untagged 2>&1 \
    | sed 's/^/[retention-gc] /' \
    || log "gc exited non-zero (continuing)"
else
  log "no repositories on disk, skipping garbage collection"
fi

# --- prune empty repo directories -------------------------------------------
# Docker Registry v2 has no API to delete a repo — the catalog reads from
# the filesystem, so a repo with zero tags still appears in /v2/_catalog
# as an empty listing. Walk the filesystem and remove any repo whose
# _manifests/tags directory is empty, then clean up now-empty parent
# directories (for nested repos like `team/project/app`).

if [ -d "$REPO_BASE" ]; then
  log "scanning for empty repositories"

  # find every */_manifests/tags directory (one per repo, always at the leaf)
  find "$REPO_BASE" -type d -path '*/_manifests/tags' 2>/dev/null | while IFS= read -r tags_dir; do
    # empty if `ls -A` returns nothing
    if [ -z "$(ls -A "$tags_dir" 2>/dev/null)" ]; then
      repo_dir=${tags_dir%/_manifests/tags}
      repo_name=${repo_dir#"$REPO_BASE"/}
      log "  empty repo: $repo_name — removing $repo_dir"
      rm -rf "$repo_dir"

      # walk up and prune any parent directories that became empty
      parent=$(dirname "$repo_dir")
      while [ "$parent" != "$REPO_BASE" ] && [ -d "$parent" ] \
            && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; do
        rmdir "$parent" 2>/dev/null || break
        parent=$(dirname "$parent")
      done
    fi
  done
fi

log "cycle complete"
