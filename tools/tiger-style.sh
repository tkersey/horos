#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'Usage: bash tools/tiger-style.sh BASE|--all [HEAD]\n' >&2
    exit 64
fi

auditor_revision=ac19a3fabd0b32fae3f6bf1becf5368c724e96f3
repository=$(git rev-parse --show-toplevel)
cd "$repository"

head=$(git rev-parse --verify --end-of-options "${2:-HEAD}^{commit}")
if [[ "$1" == --all ]]; then
    base=$head
else
    base=$(git rev-parse --verify --end-of-options "$1^{commit}")
fi
if [[ "$head" != "$(git rev-parse --verify HEAD)" ]]; then
    printf 'TigerStyle requires HEAD to be the requested candidate.\n' >&2
    exit 1
fi
if ! git diff --quiet --no-ext-diff --no-textconv "$head" -- ||
    ! git diff --cached --quiet --no-ext-diff --no-textconv "$head" --; then
    printf 'TigerStyle requires a clean committed candidate; commit tracked changes first.\n' >&2
    exit 1
fi
base=$(git merge-base "$base" "$head")

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

git diff --no-ext-diff --no-textconv --name-only -z --diff-filter=T \
    "$base" "$head" -- ':(glob)**/*.zig' > "$scratch/type-changes"
if [[ -s "$scratch/type-changes" ]]; then
    printf 'TigerStyle cannot audit changed Zig file types; preserve regular source files.\n' >&2
    exit 1
fi

git diff --no-ext-diff --no-textconv --no-renames --numstat -z \
    --diff-filter=ACMR "$base" "$head" -- ':(glob)**/*.zig' > "$scratch/changes"
while IFS= read -r -d '' change; do
    if [[ "$change" == $'-\t-\t'* ]]; then
        printf 'TigerStyle cannot audit a binary-classified Zig change: %s\n' "$change" >&2
        exit 1
    fi
done < "$scratch/changes"

git init --quiet "$scratch/auditor"
git -C "$scratch/auditor" fetch --quiet --depth=1 \
    https://github.com/tkersey/skills-zig.git "$auditor_revision"
git -C "$scratch/auditor" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
if [[ "$(git -C "$scratch/auditor" rev-parse HEAD)" != "$auditor_revision" ]]; then
    printf 'TigerStyle auditor revision mismatch.\n' >&2
    exit 1
fi

printf 'TigerStyle: base=%s head=%s auditor=%s\n' "$base" "$head" "$auditor_revision"
zig test "$scratch/auditor/tools/tiger_style/main.zig"
if [[ "$1" == --all ]]; then
    paths=()
    git ls-files --stage -z -- '*.zig' > "$scratch/sources"
    while IFS= read -r -d '' entry; do
        metadata=${entry%%$'\t'*}
        path=${entry#*$'\t'}
        mode=${metadata%% *}
        if [[ "$mode" != 100644 && "$mode" != 100755 ]] ||
            [[ ! -f "$path" || -L "$path" ]]; then
            printf 'TigerStyle requires regular tracked Zig files: %s\n' "$path" >&2
            exit 1
        fi
        paths+=("$path")
    done < "$scratch/sources"
    if [[ ${#paths[@]} -eq 0 ]]; then
        printf 'TigerStyle requires at least one tracked Zig file.\n' >&2
        exit 1
    fi
    zig run "$scratch/auditor/tools/tiger_style/main.zig" -- audit-files "${paths[@]}"
    exit
fi
zig run "$scratch/auditor/tools/tiger_style/main.zig" -- \
    audit-diff --base "$base" --head "$head"
