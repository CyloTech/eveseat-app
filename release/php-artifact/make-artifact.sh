#!/bin/sh
# Turn a self-built PHP image (docker-library/php recipe, built on a Cylo
# node by release/php-artifact/node-build.sh and loaded on the builder) into
# the reusable artifact image described by release/php-artifact/artifact.env:
# FROM scratch, holding the image's whole /usr/local tree at its real paths,
# plus /php-artifact/ with a README, SHA256SUMS, SYMLINKS, the Dockerfile the
# image was built from, the runtime Debian packages it needs and php -v/-m.
#
# Usage: release/php-artifact/make-artifact.sh <loaded source image> <new output dir>
#
# Release images then COPY --from the artifact pinned by digest.
set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

here=$(cd "$(dirname "$0")" && pwd)
env_file="$here/artifact.env"
get() {
    value=$(sed -n "s/^$1=//p" "$env_file")
    [ -n "$value" ] || fail "artifact.env: missing $1"
    printf '%s' "$value"
}
artifact_name=$(get artifact_name)
artifact_ref=$(get artifact_ref)
php_version=$(get php_version)
source_image_id=$(get source_image_id)
source_rootfs_layers_sha256=$(get source_rootfs_layers_sha256)
source_image_created=$(get source_image_created)
docker_library_commit=$(get docker_library_commit)
docker_library_path=$(get docker_library_path)
base_image=$(get base_image)
php_tarball_url=$(get php_tarball_url)
php_tarball_sha256=$(get php_tarball_sha256)
php_signing_key=$(get php_signing_key)
build_host=$(get build_host)
build_method=$(get build_method)
build_started=$(get build_started)
build_finished=$(get build_finished)
image_archive_sha256=$(get image_archive_sha256)
dockerfile_sha256=$(get dockerfile_sha256)

case "$artifact_name" in *[!a-z0-9._-]*) fail "bad artifact_name" ;; esac
[ "$artifact_ref" = "repo.cylo.net/php-artifacts:$artifact_name" ] || fail "artifact_ref does not match artifact_name"

