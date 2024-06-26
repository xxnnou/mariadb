#!/usr/bin/env bash
set -Eeuo pipefail
#
# Usage ./update.sh [version(multiple)...]
#

defaultSuite='noble'
declare -A suites=(
	[10.4]='focal'
	[10.5]='focal'
	[10.6]='focal'
	[10.11]='jammy'
	[11.0]='jammy'
	[11.1]='jammy'
	[11.2]='jammy'
	[11.3]='jammy'
	[11.4]='jammy'
)

declare -A suffix=(
	['focal']='ubu2004'
	['jammy']='ubu2204'
	['noble']='ubu2404'
)

#declare -A dpkgArchToBashbrew=(
#	[amd64]='amd64'
#	[armel]='arm32v5'
#	[armhf]='arm32v7'
#	[arm64]='arm64v8'
#	[i386]='i386'
#	[ppc64el]='ppc64le'
#	[s390x]='s390x'
#)

# For testing with https://downloads.dev.mariadb.org/rest-api
typeset -r DOWNLOADS_REST_API="https://downloads.mariadb.org/rest-api"

update_version()
{
	echo "$version: $mariaVersion ($releaseStatus)"

	suite="${suites[$version]:-$defaultSuite}"
	fullVersion=1:${mariaVersion}+maria~${suffix[${suite}]}

	if [[ $version = 10.[234] ]]; then
		arches="amd64 arm64v8 ppc64le"
	else
		arches="amd64 arm64v8 ppc64le s390x"
	fi

	cp Dockerfile.template "$version/Dockerfile"

	cp docker-entrypoint.sh healthcheck.sh "$version/"
	chmod a+x "$version"/healthcheck.sh
	sed -i \
		-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		-e 's!%%MARIADB_MAJOR%%!'"$version"'!g' \
		-e 's!%%MARIADB_RELEASE_STATUS%%!'"$releaseStatus"'!g' \
		-e 's!%%MARIADB_SUPPORT_TYPE%%!'"$supportType"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%ARCHES%%! '"$arches"'!g' \
		"$version/Dockerfile"

	sed -i \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		"$version/docker-entrypoint.sh"

	# Start using the new executable names
	case "$version" in
		10.4)
			sed -i -e '/--old-mode/d' \
				-e 's/REPLICATION REPLICA/REPLICATION SLAVE/' \
			       	-e 's/START REPLICA/START SLAVE/' \
				-e '/memory\.pressure/,+7d' \
				"$version/docker-entrypoint.sh"
			sed -i -e 's/ REPLICA\$/ SLAVE$/' "$version"/healthcheck.sh
			sed -i -e 's/\/run/\/var\/run\//g' \
				-e '/^# Issue #560/,+1d' \
				"$version/Dockerfile"
			;; # almost nothing to see/do here
		10.5)
			sed -i -e '/--old-mode/d' \
				-e '/memory\.pressure/,+7d' "$version/docker-entrypoint.sh"
			sed -i -e '/backwards compat/d' \
				-e '/^# Issue #560/,+1d' \
				"$version/Dockerfile"
			;;
		*)
			sed -i -e '/^CMD/s/mysqld/mariadbd/' \
				-e '/backwards compat/d' "$version/Dockerfile"
			sed -i -e 's/mysql_upgrade\([^_]\)/mariadb-upgrade\1/' \
				-e 's/mysqldump/mariadb-dump/' \
				-e 's/mysqladmin/mariadb-admin/' \
				-e 's/\bmysql --protocol\b/mariadb --protocol/' \
				-e 's/mysql_install_db/mariadb-install-db/' \
				-e 's/mysql_tzinfo_to_sql/mariadb-tzinfo-to-sql/' \
				"$version/docker-entrypoint.sh"
			if [ "$version" = 10.6 ]; then
				# my_print_defaults didn't recognise --mysqld until 10.11
				sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\([^-]\)mysqld/\1mariadbd/g' \
					"$version/docker-entrypoint.sh"
				sed -i -e '/^# Issue #560/,+1d' \
					"$version/Dockerfile"
			else
				sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\mysqld/mariadbd/g' \
					"$version/docker-entrypoint.sh"
			fi
			sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\bmysql\b/mariadb/' "$version/healthcheck.sh"
			if [ ! "$version" = 10.6 ]; then
				# quoted $ intentional
				# shellcheck disable=SC2016
				sed -i -e '/^ARG MARIADB_MAJOR/d' \
					-e '/^ENV MARIADB_MAJOR/d' \
					-e 's/-\$MARIADB_MAJOR//' \
					"$version/Dockerfile"
			else
				sed -i -e '/memory\.pressure/,+7d' "$version/docker-entrypoint.sh"
			fi
			if [[ $version =~ 11.[012345] ]]; then
				sed -i -e 's/mysql_upgrade_info/mariadb_upgrade_info/' \
					"$version/docker-entrypoint.sh" "$version/healthcheck.sh"
			fi
			if [[ $version =~ 11.[01] ]]; then
				sed -i -e 's/50-mysqld_safe.cnf/50-mariadb_safe.cnf/' "$version/Dockerfile"
			fi
			if [[ $version =~ 11.[012] ]] || [ "$version" = 10.11 ]; then
				sed -i -e '/^# Issue #560/,+1d' \
					"$version/Dockerfile"
			fi
			;&
	esac

	# Add version to versions.json
	versionJson="$(jq -e \
		--arg milestone "$version" --arg version "$mariaVersion" --arg fullVersion "$fullVersion" --arg releaseStatus "$releaseStatus" --arg supportType "$supportType" --arg base "ubuntu:$suite" --arg arches "$arches" \
		'.[$milestone] = {"milestone": $milestone, "version": $version, "fullVersion": $fullVersion, "releaseStatus": $releaseStatus, "supportType": $supportType, "base": $base, "arches": $arches|split(" ")}' versions.json)"
	printf '%s\n' "$versionJson" > versions.json
}

update_version_array()
{
	c0=$(( $1 - 2 ))
	c1=$(( $1 - 1 ))
	version=${release[$c0]}
	if [ ! -d "$version" ]; then
		echo >&2 "warning: no rule for $version"
		return
	fi
	mariaversion

	releaseStatus=${release[$c1]}

	case "$releaseStatus" in
		Alpha | Beta | Gamma | RC | Stable ) ;; # sanity check
		*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; ;;
	esac

	supportType=$2

	update_version
}

mariaversion()
{
	mariaVersion=$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/${version}" \
		| jq -r 'first(.releases[]).release_id')
}

all()
{
	printf '%s\n' "{}" > versions.json

	readarray -O 0 -c 3 -C update_version_array -t release <<< "$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/" \
		| jq -r '.major_releases[] | [ .release_id ], [ .release_status ], [ .release_support_type ]  | @tsv')"
}

development_version=11.5

in_development()
{
	releaseStatus=Alpha
	supportType=Unknown
	version=$development_version
	mariaVersion=${development_version}.0
	[ -d "$development_version" ] && update_version
}


if [ $# -eq 0 ]; then
	in_development
	all
	exit 0
fi

versions=( "$@" )

for version in "${versions[@]}"; do
	if [ "$version" == $development_version ]; then
		in_development
		continue
	fi
	if [ ! -d "$version" ]; then
		mariaVersion=$version
		version=${version%.[[:digit:]]*}
	else
		mariaversion
	fi
	readarray -t release <<< "$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/" \
		| jq -r --arg version "$version" '.major_releases[] | select(.release_id == $version) | [ .release_status ] , [ .release_support_type ] | @tsv')"
	releaseStatus=${release[0]}
	supportType=${release[1]}

	update_version
done
