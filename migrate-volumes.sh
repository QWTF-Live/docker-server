#!/bin/bash
#
# Fold the pre-single-container volumes into the one that replaced them.
#
# The old layout passed files between the updater and five server containers
# through thirteen named volumes. In one container that is just a directory, so
# production.yml declares two instead. `docker compose down` never removes
# named volumes, though, so without this they stay on disk holding the old
# copy of everything.
#
# Not everything in them is worth moving, and on a full host moving it is the
# problem rather than the solution:
#
#   maps and assets  a large download. Preserved - re-syncing the bucket is
#                    slow and expensive, and it is the whole reason this
#                    script copies anything at all.
#   dats             tiny, and preserved with them for the same price.
#   demos            pushed to S3 as they are recorded. Dropped.
#   stats            posted to logs.qwtf.live as they are produced. Dropped.
#   the certificate  the only thing here that cannot be refetched, so it is
#                    imported from /etc/letsencrypt either way.
#
# Dropping the demo and stats volumes first is deliberate: it frees their space
# before the map copy needs it, which is the difference between fitting and not
# on a host that is already tight.
#
#   ./migrate-volumes.sh              as described above
#   ./migrate-volumes.sh --dry-run    say what would happen, touch nothing
#   ./migrate-volumes.sh --keep       copy everything, delete nothing
#
# --keep is the rollback-safe mode: it preserves the demo and stats volumes
# too and leaves every source in place, at the cost of needing room for a
# complete second copy.
#
# Safe to run repeatedly: once the old volumes are gone it does nothing, so
# restart.sh and deploy can both call it unconditionally. Nothing is deleted
# unless its copy succeeded, and existing files at the destination are never
# overwritten, so a half-finished run resumes rather than clobbering.
#
# The stack must be down: a volume in use cannot be removed, and copying from
# underneath a running server would race it. restart.sh calls this between its
# own down and up; run by hand, it brings the stack down itself.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE=production.yml
PROJECT=docker-server

# Tiny, and all it has to do is untar.
HELPER=busybox:latest

SHARDS=(pub duel tourney scrim staging)

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

dry_run=false
keep=false
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) dry_run=true ;;
    -k|--keep)    keep=true ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "migrate-volumes: unknown argument '$arg'" >&2; usage >&2; exit 1 ;;
  esac
done

# restart.sh always sudoes; match it unless this user can reach docker directly.
DOCKER=(docker)
docker info >/dev/null 2>&1 || DOCKER=(sudo docker)

say() { printf '%s\n' "$*"; }
run() { if $dry_run; then say "    would: ${*}"; else "$@"; fi; }

volume_exists() { "${DOCKER[@]}" volume inspect "$1" >/dev/null 2>&1; }

# old volume | path within tf-data | copy or drop
declare -a MIGRATIONS=(
  "assets|assets|copy"
  "master_dats|dats/master|copy"
  "staging_dats|dats/staging|copy"
)
for s in "${SHARDS[@]}"; do
  MIGRATIONS+=("${s}-demos|shards/${s}/fortress/demos|drop")
  MIGRATIONS+=("${s}-stats|shards/${s}/fortress/data|drop")
done

pending=false
for m in "${MIGRATIONS[@]}"; do
  volume_exists "${PROJECT}_${m%%|*}" && pending=true && break
done
if ! $pending && volume_exists "${PROJECT}_letsencrypt"; then
  say "==> Nothing to migrate"
  exit 0
fi

say "==> Folding the old volume layout into ${PROJECT}_tf-data"

# A volume in use cannot be removed, and a server still writing demos would
# race the copy. Usually already down: restart.sh calls this between its own
# down and up.
if [[ -n "$("${DOCKER[@]}" compose -f "${REPO_DIR}/${COMPOSE_FILE}" ps --quiet 2>/dev/null)" ]]; then
  say "--> Stopping the stack"
  run "${DOCKER[@]}" compose -f "${REPO_DIR}/${COMPOSE_FILE}" down --remove-orphans
