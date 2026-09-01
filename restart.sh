#!/bin/bash
#
# Resets the checkout to the remote and pulls the latest images, then recreates
# the servers if either of those actually changed.
#
#   ./restart.sh        restart only if there were updates, or if the stack
#                       isn't running
#   ./restart.sh -f     restart regardless

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="production.yml"

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
}

force=false
case "${1:-}" in
  -f|--force) force=true ;;
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "restart.sh: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
esac

# Compose needs root for the docker socket, and production.yml interpolates the
# two env files kept in the parent directory.
dc() {
  sudo bash -c '
    cd "$1" || exit 1
    source ../tfl_host.env
    source ../qwtflive.env.production
    compose_file=$2
    shift 2
    exec docker compose -f "$compose_file" "$@"
  ' _ "$REPO_DIR" "$COMPOSE_FILE" "$@"
}

upstream_ref() {
  git -C "$REPO_DIR" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo origin/master
}

git_updated() {
  local upstream head remote dirty=false

  upstream=$(upstream_ref)
  git -C "$REPO_DIR" fetch --quiet origin

  head=$(git -C "$REPO_DIR" rev-parse HEAD)
  remote=$(git -C "$REPO_DIR" rev-parse "$upstream")

  # Tracked files only: reset --hard cannot remove untracked ones, so counting
  # them here would report drift on every run forever.
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]]; then
    dirty=true
  fi

  # Hosts never carry local work, so take the remote wholesale rather than
  # merging into whatever is here.
  git -C "$REPO_DIR" reset --hard --quiet "$remote"

  if [[ $head != "$remote" ]]; then
    echo "git:    $(git -C "$REPO_DIR" rev-parse --short "$head") -> $(git -C "$REPO_DIR" rev-parse --short "$remote")"
    return 0
  fi

  # Same commit, but the working tree had drifted and has just been thrown
  # away, so the running containers are on something that no longer exists.
  if $dirty; then
    echo "git:    discarded local changes"
    return 0
  fi

  echo "git:    up to date"
  return 1
}

image_ids() {
  local image
  while read -r image; do
    [[ -n $image ]] || continue
    printf '%s %s\n' "$image" \
      "$(sudo docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || echo absent)"
  done <<< "$1"
}

images_updated() {
  local images before after
  images=$(dc config --images | sort -u)

  before=$(image_ids "$images")
  dc pull --quiet
  after=$(image_ids "$images")

  if [[ $before == "$after" ]]; then
    echo "images: up to date"
    return 1
  fi

  comm -13 <(echo "$before") <(echo "$after") | cut -d' ' -f1 | sed 's/^/images: pulled /'
}

# Runs both checks; returns 0 if either found something. Neither short-circuits,
# so images are pulled even when git was already current.
check_updates() {
  local found=1

  git_updated && found=0
  images_updated && found=0

  return "$found"
}

stack_down() {
  [[ -z "$(dc ps --quiet)" ]]
}

# Runs even under -f, so a forced restart still comes up on current code.
updated=false
if check_updates; then
  updated=true
fi

restart=true
if $force; then
  echo "==> Forced restart"
elif $updated; then
  echo "==> Updates found, restarting"
elif stack_down; then
  echo "==> Nothing running, starting"
else
  echo "==> Already up to date, nothing to do"
  restart=false
fi

if $restart; then
  dc down --remove-orphans
  dc up -d
fi

# Always: clears the images the pull superseded, plus anything left dangling.
sudo docker image prune -f
