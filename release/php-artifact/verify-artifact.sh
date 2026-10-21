#!/bin/sh
# Release gate for a PHP artifact image (see make-artifact.sh).
#
# Usage: release/php-artifact/verify-artifact.sh <artifact image> <loaded source image>
#
# Exits 0 only when:
# - the source image is the node-built image recorded in artifact.env and its
#   php and php-fpm report the fixed PHP version, every binary and extension
#   resolves its libraries, php-fpm -t passes, and a PHP page served by PHP's
#   web server parses a multipart upload;
# - the artifact holds exactly the source image's /usr/local tree (same files,
#   same sha256, same symlinks) plus /php-artifact, and its SHA256SUMS check;
# - the authenticated registry definitively reports the artifact tag absent.
set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

here=$(cd "$(dirname "$0")" && pwd)
release_dir=$(dirname "$here")
env_file="$here/artifact.env"
get() {
    value=$(sed -n "s/^$1=//p" "$env_file")
    [ -n "$value" ] || fail "artifact.env: missing $1"
    printf '%s' "$value"
}
artifact_ref=$(get artifact_ref)
php_version=$(get php_version)
source_image_id=$(get source_image_id)
known_ref=$(get registry_known_ref)

[ "$#" -eq 2 ] || fail "usage: $0 <artifact image> <source image>"
[ "$1" = "$artifact_ref" ] || fail "unexpected artifact reference $1 (expected $artifact_ref)"
source_image=$2
case "$source_image" in local/*:*) ;; *) fail "source image must be a local/ reference" ;; esac
for tool in docker curl jq sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' INT TERM

echo "== Registry: $artifact_ref must not exist"
registry=${artifact_ref%%/*}
repository_and_tag=${artifact_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
known_repository_and_ref=${known_ref#*/}
known_repository=${known_repository_and_ref%@*}
known_digest=${known_ref#*@}
registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS --max-time 60 -K - -o "$work_dir/registry-body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}
status=$(registry_get /v2/) || fail "registry unreachable"
[ "$status" = 200 ] || fail "registry API check returned HTTP $status"
status=$(registry_get "/v2/$known_repository/manifests/$known_digest") || fail "registry unreachable"
[ "$status" = 200 ] || fail "authenticated read of $known_ref returned HTTP $status; state is indeterminate"
status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$status" in
    200) fail "$artifact_ref already exists; refusing to replace it" ;;
    404)
        if grep -q 'MANIFEST_UNKNOWN' "$work_dir/registry-body"; then
            echo "$artifact_ref is definitively absent (MANIFEST_UNKNOWN)"
        elif grep -q 'NAME_UNKNOWN' "$work_dir/registry-body"; then
            echo "$artifact_ref is definitively absent (repository $repository does not exist yet: NAME_UNKNOWN)"
        else
            fail "registry returned 404 without MANIFEST_UNKNOWN/NAME_UNKNOWN: $(head -c 300 "$work_dir/registry-body")"
        fi
        ;;
    *) fail "registry returned HTTP $status for $artifact_ref" ;;
esac

echo "== Source image $source_image"
[ "$(docker image inspect --format '{{.Id}}' "$source_image")" = "$source_image_id" ] \
    || fail "$source_image is not the node-built image $source_image_id"
