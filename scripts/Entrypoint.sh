#!/bin/bash
set -x

/bin/sh /scripts/lemp.sh

if [ ! -f /etc/es_installed ]; then
    mkdir -p /storage
    mkdir -p /etc/supervisor/conf.d
    mkdir -p /run/php
    mkdir -p /var/run/html/redis
    mkdir -p /home/appbox/logs/seat

    rm -f /home/appbox/config/nginx/sites-enabled/default-site.conf
    mv /tmp/eveseat.conf /home/appbox/config/nginx/sites-enabled/eveseat.conf
    mv /tmp/redis.conf /etc/redis.conf

    cd /home/appbox/public_html
    composer create-project eveseat/seat --no-dev --stability=stable
    cd /home/appbox/public_html/seat
    chmod -R guo+w /home/appbox/public_html/seat/storage

    rm -fr /home/appbox/public_html/seat/.env
    mv /tmp/eveconf /home/appbox/public_html/seat/.env
    sed -i 's#WEB_URL#'"${WEB_URL}"'#g' /home/appbox/public_html/seat/.env

    # Hack to enable SSL on our services:
sed -i -e 's#<?php#<?php \
if (isset($_SERVER["HTTP_X_FORWARDED_PROTO"]) \&\& $_SERVER["HTTP_X_FORWARDED_PROTO"] == "https") { \
  $_SERVER["HTTPS"] = "on"; \
}#g ' /home/appbox/public_html/seat/public/index.php

    chown -R appbox:appbox /home/appbox/public_html

    /usr/sbin/mysqld --user=appbox --socket=/run/mysqld/mysqld.sock &
    while ! mysqladmin --user=root --password=$MYSQL_ROOT_PASSWORD --host "127.0.0.1" ping --silent &> /dev/null ; do
    echo "Waiting for database connection..."
        sleep 2
    done

    # Publish the vendor files etc.
    #php /home/appbox/public_html/seat/artisan vendor:publish --force --all
    sudo -H -u appbox bash -c '/usr/bin/php /home/appbox/public_html/seat/artisan vendor:publish --force --all'
    sudo -H -u appbox bash -c '/usr/bin/php /home/appbox/public_html/seat/artisan migrate'
    sudo -H -u appbox bash -c '/usr/bin/php /home/appbox/public_html/seat/artisan db:seed --class=Seat\\Services\\database\\seeds\\ScheduleSeeder'
    sudo -H -u appbox bash -c '/usr/bin/php /home/appbox/public_html/seat/artisan eve:update:sde'

    # Start Redis Server
    redis-server &
    sleep 3

#    sed -i 's/$password = null;/$password = "'${ADMIN_PASS}'";/g' /home/appbox/public_html/seat/vendor/eveseat/console/src/Commands/Seat/Admin/Reset.php
#    /usr/local/bin/php /home/appbox/public_html/seat/artisan seat:admin:reset
#    sed -i 's/$password = "'${ADMIN_PASS}'";/$password = null;/g' /home/appbox/public_html/seat/vendor/eveseat/console/src/Commands/Seat/Admin/Reset.php

    LOGIN_URL=`sudo -H -u appbox bash -c 'php /home/appbox/public_html/seat/artisan seat:admin:login' | grep http`

cat << EOF > /home/appbox/public_html/seat/public/firstlogin.php
<?php
unlink('firstlogin.php');
header('Location: ${LOGIN_URL}');
?>
EOF

    # Add supervisor Config
cat << EOF > /etc/supervisor/conf.d/seat.conf
[program:seat]
command=/usr/bin/php /home/appbox/public_html/seat/artisan horizon
process_name = %(program_name)s-80%(process_num)02d
stdout_logfile = /home/appbox/logs/seat/seat-80%(process_num)02d.log
stdout_logfile_maxbytes=100MB
stdout_logfile_backups=10
numprocs=1
directory=/home/appbox/public_html/seat
stopwaitsecs=600
user=appbox
EOF

cat << EOF > /etc/supervisor/conf.d/redis.conf
[program:redis]
command=/usr/bin/redis-server
process_name = %(program_name)s-80%(process_num)02d
stdout_logfile = /home/appbox/logs/seat/redis-80%(process_num)02d.log
stdout_logfile_maxbytes=100MB
stdout_logfile_backups=10
numprocs=1
directory=/usr/bin
stopwaitsecs=600
user=appbox
EOF

    # set cronjobs (If any exist).
    crontab /tmp/crontab

    # Kill MySQL so supervisor can run it.
    pkill -9 mysqld

    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/es_installed
fi

exec /usr/bin/supervisord -n -c /home/appbox/config/supervisor/supervisord.conf