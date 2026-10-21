#!/bin/sh
# Release gate for an image built FROM the deployed digest with PHP copied in
# from a digest-pinned PHP image: an official php image, or a FROM-scratch
# PHP artifact (repo.cylo.net/php-artifacts, see release/php-artifact/). See
# the Dockerfile and release/image.env.
#
# Usage: release/verify-image.sh <image>
#
#   <image> is the release reference in release/image.env, or
#   local/<image>-trial:<tag> for a trial build.
#
# Exits 0 only when the local image passes every check and the authenticated
# registry definitively reports that the release tag does not exist yet. The
# registry check always targets the release tag, whatever image is tested.
# Any indeterminate registry answer fails.
#
# A trial run may expect another PHP version with GATE_TRIAL_PHP_VERSION
# (to prove the gate on today's unpatched release). That variable is refused
# for the release image.
set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

release_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(dirname "$release_dir")
for key in cylo_build_image cylo_build_release_ref cylo_build_dockerfile gate_base_ref \
    gate_php_release_version gate_php_image_pattern gate_php_extension_dir; do
    value=$(sed -n "s/^$key=//p" "$release_dir/image.env")
    case "$value" in ''|*[!A-Za-z0-9._/:@-]*) fail "release/image.env: bad or missing $key" ;; esac
    eval "$key=\$value"
done
gate_fpm_prepare=$(sed -n "s/^gate_fpm_prepare=//p" "$release_dir/image.env")
case "$gate_fpm_prepare" in ''|/*) ;; *) fail "release/image.env: gate_fpm_prepare must be an absolute path" ;; esac
case "$gate_fpm_prepare" in *[!A-Za-z0-9._/-]*) fail "release/image.env: bad gate_fpm_prepare" ;; esac
gate_web_prepare=$(sed -n "s/^gate_web_prepare=//p" "$release_dir/image.env")
case "$gate_web_prepare" in ''|/*) ;; *) fail "release/image.env: gate_web_prepare must be an absolute path" ;; esac
case "$gate_web_prepare" in *[!A-Za-z0-9._/-]*) fail "release/image.env: bad gate_web_prepare" ;; esac

[ "$#" -eq 1 ] || fail "usage: $0 <image>"
image_ref=$1
trial_prefix="local/$cylo_build_image-trial:"
case "$image_ref" in
    "$cylo_build_release_ref") gate_mode=release ;;
    "$trial_prefix"*)
        case "${image_ref#"$trial_prefix"}" in
            ''|*[!A-Za-z0-9._-]*) fail "invalid trial tag: $image_ref" ;;
        esac
        gate_mode=trial
        ;;
    *) fail "unexpected image reference: $image_ref (expected $cylo_build_release_ref or $trial_prefix<tag>)" ;;
esac

expected_php=$gate_php_release_version
if [ -n "${GATE_TRIAL_PHP_VERSION:-}" ]; then
    [ "$gate_mode" = trial ] || fail "refusing GATE_TRIAL_PHP_VERSION for $image_ref"
    case "$GATE_TRIAL_PHP_VERSION" in
        *[!0-9.]*|.*|*.) fail "invalid GATE_TRIAL_PHP_VERSION" ;;
    esac
    expected_php=$GATE_TRIAL_PHP_VERSION
    echo "TRIAL: expecting PHP $expected_php instead of $gate_php_release_version; this run cannot approve a release"
fi

for tool in docker curl jq diff sort comm awk tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' INT TERM

in_image_as() {
    gate_image=$1
    gate_entrypoint=$2
    shift 2
    docker run --rm --platform linux/amd64 --network none --user 0:0 \
        -v "$release_dir:/release:ro" --entrypoint "$gate_entrypoint" "$gate_image" "$@"
}

echo "== Gate: $image_ref ($gate_mode)"

echo "== Registry: $cylo_build_release_ref must not exist"
registry=${cylo_build_release_ref%%/*}
repository_and_tag=${cylo_build_release_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || fail "release reference has no tag"
base_digest=${gate_base_ref#*@}
registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS --max-time 60 -K - -o "$work_dir/registry-body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}
api_status=$(registry_get /v2/) || fail "registry unreachable"
[ "$api_status" = 200 ] || fail "registry API check returned HTTP $api_status"
known_status=$(registry_get "/v2/$repository/manifests/$base_digest") || fail "registry unreachable"
[ "$known_status" = 200 ] || fail "registry read of the deployed digest returned HTTP $known_status; state is indeterminate"
manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$manifest_status" in
    200) fail "$cylo_build_release_ref already exists in the registry; refusing to replace it" ;;
    404)
        grep -q 'MANIFEST_UNKNOWN' "$work_dir/registry-body" \
            || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$work_dir/registry-body")"
        echo "deployed digest readable; $cylo_build_release_ref is definitively absent (MANIFEST_UNKNOWN)"
        ;;
    *) fail "registry returned HTTP $manifest_status for $cylo_build_release_ref" ;;
esac

echo "== Image identity"
docker image inspect "$image_ref" >/dev/null 2>&1 || fail "$image_ref is not a local image"
docker image inspect "$gate_base_ref" >/dev/null 2>&1 \
    || docker pull -q --platform linux/amd64 "$gate_base_ref" >/dev/null \
    || fail "cannot read the deployed image $gate_base_ref"
[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")" = linux/amd64 ] \
    || fail "image is not linux/amd64"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$gate_base_ref" | sed '/^$/d' > "$work_dir/base-layers"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" | sed '/^$/d' > "$work_dir/image-layers"
base_layer_count=$(wc -l < "$work_dir/base-layers")
image_layer_count=$(wc -l < "$work_dir/image-layers")
head -n "$base_layer_count" "$work_dir/image-layers" | cmp -s - "$work_dir/base-layers" \
    || fail "the deployed image's layers are not the start of the new image"
echo "deployed layers ($base_layer_count) unchanged; $((image_layer_count - base_layer_count)) PHP layers on top"
for field in '{{json .Config.Entrypoint}}' '{{json .Config.Cmd}}' '{{json .Config.User}}' \
    '{{json .Config.WorkingDir}}' '{{json .Config.ExposedPorts}}' '{{json .Config.Volumes}}' \
    '{{json .Config.Healthcheck}}' '{{json .Config.StopSignal}}' '{{json .Config.Shell}}'; do
    [ "$(docker image inspect --format "$field" "$image_ref")" = "$(docker image inspect --format "$field" "$gate_base_ref")" ] \
        || fail "image config $field differs from the deployed image"
done
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$gate_base_ref" | sed '/^$/d' \
    | sed "s/^PHP_VERSION=.*/PHP_VERSION=$expected_php/" | sort > "$work_dir/expected-env"
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image_ref" | sed '/^$/d' | sort > "$work_dir/image-env"
if ! diff -u "$work_dir/expected-env" "$work_dir/image-env" > "$work_dir/env-diff"; then
    sed 's/=.*/=<value hidden>/' "$work_dir/env-diff" >&2
    fail "environment differs from the deployed image other than PHP_VERSION=$expected_php"
