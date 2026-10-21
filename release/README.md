# Releasing eveseat 5.0.1-3

The image is the deployed 5.0.1-2 digest with PHP's own files copied in from
`repo.cylo.net/php-artifacts:docker-library-php-8.2.35-fpm-bookworm` (see `Dockerfile.release`).

## 1. The patched PHP

On 21 October 2026 Docker Hub's `php:8.2.35-fpm-bookworm` tag was an empty image index
(no linux/amd64 image), so PHP 8.2.35 was built here instead, from the
unmodified docker-library/php `8.2/bookworm/fpm` recipe with `FROM` pinned by digest:

1. `release/php-artifact/node-build.sh` built `release/php-artifact/docker-library/`
   on a low-load Cylo node (legacy builder, `--cpu-shares 256`), saved the
   image as a gzip'd docker archive and recorded its sha256.
2. The archive was copied node -> builder with `scp -3` and its sha256 was
   checked again on the builder before `docker load`.
3. `release/php-artifact/make-artifact.sh` turned the loaded image into a
   FROM-scratch artifact (the whole /usr/local tree plus /php-artifact/
   README, SHA256SUMS, SYMLINKS, Dockerfile, runtime packages, php -v/-m).
4. `release/php-artifact/verify-artifact.sh` gated it (PHP version, libraries,
   php-fpm -t, multipart upload, artifact contents identical to the image,
   tag absent) and it was pushed, then pinned by digest in `Dockerfile.release`.

`release/php-artifact/artifact.env` records the provenance (recipe commit,
base digest, PHP tarball sha256 and signing key, node, image ID, archive
sha256).

## 2. Build, gate, push

From a clean checkout of branch `php-multipart-fix` on the Mac:

    git pull --ff-only origin php-multipart-fix
    CYLO_BUILD_TMP=<scratch dir> release/build-on-builder.sh release

`release` builds `repo.cylo.net/eveseat:5.0.1-3` on builder1 from the pushed
commit, runs `release/verify-image.sh` and pushes only if the gate passes,
then prints the pushed digest. The gate checks the deployed layers and image
config are unchanged apart from PHP_VERSION and the PHP files, the PHP files
match the pinned artifact, php and php-fpm report 8.2.35, no library is
missing, `php -m` and `php-fpm -m` equal the deployed image, `php-fpm -t`
and `nginx -t` pass, a PHP page served through the image's nginx and
php-fpm parses a multipart upload, PHP's built-in server parses one too, and
the tag is definitively absent from the registry (MANIFEST_UNKNOWN).