fi

if ! $dry_run; then
  "${DOCKER[@]}" volume create "${PROJECT}_tf-data" >/dev/null
  "${DOCKER[@]}" volume create "${PROJECT}_letsencrypt" >/dev/null
  "${DOCKER[@]}" pull --quiet "$HELPER" >/dev/null
fi

# ---------------------------------------------------------------------------
# Free what does not need moving, before the copy needs the room.
# ---------------------------------------------------------------------------
# The old server and updater images are superseded by qwtflive/fortressone,
# which contains both. restart.sh would never reclaim them: `image prune`
# without -a only drops dangling images, and these keep their tags.
if ! $keep; then
  for img in qwtflive/qwtfsv:latest qwtflive/updater:latest; do
    "${DOCKER[@]}" image inspect "$img" >/dev/null 2>&1 || continue
    say "--> Removing superseded image $img"
    run "${DOCKER[@]}" image rm "$img" >/dev/null 2>&1 \
      || say "    ! still in use; leaving it"
  done

  for m in "${MIGRATIONS[@]}"; do
    IFS='|' read -r name dest disp <<<"$m"
    [[ $disp == drop ]] || continue
    volume_exists "${PROJECT}_${name}" || continue
    say "--> Dropping ${name} (already replicated off-host)"
    run "${DOCKER[@]}" volume rm "${PROJECT}_${name}" >/dev/null 2>&1 \
      || say "    ! could not remove it (still in use?)"
  done
fi

# ---------------------------------------------------------------------------
# Copy what is expensive to refetch.
# ---------------------------------------------------------------------------
to_copy=()
for m in "${MIGRATIONS[@]}"; do
  IFS='|' read -r name dest disp <<<"$m"
  { $keep || [[ $disp == copy ]]; } || continue
  volume_exists "${PROJECT}_${name}" && to_copy+=("$m")
done

