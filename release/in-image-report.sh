#!/bin/sh
# Runs inside an image (mounted read-only at /release). Prints the PHP facts
# that release/verify-image.sh compares between the deployed image, the
# official PHP image the new PHP comes from, and the new image.
#
# Usage: in-image-report.sh <PHP extension directory> [<FPM prepare script> [<web prepare script>]]
#
# The optional prepare scripts are run first (output discarded) for images that
# render their FPM or web server configuration at start-up. Empty arguments
# mean no prepare script.
set -u
LC_ALL=C
export LC_ALL

ext_dir=$1
fpm_prepare=${2:-}
web_prepare=${3:-}

echo "@@ version"
php -v 2>&1 | head -n 1
php-fpm -v 2>&1 | head -n 1
php -r 'echo PHP_VERSION, "\n";' 2>&1

echo "@@ modules-cli"
php -m 2>&1

echo "@@ modules-fpm"
php-fpm -m 2>&1

echo "@@ fpm-test"
if [ -n "$fpm_prepare" ]; then
    "$fpm_prepare" >/dev/null 2>&1
    echo "prepare $fpm_prepare exit=$?"
fi
fpm_test=$(php-fpm -t 2>&1)
fpm_status=$?
printf '%s\n' "$fpm_test" | sed 's/^\[[^]]*\] //'
echo "exit=$fpm_status"

echo "@@ nginx-test"
if [ -n "$web_prepare" ]; then
    "$web_prepare" >/dev/null 2>&1
    echo "prepare $web_prepare exit=$?"
fi
if command -v nginx >/dev/null 2>&1; then
    nginx_test=$(nginx -t 2>&1)
    nginx_status=$?
    printf '%s\n' "$nginx_test"
    echo "exit=$nginx_status"
else
    echo "absent"
fi

echo "@@ apache-test"
apache_ctl=$(command -v apache2ctl || command -v apachectl || true)
if [ -n "$apache_ctl" ]; then
    apache_test=$("$apache_ctl" -t 2>&1)
    apache_status=$?
    printf '%s\n' "$apache_test"
    echo "exit=$apache_status"
else
    echo "absent"
fi

echo "@@ missing-libraries"
for binary in /usr/local/bin/php /usr/local/sbin/php-fpm "$ext_dir"/*.so; do
    [ -e "$binary" ] || continue
    ldd "$binary" 2>&1 | grep -E 'not found' | sed "s|^|$binary: |"
done

echo "@@ files"
cd /
for path in usr/local/bin/php usr/local/bin/php-config usr/local/bin/phpize \
    usr/local/sbin/php-fpm usr/local/include/php usr/local/lib/php/build "${ext_dir#/}"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    find "$path" \( -type f -o -type l \) -print
done | sort | while IFS= read -r path; do
    if [ -L "$path" ]; then
        echo "link $(readlink "$path") /$path"
    else
        echo "file $(sha256sum < "$path" | cut -c1-64) /$path"
    fi
done

echo "@@ end"
