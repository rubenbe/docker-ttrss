#!/bin/bash
set -euo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ "$(id -u)" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"

				# strip off any '#' symbol ('#1000' is valid syntax for Apache)
				pound='#'
				user="${user#$pound}"
				group="${group#$pound}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$(id -u)"
		group="$(id -g)"
	fi

	if [ ! -e index.php ] && [ ! -e opml.php ]; then
		# if the directory exists and TTRSS doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
		if [ "$(id -u)" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
			chown "$user:$group" .
		fi

		echo >&2 "TT-RSS not found in $PWD - copying now..."
		if [ -n "$(ls -A)" ]; then
			echo >&2 "WARNING: $PWD is not empty! (copying anyhow)"
		fi
		sourceTarArgs=(
			--create
			--file -
			--directory /usr/src/ttrss
			--owner "$user" --group "$group"
		)
		targetTarArgs=(
			--extract
			--file -
		)
		if [ "$user" != '0' ]; then
			# avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
			targetTarArgs+=( --no-overwrite-dir )
		fi
		tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"
		echo >&2 "Complete! TT-RSS has been successfully copied to $PWD"
		if [ ! -e .htaccess ]; then
			# NOTE: The "Indexes" option is disabled in the php:apache base image
			cat > .htaccess <<-'EOF'
				# BEGIN WordPress
				<IfModule mod_rewrite.c>
				RewriteEngine On
				RewriteBase /
				RewriteRule ^index\.php$ - [L]
				RewriteCond %{REQUEST_FILENAME} !-f
				RewriteCond %{REQUEST_FILENAME} !-d
				RewriteRule . /index.php [L]
				</IfModule>
				# END WordPress
			EOF
			chown "$user:$group" .htaccess
		fi
	fi

	# allow any of these "Authentication Unique Keys and Salts." to be specified via
	# environment variables with a "TTRSS_" prefix (ie, "TTRSS_AUTH_KEY")
	uniqueEnvs=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	envs=(
		TTRSS_DB_HOST
		TTRSS_DB_USER
		TTRSS_DB_PASSWORD
		TTRSS_DB_NAME
		TTRSS_DB_CHARSET
		TTRSS_DB_COLLATE
		"${uniqueEnvs[@]/#/TTRSS_}"
		TTRSS_TABLE_PREFIX
		TTRSS_DEBUG
		TTRSS_CONFIG_EXTRA
	)
	haveConfig=
	for e in "${envs[@]}"; do
		file_env "$e"
		if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
			haveConfig=1
		fi
	done

	# linking backwards-compatibility
	if [ -n "${!MYSQL_ENV_MYSQL_*}" ]; then
		haveConfig=1
		# host defaults to "mysql" below if unspecified
		: "${TTRSS_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}"
		if [ "$TTRSS_DB_USER" = 'root' ]; then
			: "${TTRSS_DB_PASSWORD:=${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
		else
			: "${TTRSS_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-}}"
		fi
		: "${TTRSS_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-}}"
	fi

	# only touch "wp-config.php" if we have environment-supplied configuration values
	if [ "$haveConfig" ]; then
		: "${TTRSS_DB_TYPE:=pgsql}"
		: "${TTRSS_DB_HOST:=mysql}"
		: "${TTRSS_DB_USER:=root}"
		: "${TTRSS_DB_PASSWORD:=}"
		: "${TTRSS_DB_NAME:=ttrss}"
		: "${TTRSS_DB_CHARSET:=utf8}"
		: "${TTRSS_DB_COLLATE:=}"

		# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
		# https://github.com/docker-library/wordpress/issues/116
		# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
		sed -ri -e 's/\r$//' config*

		if [ ! -e config.php ]; then
			awk '
				/^\/\*.*stop editing.*\*\/$/ && c == 0 {
					c = 1
					system("cat")
					if (ENVIRON["TTRSS_CONFIG_EXTRA"]) {
						print "// TTRSS_CONFIG_EXTRA"
						print ENVIRON["TTRSS_CONFIG_EXTRA"] "\n"
					}
				}
				{ print }
			' config.php-dist > config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}

EOPHP
			chown "$user:$group" config.php
		elif [ -e config.php ] && [ -n "$TTRSS_CONFIG_EXTRA" ] && [[ "$(< config.php)" != *"$TTRSS_CONFIG_EXTRA"* ]]; then
			# (if the config file already contains the requested PHP code, don't print a warning)
			echo >&2
			echo >&2 'WARNING: environment variable "TTRSS_CONFIG_EXTRA" is set, but "config.php" already exists'
			echo >&2 '  The contents of this variable will _not_ be inserted into the existing "config.php" file.'
			echo >&2 '  (see https://github.com/docker-library/wordpress/issues/333 for more details)'
			echo >&2
		fi

		# see http://stackoverflow.com/a/2705678/433558
		sed_escape_lhs() {
			echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
		}
		sed_escape_rhs() {
			echo "$@" | sed -e 's/[\/&]/\\&/g'
		}
		php_escape() {
			local escaped="$(php -r 'var_export(('"$2"') $argv[1]);' -- "$1")"
			if [ "$2" = 'string' ] && [ "${escaped:0:1}" = "'" ]; then
				escaped="${escaped//$'\n'/"' + \"\\n\" + '"}"
			fi
			echo "$escaped"
		}
		set_config() {
			key="$1"
			value="$2"
			var_type="${3:-string}"
			start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
			end="\);"
			if [ "${key:0:1}" = '$' ]; then
				start="^(\s*)$(sed_escape_lhs "$key")\s*="
				end=";"
			fi
			sed -ri -e "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" wp-config.php
		}

		set_config 'DB_TYPE' "$TTRSS_DB_TYPE"
		set_config 'DB_HOST' "$TTRSS_DB_HOST"
		set_config 'DB_USER' "$TTRSS_DB_USER"
		set_config 'DB_PASSWORD' "$TTRSS_DB_PASSWORD"
		set_config 'DB_NAME' "$TTRSS_DB_NAME"
		set_config 'DB_CHARSET' "$TTRSS_DB_CHARSET"
		set_config 'DB_COLLATE' "$TTRSS_DB_COLLATE"

		for unique in "${uniqueEnvs[@]}"; do
			uniqVar="TTRSS_$unique"
			if [ -n "${!uniqVar}" ]; then
				set_config "$unique" "${!uniqVar}"
			else
				# if not specified, let's generate a random value
				currentVal="$(sed -rn -e "s/define\(\s*(([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\s*\);/\4/p" wp-config.php)"
				if [ "$currentVal" = 'put your unique phrase here' ]; then
					set_config "$unique" "$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)"
				fi
			fi
		done

		if [ "$TTRSS_TABLE_PREFIX" ]; then
			set_config '$table_prefix' "$TTRSS_TABLE_PREFIX"
		fi

		if [ "$TTRSS_DEBUG" ]; then
			set_config 'WP_DEBUG' 1 boolean
		fi

		if ! TERM=dumb php -- <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

// https://codex.wordpress.org/Editing_wp-config.php#MySQL_Alternate_Port
//   "hostname:port"
// https://codex.wordpress.org/Editing_wp-config.php#MySQL_Sockets_or_Pipes
//   "hostname:unix-socket-path"
list($host, $socket) = explode(':', getenv('TTRSS_DB_HOST'), 2);
$port = 0;
if (is_numeric($socket)) {
	$port = (int) $socket;
	$socket = null;
}
$user = getenv('TTRSS_DB_USER');
$pass = getenv('TTRSS_DB_PASSWORD');
$dbName = getenv('TTRSS_DB_NAME');

$maxTries = 10;
do {
	$mysql = new mysqli($host, $user, $pass, '', $port, $socket);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($dbName) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

$mysql->close();
EOPHP
		then
			echo >&2
			echo >&2 "WARNING: unable to establish a database connection to '$TTRSS_DB_HOST'"
			echo >&2 '  continuing anyways (which might have unexpected results)'
			echo >&2
		fi
	fi

	# now that we're definitely done writing configuration, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
	for e in "${envs[@]}"; do
		unset "$e"
	done
fi

exec "$@"
