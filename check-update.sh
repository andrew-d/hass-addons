#!/usr/bin/env bash

set -eu -o pipefail

check_repository() {
    local name="$1"
    local repository="$2"
    local ref="$3"
    local branch="$4"
    shift 4

    local tdir
    tdir="$(mktemp -d)"

    trap "rm -rf '$tdir'" RETURN

    # We can use git ls-remote to get the commit from the branch without cloning
    git init -q "$tdir/repo"
    git -C "$tdir/repo" remote add check "$repository"

    # See if the head of the branch is different
    local latest
    latest="$(git -C "$tdir/repo" ls-remote check "refs/heads/$branch" | awk '{ print $1 }')"

    if [[ "$latest" != "$ref" ]]; then
        echo "  UPDATE: $ref -> $latest" >&2
        return 0
    else
        echo "  OK: $ref" >&2
        return 1
    fi
}

main() {
    local updatable=()

    while read -r upstream; do
        local name repository ref prefix
        name="$(echo "$upstream" | jq -r .key)"
        repository="$(echo "$upstream" | jq -r .value.repository)"
        ref="$(echo "$upstream" | jq -r .value.ref)"
        branch="$(echo "$upstream" | jq -r .value.branch)"

        echo "Checking: $repository" >&2

        if check_repository "$name" "$repository" "$ref" "$branch"; then
            updatable+=("$name")
        fi
    done < <(jq -c '. | to_entries | .[]' upstreams.json)

    if [[ "${#updatable[@]}" -gt 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