# The move unlinks each file as it lands, so the high-water mark is the
# largest single FILE, not the largest volume. Checked up front all the same:
# running out midway leaves the tree split across both volumes. --keep copies
# instead of moving, so there it really is the whole volume.
if ! $dry_run && [[ ${#to_copy[@]} -gt 0 ]]; then
  mounts=()
  for m in "${to_copy[@]}"; do
    name="${m%%|*}"
    mounts+=(-v "${PROJECT}_${name}:/old/${name}:ro")
  done
  if $keep; then
    probe='du -sk /old/* 2>/dev/null | sort -rn | head -1 | cut -f1'
    what="volume"
  else
    probe='find /old -type f -exec du -k {} + 2>/dev/null | sort -rn | head -1 | cut -f1'
    what="file"
  fi
  largest_kb=$("${DOCKER[@]}" run --rm "${mounts[@]}" "$HELPER" sh -c "$probe" || echo 0)
  [[ -n $largest_kb ]] || largest_kb=0
  root=$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
  free_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
  need_kb=$(( largest_kb + largest_kb / 10 ))
  say "--> Largest $what $(( largest_kb / 1024 ))M, free $(( free_kb / 1024 ))M on $root"
  if [[ $free_kb -lt $need_kb ]]; then
    say "" >&2
    say "migrate-volumes: not enough space: need ~$(( need_kb / 1024 ))M free, have $(( free_kb / 1024 ))M" >&2
    say "" >&2
    say "  Where the disk has gone:" >&2
    "${DOCKER[@]}" system df >&2 || true
    say "" >&2
    say "  Reclaim the obvious first:" >&2
    say "    docker system prune -a -f          # every image nothing is running" >&2
    say "" >&2
    say "  If it still will not fit, the map tree is the only thing left here" >&2
    say "  and it is refetchable - drop it and let the updater re-sync:" >&2
    say "    docker volume rm ${PROJECT}_assets" >&2
    exit 1
  fi
fi

migrated=()
for m in "${to_copy[@]}"; do
  IFS='|' read -r name dest disp <<<"$m"
  old="${PROJECT}_${name}"
  say "--> ${name} -> /srv/${dest}"

  if $dry_run; then
    say "    would: move the contents of ${old} into /srv/${dest} and remove it"
    migrated+=("$old")
    continue
  fi

  if $keep; then
    # Copy, leaving the source untouched. Needs room for a full second copy -
    # that is the price of being able to roll back.
    #
    # tar rather than cp: busybox `cp -n` silently copies nothing at all, and
    # `cp -a /src/.` cannot decline to overwrite. tar -xk keeps whatever is
    # already at the destination, so an interrupted run resumes.
    ok=false
    "${DOCKER[@]}" run --rm -v "${old}:/src:ro" -v "${PROJECT}_tf-data:/dst" \
      "$HELPER" sh -c "
        set -e
        mkdir -p '/dst/${dest}'
        tar cf - -C /src . | tar xkf - -C '/dst/${dest}'
        cd /src
        missing=0
        for f in \$(find . -type f); do
          [ -e \"/dst/${dest}/\$f\" ] || { echo \"missing: \$f\" >&2; missing=1; }
        done
        exit \$missing" && ok=true
    if $ok; then
      migrated+=("$old")
      say "    copied (source kept)"
    else
      say "    ! copy incomplete; keeping ${old}"
    fi
    continue
  fi

  # Move one file at a time, unlinking each as it lands, so the source shrinks
  # as the destination grows. A bulk copy needs room for the whole tree twice
  # over, which is what california does not have; this needs room for the
  # largest single file. Slower - it is still a real copy per file, since the
  # two volumes are separate mounts inside the container - but the high-water
  # mark is what matters here, not the throughput.
  if "${DOCKER[@]}" run --rm -i \
       -v "${old}:/src" \
       -v "${PROJECT}_tf-data:/dst" \
       "$HELPER" sh -s "$dest" <<'INNER'
set -e
dest=$1
mkdir -p "/dst/$dest"
cd /src
find . \( -type f -o -type l \) | while IFS= read -r f; do
  mkdir -p "/dst/$dest/$(dirname "$f")"
  if [ -e "/dst/$dest/$f" ]; then
    rm -f "$f"                      # an earlier run already moved it
  else
    cp -a "$f" "/dst/$dest/$f" && rm -f "$f"
  fi
done
left=$(find . \( -type f -o -type l \) | wc -l)
[ "$left" -eq 0 ] || { echo "$left file(s) could not be moved" >&2; exit 1; }
INNER
  then
    migrated+=("$old")
    if "${DOCKER[@]}" volume rm "$old" >/dev/null 2>&1; then
      say "    moved and removed"
    else
      say "    ! moved, but could not remove ${old} (still in use?)"
    fi
  else
    say "    ! move incomplete; keeping ${old}"
  fi
done

# The certificate lives in /etc/letsencrypt on the host, where the container
# cannot see it. Importing it keeps the existing certificate and its renewal
# config instead of certbot issuing a fresh one, with the shards serving the
# bundled self-signed pair until it lands.
if [[ -d /etc/letsencrypt ]]; then
  say "--> /etc/letsencrypt -> the letsencrypt volume"
  run "${DOCKER[@]}" run --rm \
    -v /etc/letsencrypt:/src:ro \
    -v "${PROJECT}_letsencrypt:/dst" \
    "$HELPER" sh -c 'tar cf - -C /src . | tar xkf - -C /dst' \
    || say "    ! import failed; certbot will issue a fresh certificate"
  # Deliberately not deleted: it costs little, and it is the only copy of the
  # account key if this ever has to be undone.
fi

if $keep; then
  say "==> Copied ${#migrated[@]} volume(s); all sources kept (--keep)"
else
  say "==> Done"
fi