fi
docker image inspect --format '{{json .Config.Labels}}' "$gate_base_ref" | jq -S 'del(.["org.appbox.php-source"])' > "$work_dir/base-labels"
docker image inspect --format '{{json .Config.Labels}}' "$image_ref" | jq -S 'del(.["org.appbox.php-source"])' > "$work_dir/image-labels"
diff -u "$work_dir/base-labels" "$work_dir/image-labels" || fail "labels differ from the deployed image"
echo "entrypoint, command, user, ports, volumes, labels and environment unchanged except PHP_VERSION"

echo "== PHP source image"
php_source=$(docker image inspect --format '{{index .Config.Labels "org.appbox.php-source"}}' "$image_ref")
case "$php_source" in
    php:*@sha256:*|repo.cylo.net/php-artifacts:*@sha256:*) ;;
    *) fail "org.appbox.php-source label '$php_source' is not a digest-pinned PHP image or artifact" ;;
esac
php_source_digest=${php_source#*@sha256:}
case "$php_source_digest" in
    *[!0-9a-f]*) fail "bad digest in $php_source" ;;
esac
[ "${#php_source_digest}" -eq 64 ] || fail "bad digest in $php_source"
if [ "$gate_mode" = release ]; then
    [ "${php_source%@*}" = "$gate_php_image_pattern" ] \
        || fail "PHP source $php_source is not $gate_php_image_pattern"
    dockerfile_pin=$(sed -n 's/^ARG PHP_IMAGE=//p' "$repo_dir/$cylo_build_dockerfile")
    [ "$dockerfile_pin" = "$php_source" ] \
        || fail "image was built from $php_source, but $cylo_build_dockerfile pins '$dockerfile_pin'"
fi
docker image inspect "$php_source" >/dev/null 2>&1 \
    || docker pull -q --platform linux/amd64 "$php_source" >/dev/null \
    || fail "cannot read the PHP source image $php_source"
echo "PHP copied from $php_source"

echo "== Reports (deployed, source, new)"
in_image_as "$gate_base_ref" sh /release/in-image-report.sh "$gate_php_extension_dir" "$gate_fpm_prepare" "$gate_web_prepare" > "$work_dir/base.report" 2>&1 \
    || fail "report failed in the deployed image"
# The source may be a FROM-scratch artifact with no shell, so its file list
# is read from an export on the host, in the same format as in-image-report.
mkdir "$work_dir/source-root"
source_container=$(docker create --platform linux/amd64 --network none "$php_source" true)
docker export "$source_container" | tar -xp -C "$work_dir/source-root" usr/local \
    || { docker rm "$source_container" >/dev/null; fail "cannot export the PHP source image"; }
docker rm "$source_container" >/dev/null
{
    echo "@@ files"
    (
        cd "$work_dir/source-root"
        for path in usr/local/bin/php usr/local/bin/php-config usr/local/bin/phpize \
            usr/local/sbin/php-fpm usr/local/include/php usr/local/lib/php/build "${gate_php_extension_dir#/}"; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            find "$path" \( -type f -o -type l \) -print
        done | sort | while IFS= read -r path; do
            if [ -L "$path" ]; then
                echo "link $(readlink "$path") /$path"
            else
                echo "file $(sha256sum < "$path" | cut -c1-64) /$path"
            fi
        done
    )
    echo "@@ end"
} > "$work_dir/source.report"
in_image_as "$image_ref" sh /release/in-image-report.sh "$gate_php_extension_dir" "$gate_fpm_prepare" "$gate_web_prepare" > "$work_dir/image.report" 2>&1 \
    || fail "report failed in the new image"
