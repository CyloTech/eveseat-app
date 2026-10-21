# Releasing eveseat 5.0.1-3

The image is the deployed 5.0.1-2 digest with PHP's own files copied in from
the official `php:8.2.35-fpm-bookworm` image (see Dockerfile.release).

## 1. Is the patched PHP available?

Docker Hub must have `php:8.2.35-fpm-bookworm`. Either of these answers it:

    docker buildx imagetools inspect docker.io/library/php:8.2.35-fpm-bookworm   # on the builder
    release/build-on-builder.sh pin 8.2.35-fpm-bookworm                           # fails with "not available on Docker Hub yet"

## 2-5. Pin, build, gate, push

From a clean checkout of branch `php-multipart-fix` on the Mac:

    git pull --ff-only origin php-multipart-fix
    release/build-on-builder.sh pin 8.2.35-fpm-bookworm
    git commit -am "Pin php:8.2.35-fpm-bookworm by digest"
    git push origin php-multipart-fix
    release/build-on-builder.sh release

`release` builds `repo.cylo.net/eveseat:5.0.1-3` on the builder from the
pushed commit, runs `release/verify-image.sh` and pushes only if the gate
passes, then prints the pushed digest.

A trial (never pushed) is `release/build-on-builder.sh trial 8.2.34-fpm-bookworm`.
