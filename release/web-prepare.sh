#!/bin/sh
# Run by release/in-image-report.sh before nginx -t (gate_web_prepare): install
# the SeAT vhost the way /entrypoint.sh install_configs does at start (copy
# /opt/eveseat/sources/eveseat.conf into conf.d and drop the default site), so
# the gate tests the real vhost.
set -e
cp /opt/eveseat/sources/eveseat.conf /etc/nginx/conf.d/eveseat.conf
rm -f /etc/nginx/sites-enabled/default
