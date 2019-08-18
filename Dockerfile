FROM php:7.1-fpm-alpine

# docker-entrypoint.sh dependencies
RUN apk add --no-cache \
# in theory, docker-entrypoint.sh is POSIX-compliant, but priority is a working, consistent image
		bash \
# BusyBox sed is not sufficient for some of our sed expressions
		sed

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging

RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

VOLUME /var/www/html

ENV TTRSS_VERSION 19.8
ENV TTRSS_SHA1 6f6ff49bc8d396d31d13bf6c31ab45ec3bb99391

RUN set -ex; \
	curl -o ttrss.tar.gz -fSL "https://git.tt-rss.org/git/tt-rss/archive/${TTRSS_VERSION}.tar.gz"; \
	echo "$TTRSS_SHA1 *ttrss.tar.gz" | sha1sum -c -; \
# upstream tarballs include ./tt-rss/ so this gives us /usr/src/tt-rss
	tar -xzf ttrss.tar.gz -C /usr/src/; \
	rm ttrss.tar.gz; \
	mv /usr/src/tt-rss /usr/src/ttrss; \
	chown -R www-data:www-data /usr/src/ttrss

COPY docker-entrypoint.sh /usr/local/bin/

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
