#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

launcher=$(cd -- "$(dirname -- "$0")" && pwd)/tiger-style.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
git init --quiet "$scratch/repository"
cd "$scratch/repository"
git config user.name TigerStyle
git config user.email tiger-style@example.invalid
git config commit.gpgsign false
git config core.hooksPath /dev/null

commit_fixture() {
    git add --all
    git commit --quiet -m "$1"
}

expect_failure() {
    local expected=$1
    shift
    if bash "$launcher" "$@" > "$scratch/result" 2>&1; then
        printf 'Expected TigerStyle failure: %s\n' "$expected" >&2
        cat "$scratch/result" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$scratch/result"; then
        cat "$scratch/result" >&2
        exit 1
    fi
}

printf 'fn legacy() void { while (true) {} }\n' > legacy.zig
printf 'const value = true;\n' > existing.zig
printf 'fn hidden() void { while (true) {} }\n' > source.txt
printf '/.zig-cache/\n' > .gitignore
commit_fixture baseline
base=$(git rev-parse HEAD)

printf 'const value = false;\n' > existing.zig
commit_fixture valid
if ! bash "$launcher" "$base" HEAD > "$scratch/result" 2>&1; then
    cat "$scratch/result" >&2
    exit 1
fi
grep -Fq 'TigerStyle passed:' "$scratch/result"
valid=$(git rev-parse HEAD)

expect_failure 'requires HEAD to be the requested candidate' "$base" "$base"
expect_failure 'Needed a single revision' tiger-style-missing-revision HEAD

printf 'const edited = true;\n' >> existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git add existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git show "$valid:existing.zig" > existing.zig
expect_failure 'requires a clean committed candidate' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'fn bad() void { fail() catch unreachable; }\n' >> existing.zig
commit_fixture added-line
expect_failure 'tiger-style/error-handling' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'fn recurse() void {\n    recurse();\n}\n' > new.zig
commit_fixture new-file
expect_failure 'tiger-style/recursion' "$base" HEAD
git reset --quiet --hard "$valid"

printf 'existing.zig -diff\n' > .gitattributes
printf 'const value = 1;\n' > existing.zig
commit_fixture binary-zig
expect_failure 'cannot audit a binary-classified Zig change' "$base" HEAD
git reset --quiet --hard "$valid"

rm existing.zig
ln -s source.txt existing.zig
commit_fixture source-type
expect_failure 'cannot audit changed Zig file types' "$base" HEAD

printf 'TigerStyle integration passed: legacy debt, valid change, added-line/new-file rejection, revisions, index/worktree, binary/type changes.\n'
