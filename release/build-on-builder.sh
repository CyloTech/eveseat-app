#!/usr/bin/env bash
# Build this branch's image on the dedicated builder from the pushed commit,
# following the staged flow in app-fixes-and-builds.md, and run the release
# gate. Run it on the operator's Mac from a clean checkout of the branch named
# in release/image.env.
#
# For cylo_build_kind=official-php (PHP copied from an official PHP image):
#   build-on-builder.sh pin <php-tag>     e.g. pin 8.5.12-fpm-trixie
#       Resolve php:<php-tag> on the builder and set the Dockerfile's
#       PHP_IMAGE default to php:<php-tag>@<index digest>. Does not commit.
#   build-on-builder.sh trial <php-tag>   e.g. trial 8.5.11-fpm-trixie
#       Build local/<image>-trial:<tag> with that PHP image, gate it against
#       the real release tag. Never pushes.
#
# For cylo_build_kind=apt (distribution PHP packages upgraded in place):
#   build-on-builder.sh pin <version>     e.g. pin 8.2.35-1~deb12u1
#       Set the Dockerfile's PHP_FIXED_VERSION default. Does not commit.
#   build-on-builder.sh trial <version>
#       Build local/<image>-trial:<tag> with PHP_FIXED_VERSION=<version>,
#       gate it against the real release tag. Never pushes.
#
#   build-on-builder.sh release
#       Build the release reference from the committed pins, run the gate,
#       push, and print the pushed digest.
set -euo pipefail

builder_host=appbox@builder.grant.appboxes.co
builder_ssh=(ssh -p 12246 -i /Users/rid/.ssh/appbox_ubuntuvps2_webtop
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
    -o StrictHostKeyChecking=yes)
builder_scp=(scp -P 12246 -i /Users/rid/.ssh/appbox_ubuntuvps2_webtop
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
    -o StrictHostKeyChecking=yes)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

