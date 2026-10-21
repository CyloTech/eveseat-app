#!/bin/sh
# Usage (inside the image, as root, no network needed):
#   fpm-nginx-smoke.sh <expected PHP version>
#
# Serves a PHP page through the image's own nginx and php-fpm binaries, the
# path production requests take, and posts a multipart/form-data upload to
# it. php-fpm loads the image's php.ini and conf.d (so every deployed
# extension is loaded); only a throwaway pool and server block in a temporary
# directory are added. Prints the page and exits 0 only when php-fpm (SAPI
# fpm-fcgi) at the expected version parsed the upload into $_POST and $_FILES.
set -eu

expected=$1
work=$(mktemp -d)
fpm_pid=
cleanup() {
    [ -n "$fpm_pid" ] && kill "$fpm_pid" 2>/dev/null || true
    [ -f "$work/nginx.pid" ] && kill "$(cat "$work/nginx.pid")" 2>/dev/null || true
    sleep 0.5
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/www" "$work/tmp"
chmod 755 "$work" "$work/www"
chmod 1777 "$work/tmp"
cat > "$work/www/upload.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo PHP_SAPI, ' ', PHP_VERSION, ' ', count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':',
    $_FILES['f']['error'] ?? -1, ':', $_POST['a'] ?? '', ':',
    (isset($_FILES['f']['tmp_name']) && is_uploaded_file($_FILES['f']['tmp_name'])
        ? hash_file('sha256', $_FILES['f']['tmp_name']) : 'no-file');
PHP
printf 'hello multipart\n' > "$work/upload.txt"
upload_sha=$(sha256sum < "$work/upload.txt" | cut -c1-64)

cat > "$work/fpm.conf" <<CONF
[global]
error_log = $work/fpm.log
daemonize = no
[smoke]
user = www-data
group = www-data
listen = 127.0.0.1:9187
pm = static
pm.max_children = 2
catch_workers_output = yes
php_admin_value[upload_tmp_dir] = $work/tmp
php_admin_value[file_uploads] = 1
CONF
php-fpm -y "$work/fpm.conf" -F >"$work/fpm.out" 2>&1 &
fpm_pid=$!

cat > "$work/nginx.conf" <<CONF
user root;
worker_processes 1;
pid $work/nginx.pid;
error_log $work/nginx-error.log;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $work/body;
    proxy_temp_path $work/proxy;
    fastcgi_temp_path $work/fastcgi;
    uwsgi_temp_path $work/uwsgi;
    scgi_temp_path $work/scgi;
    client_max_body_size 8m;
    server {
        listen 127.0.0.1:8187;
        root $work/www;
        location ~ \.php\$ {
            fastcgi_pass 127.0.0.1:9187;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
            fastcgi_param REQUEST_METHOD \$request_method;
            fastcgi_param CONTENT_TYPE \$content_type;
            fastcgi_param CONTENT_LENGTH \$content_length;
            fastcgi_param QUERY_STRING \$query_string;
            fastcgi_param REQUEST_URI \$request_uri;
            fastcgi_param DOCUMENT_ROOT \$document_root;
            fastcgi_param SERVER_PROTOCOL \$server_protocol;
            fastcgi_param GATEWAY_INTERFACE CGI/1.1;
            fastcgi_param REMOTE_ADDR \$remote_addr;
            fastcgi_param SERVER_ADDR \$server_addr;
            fastcgi_param SERVER_PORT \$server_port;
            fastcgi_param SERVER_NAME \$server_name;
            fastcgi_param REDIRECT_STATUS 200;
        }
    }
}
CONF
nginx -t -c "$work/nginx.conf" >/dev/null 2>&1 || { nginx -t -c "$work/nginx.conf"; exit 1; }
nginx -c "$work/nginx.conf"

# Wait for php-fpm to accept connections, then post the upload.
fpm_ready=no
for attempt in $(seq 1 60); do
    kill -0 "$fpm_pid" 2>/dev/null || break
    if php -n -r '$s = @fsockopen("127.0.0.1", 9187, $e, $m, 1); exit($s ? 0 : 1);'; then
        fpm_ready=yes
        break
    fi
    sleep 0.5
done
if [ "$fpm_ready" != yes ]; then
    echo "php-fpm did not start listening on 127.0.0.1:9187" >&2
    cat "$work/fpm.out" "$work/fpm.log" 2>/dev/null | tail -20 >&2
    exit 1
fi
result=
for attempt in $(seq 1 20); do
    result=$(curl -s --max-time 5 -F a=b -F "f=@$work/upload.txt" http://127.0.0.1:8187/upload.php || true)
    case "$result" in fpm-fcgi*) break ;; esac
    sleep 0.5
done
expected_result="fpm-fcgi $expected 1:16:0:b:$upload_sha"
if [ "$result" != "$expected_result" ]; then
    echo "nginx -> php-fpm multipart upload returned '$result', expected '$expected_result'" >&2
    cat "$work/fpm.out" "$work/fpm.log" "$work/nginx-error.log" 2>/dev/null | tail -20 >&2
    exit 1
fi
echo "nginx -> php-fpm page served and multipart upload parsed: $result"