section() {
    awk -v want="@@ $1" '$0 == want {on = 1; next} /^@@ / {on = 0} on' "$work_dir/$2.report"
}

echo "== PHP version"
section version image | tee "$work_dir/image.version"
case "$(sed -n 1p "$work_dir/image.version")" in
    "PHP $expected_php (cli)"*) ;;
    *) fail "php does not report PHP $expected_php" ;;
esac
case "$(sed -n 2p "$work_dir/image.version")" in
    "PHP $expected_php (fpm-fcgi)"*) ;;
    *) fail "php-fpm does not report PHP $expected_php" ;;
esac
[ "$(sed -n 3p "$work_dir/image.version")" = "$expected_php" ] || fail "PHP_VERSION constant is not $expected_php"
echo "deployed image: $(section version base | sed -n 1p)"

echo "== Shared libraries"
section missing-libraries image > "$work_dir/missing"
if [ -s "$work_dir/missing" ]; then
    cat "$work_dir/missing" >&2
    fail "the new PHP binaries or extensions have unresolved libraries"
fi
echo "php, php-fpm and every extension resolve all libraries"

echo "== Modules"
section modules-cli base > "$work_dir/base.cli-modules"
section modules-cli image > "$work_dir/image.cli-modules"
diff -u "$work_dir/base.cli-modules" "$work_dir/image.cli-modules" || fail "php -m differs from the deployed image"
section modules-fpm base > "$work_dir/base.fpm-modules"
section modules-fpm image > "$work_dir/image.fpm-modules"
diff -u "$work_dir/base.fpm-modules" "$work_dir/image.fpm-modules" || fail "php-fpm -m differs from the deployed image"
echo "$(grep -c . "$work_dir/image.fpm-modules") lines of php-fpm -m output identical to the deployed image"

echo "== FPM configuration"
section fpm-test image
section fpm-test image | grep -qx 'exit=0' || fail "php-fpm -t failed with the deployed configuration"
section fpm-test base | grep -qx 'exit=0' || fail "php-fpm -t fails in the deployed image too; fix gate_fpm_prepare"

echo "== Web server configuration"
for server in nginx apache; do
    section "$server-test" base > "$work_dir/base.$server"
    section "$server-test" image > "$work_dir/image.$server"
    if grep -qx 'absent' "$work_dir/base.$server"; then
        grep -qx 'absent' "$work_dir/image.$server" || fail "$server appeared in the new image"
        echo "$server: not installed in the deployed image"
        continue
    fi
    cat "$work_dir/image.$server"
    grep -qx 'exit=0' "$work_dir/image.$server" || fail "$server configuration test failed in the new image"
    grep -qx 'exit=0' "$work_dir/base.$server" || fail "$server configuration test fails in the deployed image too; fix gate_web_prepare"
done

echo "== Files"
section files source | sort > "$work_dir/source.files"
section files image | sort > "$work_dir/image.files"
section files base | sort > "$work_dir/base.files"
[ -s "$work_dir/source.files" ] || fail "no PHP files found in the source image"
grep -q " /usr/local/sbin/php-fpm\$" "$work_dir/source.files" || fail "source image has no php-fpm"
missing=$(comm -23 "$work_dir/source.files" "$work_dir/image.files")
if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | head -20 >&2
    fail "files from the PHP source image are missing or different in the new image"
fi
awk '{print $NF}' "$work_dir/source.files" > "$work_dir/source.paths"
awk 'NR == FNR {skip[$1]; next} !($NF in skip)' "$work_dir/source.paths" "$work_dir/image.files" > "$work_dir/image.other"
awk 'NR == FNR {skip[$1]; next} !($NF in skip)' "$work_dir/source.paths" "$work_dir/base.files" > "$work_dir/base.other"
diff -u "$work_dir/base.other" "$work_dir/image.other" \
    || fail "files that do not come from the PHP source image differ from the deployed image"
echo "$(wc -l < "$work_dir/source.files") files identical to $php_source; $(wc -l < "$work_dir/image.other") other PHP files identical to the deployed image"

echo "== Multipart upload"
in_image_as "$image_ref" sh /release/multipart-smoke.sh php || fail "multipart upload smoke test failed"

echo "== PHP page through nginx and php-fpm"
in_image_as "$image_ref" sh /release/fpm-nginx-smoke.sh "$expected_php" \
    || fail "nginx -> php-fpm page or multipart upload failed"

echo "== Regression checks"
for check in "$release_dir"/regression/*.sh; do
    [ -e "$check" ] || continue
    echo "-- $(basename "$check")"
    in_image_as "$image_ref" sh "/release/regression/$(basename "$check")" \
        || fail "regression check $(basename "$check") failed"
done

echo "PASS ($gate_mode): $image_ref"
