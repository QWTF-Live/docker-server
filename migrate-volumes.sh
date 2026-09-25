#!/bin/bash
#
# Move the pre-single-container data into the one volume that replaced it.
#
# The old layout passed files between the updater and five server containers
# through thirteen named volumes. In one container that is just a directory, so
# production.yml now declares two volumes instead. `docker compose down` never
# removes named volumes, though, which would leave the old thirteen on disk
# holding real data: demos not yet uploaded to S3, stats not yet posted, and
# the whole map and asset tree the updater would otherwise re-sync on every
# host.
#
# This copies each of them to where the new layout expects it, then deletes it.
#
#   ./migrate-volumes.sh              migrate, then remove the old volumes
#   ./migrate-volumes.sh --dry-run    say what would happen, touch nothing
#   ./migrate-volumes.sh --keep       migrate but leave the old volumes in place
#
# Safe to run repeatedly: once the old volumes are gone it does nothing, so
# deploy can call it unconditionally. Nothing is deleted unless its copy
# succeeded, and existing files at the destination are never overwritten - a
# half-finished run resumes rather than clobbering.
#
# The stack must be down, since a volume in use cannot be removed and copying
# from underneath a running server would race it. This brings it down itself;
# restart.sh brings the new one up afterwards.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE=production.yml
PROJECT=docker-server

# Tiny, and the only thing it has to do is cp.
HELPER=busybox:latest

SHARDS=(pub duel tourney scrim staging)

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

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

# old volume name -> path within the new tf-data volume
declare -a MIGRATIONS=(
  "assets|assets"
  "master_dats|dats/master"
  "staging_dats|dats/staging"
)
for s in "${SHARDS[@]}"; do
  MIGRATIONS+=("${s}-demos|shards/${s}/fortress/demos")
  MIGRATIONS+=("${s}-stats|shards/${s}/fortress/data")
done

# Nothing to do at all? Say so and leave, so a fresh host and a migrated one
# both come out of this silently.
pending=false
for m in "${MIGRATIONS[@]}"; do
  volume_exists "${PROJECT}_${m%%|*}" && pending=true && break
done
if ! $pending && volume_exists "${PROJECT}_letsencrypt"; then
  say "==> Nothing to migrate"
  exit 0
fi

say "==> Migrating the old volume layout into ${PROJECT}_tf-data"

# A volume in use cannot be removed, and a server still writing demos would
# race the copy.
if [[ -n "$("${DOCKER[@]}" compose -f "${REPO_DIR}/${COMPOSE_FILE}" ps --quiet 2>/dev/null)" ]]; then
  say "--> Stopping the stack"
  run "${DOCKER[@]}" compose -f "${REPO_DIR}/${COMPOSE_FILE}" down --remove-orphans
fi

if ! $dry_run; then
  "${DOCKER[@]}" volume create "${PROJECT}_tf-data" >/dev/null
  "${DOCKER[@]}" volume create "${PROJECT}_letsencrypt" >/dev/null
  "${DOCKER[@]}" pull --quiet "$HELPER" >/dev/null
fi

# The old server and updater images are superseded by qwtflive/fortressone,
# which has both inside it. restart.sh would never reclaim them: `image prune`
# without -a only drops dangling images, and these keep their tags. Removing
# them here frees the space BEFORE the copy needs it, which matters on a host
# that is already tight.
#
# Only when the old volumes are going too: with --keep the point is to stay
# able to roll back, and that needs the images.
if ! $keep; then
  for img in qwtflive/qwtfsv:latest qwtflive/updater:latest; do
    "${DOCKER[@]}" image inspect "$img" >/dev/null 2>&1 || continue
    say "--> Removing superseded image $img"
    run "${DOCKER[@]}" image rm "$img" >/dev/null 2>&1 \
      || say "    ! still in use; leaving it"
  done
fi

