#!/bin/sh
# Usage (inside the image): multipart-smoke.sh <php cli binary>
#
# PHP's built-in web server uses the same multipart/form-data parser
# (main/rfc1867.c) as php-fpm, so an ordinary upload must still fill $_POST
# and $_FILES after the parser is patched.
set -eu

php_bin=${1:-php}
work=$(mktemp -d)
cat > "$work/upload.php" <<'PHP'
<?php
echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
printf 'hello' > "$work/upload.txt"

"$php_bin" -d file_uploads=1 -S 127.0.0.1:8089 -t "$work" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl -s -o /dev/null http://127.0.0.1:8089/upload.php && break
    sleep 0.5
done

result=$(curl -s -F a=b -F "f=@$work/upload.txt" http://127.0.0.1:8089/upload.php)
if [ "$result" != "1:5:b" ]; then
    echo "multipart upload returned '$result', expected '1:5:b'" >&2
    exit 1
fi
echo "multipart upload ok ($("$php_bin" -r 'echo PHP_VERSION;'))"
