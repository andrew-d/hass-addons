#!/usr/bin/env bash

set -eu -o pipefail

clean_branches() {
    local name="$1"
    local id="$2"

    local branch
    declare -a remove
    while read -r branch; do
        if [[ "$branch" = "$name-$id-working"* ]]; then
            remove+=("$branch")
        fi
    done < <(git for-each-ref --format '%(refname:short)' refs/heads/)

    for branch in "${remove[@]}"; do
        echo "cleaning branch: $branch" >&2
        git branch -q -D "$branch" >/dev/null 2>&1 || true
    done

    # Remove the remote (if any)
    local remote="$name-remote-$id"
    git remote rm "$remote" >/dev/null 2>&1 || true
}

check_repository() {
    local name="$1"
    local repository="$2"
    local ref="$3"
    local prefix="$4"
    shift 4

    local id
    id="$(echo "$name-$repository-$ref" | sha256sum | head -c 10)"

    local initialbranch
    initialbranch="$(git branch --show-current)"

    # Remove branches on return or exit
    trap "clean_branches '$name' '$id'" RETURN

    # Add the repository as an origin
    local remote="$name-remote-$id"
    git remote rm "$remote" || true
    git remote add "$remote" "$repository"
    git fetch -q "$remote"

    # Create a branch from the given ref
    local branchprefix="$name-$id-working"
    git branch -q -D "$branchprefix" >/dev/null 2>&1 || true
    git checkout -q -b "$branchprefix" "$ref"

    # Create a branch that contains only the contents of the prefix
    git checkout -q "$branchprefix"

    local currbranch="$branchprefix-$prefix"
    git branch -q -D "$currbranch" >/dev/null 2>&1 || true

    # This prints the resulting HEAD of the created tree to stdout, which
    # we don't need.
    git subtree split -P "$prefix" -b "$currbranch" >/dev/null

    # Move back to the main branch
    git checkout -q "$initialbranch"

    # Remove the existing prefix data
    git rm -rf --quiet "$prefix"

    # Add the data from the branch to this directory prefix
    git read-tree -q --prefix="$prefix/" -u "$currbranch"

    # Apply patches, if any
    local patch
    for patch in "$@"; do
        patch="$(realpath "$patch")"
        (
            cd "$prefix/" \
            && patch \
                --no-backup-if-mismatch \
                -p0 \
                < "$patch" \
            && git add .
        )
    done
    git add "$prefix/"

    # Commit if there's any changes
    if [[ -n "$(git status --porcelain)" ]]; then
        git commit -q -m "$name: updated prefix '$prefix/' to $ref"
    else
        echo "$name: nothing to update in $prefix"
    fi
}

main() {
    while read -r upstream; do
        local name repository ref prefix
        name="$(echo "$upstream" | jq -r .key)"
        repository="$(echo "$upstream" | jq -r .value.repository)"
        ref="$(echo "$upstream" | jq -r .value.ref)"
        prefix="$(echo "$upstream" | jq -r .value.prefix)"

        echo "Checking: $repository"
        #echo "  $ref"

        # Get all patches that we're applying into a bash array; note that this
        # means that patches can't have '|' characters in them, which seems
        # fine.
        local patches
        { readarray -t -d '' patches && wait "$!"; } < <(
          set -o pipefail
          jq -j 'if (.value | has("patches")) then .value.patches[] | (., "\u0000") else "" end' <<<"$upstream"
        )

        check_repository "$name" "$repository" "$ref" "$prefix" "${patches[@]}"
    done < <(jq -c '. | to_entries | .[]' upstreams.json)
}

main "$@"