in_source() {
    docker run --rm --platform linux/amd64 --network none --user 0:0 \
        -v "$release_dir:/release:ro" --entrypoint sh "$source_image" "$@"
}
in_source -c 'php -v | head -n 1; php-fpm -v | head -n 1; php -r "echo PHP_VERSION, \"\\n\";"' > "$work_dir/version"
cat "$work_dir/version"
case "$(sed -n 1p "$work_dir/version")" in "PHP $php_version (cli)"*) ;; *) fail "php is not $php_version" ;; esac
case "$(sed -n 2p "$work_dir/version")" in "PHP $php_version (fpm-fcgi)"*) ;; *) fail "php-fpm is not $php_version" ;; esac
[ "$(sed -n 3p "$work_dir/version")" = "$php_version" ] || fail "PHP_VERSION is not $php_version"
in_source -c 'for f in /usr/local/bin/php /usr/local/sbin/php-fpm /usr/local/lib/php/extensions/*/*.so; do ldd "$f" 2>&1 | grep "not found" | sed "s|^|$f: |"; done' > "$work_dir/missing"
[ ! -s "$work_dir/missing" ] || { cat "$work_dir/missing" >&2; fail "unresolved libraries"; }
echo "php, php-fpm and the shared extensions resolve all libraries"
in_source -c 'php -m' > "$work_dir/modules"
for module in Core curl date dom fileinfo filter hash json libxml mbstring mysqlnd openssl pcre PDO pdo_sqlite readline Reflection session SimpleXML sodium SPL sqlite3 standard tokenizer xml zlib "Zend OPcache"; do
    grep -qx "$module" "$work_dir/modules" || fail "php -m lacks $module"
done
echo "php -m lists $(grep -c . "$work_dir/modules") lines including the docker-library default set"
in_source -c 'php-fpm -t 2>&1; echo "exit=$?"' > "$work_dir/fpm-test"
sed 's/^\[[^]]*\] //' "$work_dir/fpm-test"
grep -qx 'exit=0' "$work_dir/fpm-test" || fail "php-fpm -t failed"
in_source /release/multipart-smoke.sh php || fail "multipart smoke test failed"

echo "== Artifact contents"
[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$artifact_ref")" = linux/amd64 ] || fail "artifact is not linux/amd64"
mkdir "$work_dir/source" "$work_dir/artifact"
container_id=$(docker create --platform linux/amd64 --network none "$source_image" true)
docker export "$container_id" | tar -xp -C "$work_dir/source" usr/local
docker rm "$container_id" >/dev/null
container_id=$(docker create --platform linux/amd64 --network none "$artifact_ref" true)
docker export "$container_id" | tar -xp -C "$work_dir/artifact"
docker rm "$container_id" >/dev/null
listing() {
    (
        cd "$1"
        find usr/local \( -type f -o -type l \) -print | sort | while IFS= read -r path; do
            if [ -L "$path" ]; then
                echo "link $(readlink "$path") $path"
            else
                echo "file $(sha256sum < "$path" | cut -c1-64) $(stat -c %a "$path") $path"
            fi
        done
    )
}
listing "$work_dir/source" > "$work_dir/source.list"
listing "$work_dir/artifact" > "$work_dir/artifact.list"
diff -u "$work_dir/source.list" "$work_dir/artifact.list" > "$work_dir/list.diff" \
    || { head -40 "$work_dir/list.diff" >&2; fail "artifact /usr/local differs from the source image"; }
top=$(cd "$work_dir/artifact" && find . -mindepth 1 -maxdepth 1 ! -name usr ! -name php-artifact ! -name dev ! -name etc ! -name proc ! -name sys ! -name .dockerenv -print)
[ -z "$top" ] || fail "unexpected top-level entries in the artifact: $top"
other=$(cd "$work_dir/artifact" && find usr -mindepth 1 -maxdepth 1 ! -name local -print)
[ -z "$other" ] || fail "unexpected entries under /usr in the artifact: $other"
(cd "$work_dir/artifact" && sha256sum -c --quiet php-artifact/SHA256SUMS) || fail "php-artifact/SHA256SUMS does not match"
[ "$(wc -l < "$work_dir/artifact/php-artifact/SHA256SUMS")" -eq "$(grep -c '^file ' "$work_dir/artifact.list")" ] \
    || fail "php-artifact/SHA256SUMS does not cover every file"
echo "$(grep -c '^file ' "$work_dir/artifact.list") files and $(grep -c '^link ' "$work_dir/artifact.list") symlinks identical to the source image; SHA256SUMS verified"

echo "PASS: $artifact_ref"
