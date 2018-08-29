FROM repo.cylo.io/ubuntu-lemp

# Disable Supervisor on the parent image, this allows us to run commands after the parent has finished installing.
ENV START_SUPERVISOR=false

# Declare Environment variables required by the parent:
ENV MYSQL_ROOT_PASS=mysqlr00t
ENV DB_USER=seat
ENV DB_PASS=seat
ENV DB_NAME=seat

RUN apt update
RUN apt install -y redis-server \
                   sudo \
                   zip \
                   php7.2-cli \
                   php7.2-mysql \
                   #php7.2-mcrypt \
                   php7.2-intl \
                   php7.2-curl \
                   php7.2-gd \ 
                   php7.2-mbstring \
                   php7.2-bz2 \
                   php7.2-dom \
                   php7.2-zip


# Dont use /sources as the destination as the ubuntu-lep base image deletes the /sources dir during cleanup.
ADD /sources /tmp
ADD /scripts /scripts
RUN chmod -R +x /scripts

RUN mkdir /data && \
    chown -R redis:redis /data && \
    echo -e "include /etc/redis-local.conf\n" >> /etc/redis.conf

# Register the COMPOSER_HOME environment variable
ENV COMPOSER_HOME /composer

# Add global binary directory to PATH and make sure to re-export it
ENV PATH /composer/vendor/bin:$PATH

# Allow Composer to be run as root
ENV COMPOSER_ALLOW_SUPERUSER 1

# Setup the Composer installer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && hash -r

ENTRYPOINT ["/scripts/Entrypoint.sh"]