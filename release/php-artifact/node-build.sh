#!/bin/sh
# Runs on the Cylo node inside the mktemp build directory given as $1.
# Builds the unmodified docker-library/php Dockerfiles (FROM pinned by digest)
# with the legacy builder so every RUN container gets --cpu-shares 256, then
# saves each image as a gzip'd docker archive in $1/out.
set -u
d=$1
case "$d" in /root/php-builds/azuracast-seat.??????) ;; *) echo "bad dir $d"; exit 1 ;; esac
cd "$d" || exit 1
suffix=$(basename "$d" | sed 's/^azuracast-seat\.//' | tr 'A-Z' 'a-z')
mkdir -p out
build_one() {
    name=$1
    tag="local/azuracast-seat-selfbuild-$suffix:$name"
    echo "$tag" > "out/$name.tag"
    start=$(date -u +%FT%TZ)
    if DOCKER_BUILDKIT=0 docker build --cpu-shares 256 --network bridge_1 --force-rm --rm -t "$tag" "ctx/$name" > "out/$name.build.log" 2>&1 \
        && docker image inspect "$tag" > "out/$name.inspect.json" \
        && docker save "$tag" | gzip -1 > "out/$name.image.tar.gz" \
        && (cd out && sha256sum "$name.image.tar.gz" > "$name.image.tar.gz.sha256"); then
        echo "ok $start $(date -u +%FT%TZ)" > "out/$name.status"
    else
        echo "failed $start $(date -u +%FT%TZ)" > "out/$name.status"
    fi
}
build_one php-8.5.12-fpm-trixie &
build_one php-8.2.35-fpm-bookworm &
wait
echo done > out/all.done