# Copying needs room for one volume in duplicate - each is freed as it lands -
# so the largest single one is the high-water mark. Checked rather than
# discovered halfway through: a full disk mid-copy leaves both a partial
# destination and the source it came from.
if ! $dry_run; then
  mounts=()
  for m in "${MIGRATIONS[@]}"; do
    vol="${PROJECT}_${m%%|*}"
    volume_exists "$vol" && mounts+=(-v "${vol}:/old/${m%%|*}:ro")
  done
  if [[ ${#mounts[@]} -gt 0 ]]; then
    largest_kb=$("${DOCKER[@]}" run --rm "${mounts[@]}" "$HELPER" \
      sh -c 'du -sk /old/* 2>/dev/null | sort -rn | head -1 | cut -f1' || echo 0)
    root=$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
    free_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
    need_kb=$(( largest_kb + largest_kb / 10 ))   # +10% margin
    say "--> Largest volume $(( largest_kb / 1024 ))M, free $(( free_kb / 1024 ))M on $root"
    if [[ $free_kb -lt $need_kb ]]; then
      say "migrate-volumes: not enough space: need ~$(( need_kb / 1024 ))M free, have $(( free_kb / 1024 ))M" >&2
      say "  free some up (docker image prune -a) and re-run; nothing has been changed yet" >&2
      exit 1
    fi
  fi
fi

migrated=()
for m in "${MIGRATIONS[@]}"; do
  old="${PROJECT}_${m%%|*}"
  dest="${m##*|}"

  volume_exists "$old" || continue
  say "--> ${m%%|*} -> /srv/${dest}"

  # tar rather than cp: busybox `cp -n` silently copies nothing at all, and
  # `cp -a /src/.` misses nothing but cannot decline to overwrite. tar -xk
  # keeps whatever is already at the destination, so an interrupted run
  # resumes instead of replacing newer files with older ones, and dotfiles,
  # symlinks and permissions all survive.
  #
  # The copy is verified rather than trusted: this deletes the source
  # afterwards, so "the container exited 0" is not good enough. Every regular
  # file in the source must be present in the destination.
  if run "${DOCKER[@]}" run --rm \
       -v "${old}:/src:ro" \
       -v "${PROJECT}_tf-data:/dst" \
       "$HELPER" sh -c "
         set -e
         mkdir -p '/dst/${dest}'
         tar cf - -C /src . | tar xkf - -C '/dst/${dest}'
         missing=0
         cd /src
         for f in \$(find . -type f); do
           [ -e \"/dst/${dest}/\$f\" ] || { echo \"missing: \$f\" >&2; missing=1; }
         done
         exit \$missing"
  then
    migrated+=("$old")
    # Removed here rather than after the whole loop: holding every old volume
    # and a complete second copy of it at once needs twice the total data,
    # which is how california ran out of disk. Freeing each one as it lands
    # means never holding more than a single volume in duplicate.
    if $keep; then
      :
    elif "${DOCKER[@]}" volume rm "$old" >/dev/null 2>&1; then
      say "    copied and removed"
    else
      say "    ! copied, but could not remove ${old} (still in use?)"
    fi
  else
    say "    ! copy incomplete; keeping ${old}"
  fi
done

# The certificate lives in /etc/letsencrypt on the host, where the container
# cannot see it. Importing it keeps the existing certificate and its renewal
# config, instead of certbot issuing a fresh one and the shards serving the
# bundled self-signed pair until it does.
if [[ -d /etc/letsencrypt ]]; then
  say "--> /etc/letsencrypt -> the letsencrypt volume"
  run "${DOCKER[@]}" run --rm \
    -v /etc/letsencrypt:/src:ro \
    -v "${PROJECT}_letsencrypt:/dst" \
    "$HELPER" sh -c 'tar cf - -C /src . | tar xkf - -C /dst' \
    || say "    ! import failed; certbot will issue a fresh certificate"
  # Deliberately not deleted: it costs nothing, and it is the only copy of the
  # account key if this ever has to be undone.
fi

if $keep; then
  say "==> Migrated; ${#migrated[@]} old volume(s) kept (--keep)"
else
  say "==> Migrated and removed ${#migrated[@]} old volume(s)"
fi

say "==> Done"