repo_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$repo_root"
image_env() {
    local value
    value=$(sed -n "s/^$1=//p" release/image.env)
    case "$value" in ''|*[!A-Za-z0-9._/:@~+-]*) die "release/image.env: bad or missing $1" ;; esac
    printf '%s' "$value"
}
cylo_build_kind=$(image_env cylo_build_kind)
cylo_build_repo_slug=$(image_env cylo_build_repo_slug)
cylo_build_image=$(image_env cylo_build_image)
cylo_build_tag=$(image_env cylo_build_tag)
cylo_build_release_ref=$(image_env cylo_build_release_ref)
cylo_build_dockerfile=$(image_env cylo_build_dockerfile)
cylo_build_git_remote=$(image_env cylo_build_git_remote)
cylo_build_git_branch=$(image_env cylo_build_git_branch)
case "$cylo_build_repo_slug" in *[!A-Za-z0-9._-]*) die "bad slug" ;; esac
case "$cylo_build_image" in *[!a-z0-9._-]*) die "bad image name" ;; esac
case "$cylo_build_tag" in *[!A-Za-z0-9._-]*) die "bad tag" ;; esac
[ "$cylo_build_release_ref" = "repo.cylo.net/$cylo_build_image:$cylo_build_tag" ] || die "bad release ref"
case "$cylo_build_dockerfile" in /*|*..*|*[!A-Za-z0-9._/-]*) die "bad Dockerfile path" ;; esac
test -f "$cylo_build_dockerfile" || die "$cylo_build_dockerfile is missing"
test -x release/verify-image.sh || die "release/verify-image.sh is not executable"

dockerfile_arg() {
    sed -n "s/^ARG $1=//p" "$cylo_build_dockerfile"
}

mode=${1:-}
build_args=
gate_env=
case "$cylo_build_kind:$mode" in
    official-php:pin)
        php_tag=${2:-}
        case "$php_tag" in ''|*[!A-Za-z0-9._-]*) die "usage: $0 pin <php-tag>" ;; esac
        php_version=$(dockerfile_arg PHP_VERSION)
        case "$php_tag" in "$php_version"-*) ;; *) die "php:$php_tag does not match ARG PHP_VERSION=$php_version" ;; esac
        manifest=$("${builder_ssh[@]}" "$builder_host" \
            "docker buildx imagetools inspect --format '{{json .Manifest}}' 'docker.io/library/php:$php_tag'") \
            || die "php:$php_tag is not available on Docker Hub yet"
        digest=$(jq -r '.digest' <<< "$manifest")
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not read the index digest of php:$php_tag"
        jq -e '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")] | length == 1' \
            <<< "$manifest" > /dev/null || die "php:$php_tag has no single linux/amd64 manifest"
        sed -i.pin-bak "s|^ARG PHP_IMAGE=.*|ARG PHP_IMAGE=php:$php_tag@$digest|" "$cylo_build_dockerfile"
        rm -f "$cylo_build_dockerfile.pin-bak"
        git --no-pager diff -- "$cylo_build_dockerfile"
        exit 0
        ;;
    apt:pin)
        fixed_version=${2:-}
        case "$fixed_version" in ''|*[!A-Za-z0-9.+~-]*) die "usage: $0 pin <package version>" ;; esac
        sed -i.pin-bak "s|^ARG PHP_FIXED_VERSION=.*|ARG PHP_FIXED_VERSION=$fixed_version|" "$cylo_build_dockerfile"
        rm -f "$cylo_build_dockerfile.pin-bak"
        git --no-pager diff -- "$cylo_build_dockerfile"
        exit 0
        ;;
    official-php:trial)
        php_tag=${2:-}
        case "$php_tag" in ''|*[!A-Za-z0-9._-]*) die "usage: $0 trial <php-tag>" ;; esac
        trial_php_version=${php_tag%%-*}
        case "$trial_php_version" in ''|*[!0-9.]*) die "cannot read a PHP version from $php_tag" ;; esac
        manifest=$("${builder_ssh[@]}" "$builder_host" \
            "docker buildx imagetools inspect --format '{{json .Manifest}}' 'docker.io/library/php:$php_tag'") \
            || die "cannot resolve php:$php_tag"
        digest=$(jq -r '.digest' <<< "$manifest")
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not read the index digest of php:$php_tag"
        build_args="--build-arg PHP_VERSION=$trial_php_version --build-arg PHP_IMAGE=php:$php_tag@$digest"
        gate_env="GATE_TRIAL_PHP_VERSION=$trial_php_version"
        build_ref="local/$cylo_build_image-trial:$cylo_build_tag"
        remote_suffix="$cylo_build_tag-trial"
        ;;
    apt:trial)
        fixed_version=${2:-}
        case "$fixed_version" in ''|*[!A-Za-z0-9.+~-]*) die "usage: $0 trial <package version>" ;; esac
        build_args="--build-arg PHP_FIXED_VERSION=$fixed_version"
        gate_env="GATE_TRIAL_PHP_MIN_VERSION=$fixed_version"
        build_ref="local/$cylo_build_image-trial:$cylo_build_tag"
        remote_suffix="$cylo_build_tag-trial"
        ;;
    official-php:release)
        [[ "$(dockerfile_arg PHP_IMAGE)" =~ ^php:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] \
            || die "PHP_IMAGE is not pinned by digest; run: $0 pin <php-tag>"
        build_ref=$cylo_build_release_ref
        remote_suffix=$cylo_build_tag
        ;;
    apt:release)
        [[ "$(dockerfile_arg PHP_FIXED_VERSION)" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]] \
            || die "PHP_FIXED_VERSION is not set; run: $0 pin <package version>"
        build_ref=$cylo_build_release_ref
        remote_suffix=$cylo_build_tag
        ;;
    *) die "usage: $0 pin <arg> | trial <arg> | release" ;;
esac

# Build only a clean, pushed commit.
[ -z "$(git status --porcelain)" ] || die "the worktree has uncommitted changes"
git fetch -q "$cylo_build_git_remote" "$cylo_build_git_branch"
cylo_build_commit=$(git rev-parse HEAD)
[ "$(git rev-parse FETCH_HEAD)" = "$cylo_build_commit" ] \
    || die "HEAD $cylo_build_commit is not the pushed $cylo_build_git_remote/$cylo_build_git_branch"
echo "commit $cylo_build_commit"
grep -E '^ARG (PHP_VERSION|PHP_IMAGE|PHP_FIXED_VERSION)=' "$cylo_build_dockerfile" || true

stage_root=${CYLO_BUILD_TMP:-/private/tmp}
cylo_build_stage=$(mktemp -d "$stage_root/cylo-app-build.XXXXXX")
cylo_build_remote_dir=
cleanup() {
    case "$cylo_build_stage" in
        "$stage_root"/cylo-app-build.??????) rm -rf "$cylo_build_stage" ;;
    esac
    case "$cylo_build_remote_dir" in
        "/home/appbox/builds/$cylo_build_repo_slug.$remote_suffix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
            "${builder_ssh[@]}" "$builder_host" "rm -rf '$cylo_build_remote_dir'" \
                || echo "WARNING: remove $cylo_build_remote_dir on the builder by hand" >&2
            ;;
    esac
}
trap cleanup EXIT

cylo_build_archive="$cylo_build_stage/context.tgz"
git archive --format=tar.gz --output="$cylo_build_archive" "$cylo_build_commit"
echo "== archive members"
tar -tzf "$cylo_build_archive"
cylo_build_sha=$(shasum -a 256 "$cylo_build_archive" | awk '{print $1}')
echo "archive sha256 $cylo_build_sha"

remote_prefix="/home/appbox/builds/$cylo_build_repo_slug.$remote_suffix"
cylo_build_remote_dir=$("${builder_ssh[@]}" "$builder_host" "mktemp -d '$remote_prefix.XXXXXX'")
case "$cylo_build_remote_dir" in
    "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]) ;;
    *) cylo_build_remote_dir=; die "unexpected remote directory" ;;
esac
echo "builder directory $cylo_build_remote_dir"

"${builder_scp[@]}" "$cylo_build_archive" "$builder_host:$cylo_build_remote_dir/context.tgz"
"${builder_ssh[@]}" "$builder_host" "cd '$cylo_build_remote_dir' && \
    printf '%s  context.tgz\n' '$cylo_build_sha' | sha256sum -c - && \
    mkdir context && tar xzf context.tgz -C context"

echo "== build $build_ref"
"${builder_ssh[@]}" "$builder_host" "cd '$cylo_build_remote_dir/context' && \
    { docker build --progress=plain --platform linux/amd64 -f '$cylo_build_dockerfile' $build_args \
        -t '$build_ref' . > ../build.log 2>&1 \
      || { tail -n 150 ../build.log; exit 1; }; } && \
    tail -n 30 ../build.log"

if [ "$mode" = trial ]; then
    echo "== gate (trial, no push)"
    "${builder_ssh[@]}" "$builder_host" "cd '$cylo_build_remote_dir/context' && \
        env $gate_env ./release/verify-image.sh '$build_ref'"
    echo "TRIAL PASSED: $build_ref from $cylo_build_commit (not pushed)"
    exit 0
fi

echo "== gate, push"
"${builder_ssh[@]}" "$builder_host" "cd '$cylo_build_remote_dir/context' && \
    ./release/verify-image.sh '$build_ref' && \
    docker push '$build_ref' && \
    docker buildx imagetools inspect '$build_ref' | head -n 3"
echo "RELEASED $build_ref from $cylo_build_commit"
