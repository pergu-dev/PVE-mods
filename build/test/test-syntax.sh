#!/usr/bin/env bash
# build/test/test-syntax.sh
#
# Validates source syntax for all mod files without requiring a running system.
#
# Usage: test-syntax.sh <mod> | all
#
# Mods are auto-discovered by scanning for subdirectories of src/ that contain
# a files/ or patches/ directory. No installed package required.
#
# For each target mod it:
#   1. runs perl -c on every .pm file under <mod>/files/
#   2. runs node --check on every .js file under <mod>/files/
#   3. runs bash -n on post-apply.sh and post-revert.sh in <mod>/patches/

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${PVE_MODs_SRC_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/src/modules}"

info() { echo "[syntax] $*"; }
warn() { echo "[syntax] WARNING: $*" >&2; }

# List mod names by scanning SRC_DIR for subdirs that contain files/ or patches/.
list_modules() {
    local d name
    for d in "$SRC_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        if [[ -d "$d/files" || -d "$d/patches" ]]; then
            echo "$name"
        fi
    done | sort
}

# check_perl_syntax <mod>: run perl -c on every .pm under <mod>/files/
#
# If the module has a files.list manifest, construct a temporary Perl library
# using its installation destinations. This makes source-tree imports resolve
# to the current source files instead of older modules under /usr/share/perl5.
check_perl_syntax() {
    local mod="$1"
    local files_dir="$SRC_DIR/$mod/files"
    [[ -d "$files_dir" ]] || return 0

    local manifest="$files_dir/files.list"
    local temp_lib=""
    local ok=0 f output

    if [[ -f "$manifest" ]]; then
        temp_lib="$(mktemp -d)"

        while read -r source destination _mode; do
            [[ -n "${source:-}" ]] || continue
            [[ "$source" == \#* ]] && continue
            [[ "$source" == *.pm ]] || continue
            [[ "$destination" == usr/share/perl5/* ]] || continue

            local source_path="$files_dir/$source"
            local relative_destination="${destination#usr/share/perl5/}"
            local target_path="$temp_lib/$relative_destination"

            [[ -f "$source_path" ]] || continue

            mkdir -p "$(dirname "$target_path")"
            ln -s "$source_path" "$target_path"
        done < "$manifest"
    fi

    while IFS= read -r f; do
        if [[ -n "$temp_lib" ]]; then
            output="$(
                PERL5LIB="$temp_lib${PERL5LIB:+:$PERL5LIB}"                     perl -c "$f" 2>&1
            )"
        else
            output="$(perl -c "$f" 2>&1)"
        fi

        if [[ $? -ne 0 ]]; then
            warn "perl -c FAILED: $f"
            echo "$output"
            ok=1
        fi
    done < <(
        find "$files_dir"           -name "*.pm"           -type f |
        sort
    )

    [[ -n "$temp_lib" ]] && rm -rf "$temp_lib"

    return $ok
}

# check_js_syntax <mod>: run node --check on every .js under <mod>/files/
check_js_syntax() {
    local mod="$1"
    local files_dir="$SRC_DIR/$mod/files"
    [[ -d "$files_dir" ]] || return 0

    local ok=0 f output
    while IFS= read -r f; do
        output="$(node --check "$f" 2>&1)"
        if [[ $? -ne 0 ]]; then
            warn "node --check FAILED: $f"
            echo "$output"
            ok=1
        fi
    done < <(find "$files_dir" -name "*.js" -type f | sort)
    return $ok
}

# check_bash_syntax <mod>: run bash -n on post-apply.sh and post-revert.sh
check_bash_syntax() {
    local mod="$1"
    local patches_src="$SRC_DIR/$mod/patches"
    [[ -d "$patches_src" ]] || return 0

    local ok=0 script f output
    for script in post-apply.sh post-revert.sh; do
        f="$patches_src/$script"
        [[ -f "$f" ]] || continue
        output="$(bash -n "$f" 2>&1)"
        if [[ $? -ne 0 ]]; then
            warn "bash -n FAILED: $f"
            echo "$output"
            ok=1
        fi
    done
    return $ok
}

# test_syntax_one_mod <mod>: run all syntax checks for one mod.
# Returns 0 on pass, 1 on any failure.
test_syntax_one_mod() {
    local mod="$1"
    echo "::group::Syntax check: $mod"
    local ok=0

    check_perl_syntax "$mod" || ok=1
    check_js_syntax   "$mod" || ok=1
    check_bash_syntax "$mod" || ok=1

    if [[ $ok -eq 0 ]]; then
        info "PASS: $mod"
    else
        warn "FAIL: $mod"
    fi
    echo "::endgroup::"
    return $ok
}

# ── main ──────────────────────────────────────────────────────────────────────
[[ $# -eq 1 ]] || { echo "Usage: $0 <mod>|all" >&2; exit 2; }

if ! command -v perl >/dev/null 2>&1; then
    warn "'perl' command not found; install perl."
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    warn "'node' command not found; install nodejs."
    exit 1
fi

targets=()
if [[ "$1" == "all" ]]; then
    mapfile -t targets < <(list_modules)
    [[ ${#targets[@]} -gt 0 ]] || { warn "no mods found in $SRC_DIR"; exit 1; }
else
    targets=("$1")
fi

failed=()
for mod in "${targets[@]}"; do
    test_syntax_one_mod "$mod" || failed+=("$mod")
done

echo ""
if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed mods: ${failed[*]}"
    exit 1
fi
info "All tested mods passed: ${targets[*]}"
exit 0