[ "$#" -eq 2 ] || fail "usage: $0 <source image> <new output dir>"
source_image=$1
out_dir=$2
case "$source_image" in local/*:*) ;; *) fail "source image must be a local/ reference" ;; esac
case "$source_image" in *[!A-Za-z0-9._/:-]*) fail "bad source image reference" ;; esac
[ ! -e "$out_dir" ] || fail "$out_dir already exists"

# Image IDs differ between image stores (config digest on the node's classic
# store, manifest digest on a containerd store), so the loaded image is
# identified by its layer diff IDs and creation time as recorded on the node.
[ "$(docker image inspect --format '{{json .RootFS.Layers}}' "$source_image" | sha256sum | cut -c1-64)" = "$source_rootfs_layers_sha256" ] \
    || fail "$source_image does not have the layers of the node-built image $source_image_id"
[ "$(docker image inspect --format '{{.Created}}' "$source_image")" = "$source_image_created" ] \
    || fail "$source_image was not created at $source_image_created like the node-built image"
[ "$(sha256sum < "$here/docker-library/Dockerfile" | cut -c1-64)" = "$dockerfile_sha256" ] \
    || fail "docker-library/Dockerfile is not the file the image was built from"

mkdir -p "$out_dir/rootfs/php-artifact"
out_dir=$(cd "$out_dir" && pwd)
container_id=$(docker create --platform linux/amd64 --network none "$source_image" true)
docker export "$container_id" | tar -xp -C "$out_dir/rootfs" usr/local
docker rm "$container_id" >/dev/null
[ -x "$out_dir/rootfs/usr/local/bin/php" ] || fail "export has no usr/local/bin/php"
[ -x "$out_dir/rootfs/usr/local/sbin/php-fpm" ] || fail "export has no usr/local/sbin/php-fpm"

meta="$out_dir/rootfs/php-artifact"
(
    cd "$out_dir/rootfs"
    find usr/local -type f -print0 | sort -z | xargs -0 sha256sum
) > "$meta/SHA256SUMS"
(
    cd "$out_dir/rootfs"
    find usr/local -type l | sort | while IFS= read -r link; do
        printf '%s -> %s\n' "$link" "$(readlink "$link")"
    done
) > "$meta/SYMLINKS"
docker run --rm --network none --entrypoint sh "$source_image" -c \
    'apt-mark showmanual | sort | xargs dpkg-query -W -f "\${Package} \${Version}\n"' > "$meta/runtime-packages.txt"
docker run --rm --network none --entrypoint sh "$source_image" -c \
    'cat /etc/os-release | grep -E "^(PRETTY_NAME|VERSION_ID)="; php -v; echo; php -m; echo; php -i | grep -E "^(Build Provider|PHP API|PHP Extension|Zend Extension|Configure Command) "' \
    > "$meta/php-info.txt"
cp "$here/docker-library/Dockerfile" "$meta/Dockerfile"
file_count=$(wc -l < "$meta/SHA256SUMS")
link_count=$(wc -l < "$meta/SYMLINKS")

cat > "$meta/README.md" <<README
# $artifact_ref

PHP $php_version built from the unmodified docker-library/php recipe
(the recipe behind the Docker Official \`php\` images), packaged as a
FROM-scratch artifact so Appbox images can copy PHP in from a pinned digest
instead of waiting for Docker Hub.

Contents:

- \`/usr/local/\`: the complete /usr/local tree of the built image (php,
  php-fpm, php-config, phpize, headers, build files, shared extensions,
  default ini and FPM configuration, PEAR, docker-php-* helpers).
  $file_count files and $link_count symlinks.
- \`/php-artifact/SHA256SUMS\`: sha256 of every file under /usr/local.
- \`/php-artifact/SYMLINKS\`: every symlink under /usr/local and its target.
- \`/php-artifact/Dockerfile\`: the exact Dockerfile that was built.
- \`/php-artifact/runtime-packages.txt\`: the Debian packages the build
  kept as runtime dependencies (the shared libraries PHP links against).
- \`/php-artifact/php-info.txt\`: OS release, php -v, php -m and build facts.

Provenance:

| | |
|---|---|
| Recipe | https://github.com/docker-library/php commit $docker_library_commit, \`$docker_library_path\` |
| Only change to the recipe | \`FROM\` pinned to \`$base_image\` |
| Dockerfile sha256 | $dockerfile_sha256 |
| PHP source | $php_tarball_url |
| PHP source sha256 | $php_tarball_sha256 (checked by the recipe, matches php.net) |
| PHP source signature | verified by the recipe with gpg, key $php_signing_key |
| Built on | $build_host, $build_method |
| Built | $build_started to $build_finished |
| Built image ID (config digest) | $source_image_id |
| Built image layers (sha256 of RootFS.Layers JSON) | $source_rootfs_layers_sha256 |
| Image archive sha256 | $image_archive_sha256 (verified on the node and on the builder) |

Use it from a Dockerfile, pinned by digest, for example:

    FROM $artifact_ref@sha256:<digest> AS php-artifact
    COPY --from=php-artifact /usr/local/sbin/php-fpm /usr/local/sbin/

The target image must provide the runtime libraries in runtime-packages.txt
(any image based on the matching official php image already does).
README

cat > "$out_dir/Dockerfile.artifact" <<DOCKERFILE
FROM scratch
COPY rootfs/ /
LABEL org.appbox.php-artifact.name="$artifact_name" \\
      org.appbox.php-artifact.php-version="$php_version" \\
      org.appbox.php-artifact.recipe="docker-library/php@$docker_library_commit:$docker_library_path" \\
      org.appbox.php-artifact.base-image="$base_image" \\
      org.appbox.php-artifact.source-image-id="$source_image_id"
DOCKERFILE
echo "artifact context ready in $out_dir ($file_count files, $link_count symlinks)"
