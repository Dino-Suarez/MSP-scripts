#!/bin/bash
#
# nessus-service-update.sh - Update an installed Tenable Nessus scanner to the
# latest release published on tenable.com, then restart nessusd.
#
# Supported platforms: RHEL, CentOS and Rocky Linux (Tenable "el" packages) and
# Fedora ("fc" packages), x86_64 only. Must be run as root.
# Download listing: https://www.tenable.com/downloads/nessus

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
readonly BASE_URL="https://www.tenable.com/downloads/api/v2/pages/nessus"
readonly PACKAGE_ARCH="x86_64"
readonly MAX_ATTEMPTS=3
readonly RETRY_DELAY=5   # seconds to wait between failed attempts

# Carried over from the original script, which ran curl with -k. Set to true to
# have curl verify tenable.com's TLS certificate.
readonly VERIFY_TLS=false

# EL major versions that Tenable has no package for, mapped to the major version
# whose package is used instead. RHEL 10 uses Tenable's RHEL 9 (el9) package.
# A native package is always preferred if Tenable starts publishing one.
declare -rA EL_PACKAGE_FALLBACK=([10]=9)

#------------------------------------------------------------------------------
# State (set at runtime)
#------------------------------------------------------------------------------
OS_ID=""
OS_MAJOR=""
PACKAGE_FAMILY=""          # "el" (RHEL/CentOS/Rocky) or "fc" (Fedora)
PACKAGE_TAGS=()            # Tenable platform tags to try, in order of preference
WORK_DIR=""                # scratch directory for the downloaded rpm
ORIGINAL_CRYPTO_POLICY=""  # empty if the system has no crypto-policies support

CURL_OPTS=(--fail --location --show-error)
[[ $VERIFY_TLS == true ]] || CURL_OPTS+=(--insecure)

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

require_root() {
	[[ $(id -u) -eq 0 ]] || die "This script must be run as root."
}

# True if version $1 is strictly newer than version $2.
version_gt() {
	[[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# Prints the installed Nessus version, or nothing if Nessus isn't installed.
installed_version() {
	if rpm -q Nessus &>/dev/null; then
		rpm -q --queryformat '%{VERSION}' Nessus
	fi
}

#------------------------------------------------------------------------------
# System crypto policy
#
# tenable.com is fetched under the LEGACY crypto policy. The policy that was
# active beforehand is restored after every request, and again on exit in case
# the script is interrupted mid-request.
#------------------------------------------------------------------------------
init_crypto_policy() {
	command -v update-crypto-policies &>/dev/null || return 0
	ORIGINAL_CRYPTO_POLICY=$(update-crypto-policies --show 2>/dev/null) || ORIGINAL_CRYPTO_POLICY=""
}

use_legacy_crypto() {
	[[ -n $ORIGINAL_CRYPTO_POLICY ]] || return 0
	update-crypto-policies --set LEGACY &>/dev/null || warn "Could not switch crypto policy to LEGACY."
}

restore_crypto_policy() {
	[[ -n $ORIGINAL_CRYPTO_POLICY ]] || return 0
	if [[ $(update-crypto-policies --show 2>/dev/null) != "$ORIGINAL_CRYPTO_POLICY" ]]; then
		update-crypto-policies --set "$ORIGINAL_CRYPTO_POLICY" &>/dev/null \
			|| warn "Could not restore crypto policy $ORIGINAL_CRYPTO_POLICY."
	fi
}

# curl wrapper: runs the request under the LEGACY policy, then puts it back.
tenable_curl() {
	local status=0
	use_legacy_crypto
	curl "${CURL_OPTS[@]}" "$@" || status=$?
	restore_crypto_policy
	return "$status"
}

cleanup() {
	restore_crypto_policy
	if [[ -n $WORK_DIR ]]; then
		rm -rf "$WORK_DIR"
	fi
}

#------------------------------------------------------------------------------
# OS detection
#------------------------------------------------------------------------------
detect_os() {
	[[ -r /etc/os-release ]] || die "Unable to read /etc/os-release."
	local version_id
	OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
	version_id=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
	OS_MAJOR=${version_id%%.*}

	case $OS_ID in
		rhel | centos | rocky) PACKAGE_FAMILY=el ;;
		fedora)                PACKAGE_FAMILY=fc ;;
		*) die "Detected OS is $OS_ID - only RHEL/CentOS/Rocky/Fedora are supported." ;;
	esac
	[[ $OS_MAJOR =~ ^[0-9]+$ ]] || die "Unable to determine the major version of $OS_ID."

	PACKAGE_TAGS=("$PACKAGE_FAMILY$OS_MAJOR")
	if [[ $PACKAGE_FAMILY == el && -n ${EL_PACKAGE_FALLBACK[$OS_MAJOR]:-} ]]; then
		PACKAGE_TAGS+=("el${EL_PACKAGE_FALLBACK[$OS_MAJOR]}")
	fi

	log "Detected OS is $OS_ID $OS_MAJOR."
}

#------------------------------------------------------------------------------
# Tenable release listing
#------------------------------------------------------------------------------
# Prints the latest Nessus version found in the release listing ($1).
parse_latest_version() {
	grep -oE '"latest":\{"Nessus - [0-9.]+"' <<< "$1" \
		| grep -oE '[0-9]+(\.[0-9]+)*' \
		| head -n 1 || true
}

# Prints the name of the package to download for this OS, given the listing ($1).
select_package() {
	local listing=$1 tag package

	for tag in "${PACKAGE_TAGS[@]}"; do
		package="Nessus-latest-${tag}.${PACKAGE_ARCH}.rpm"
		if grep -qF "$package" <<< "$listing"; then
			printf '%s\n' "$package"
			return 0
		fi
	done

	# Tenable's Fedora builds lag behind Fedora releases, so settle for the
	# newest one on offer.
	if [[ $PACKAGE_FAMILY == fc ]]; then
		package=$(grep -oE "Nessus-latest-fc[0-9]+\.${PACKAGE_ARCH}\.rpm" <<< "$listing" \
			| sort -uV | tail -n 1 || true)
		if [[ -n $package ]]; then
			printf '%s\n' "$package"
			return 0
		fi
	fi

	return 1
}

#------------------------------------------------------------------------------
# Download and install
#------------------------------------------------------------------------------
download_package() {
	local url=$1 rpm_file=$2
	local progress=(--silent)
	if [[ -t 2 ]]; then progress=(--progress-bar); fi
	tenable_curl "${progress[@]}" --output "$rpm_file" "$url"
}

# Downloads and installs the package, retrying up to MAX_ATTEMPTS times until
# the installed version matches the expected one.
install_package() {
	local url=$1 rpm_file=$2 expected_version=$3 attempt

	for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
		if download_package "$url" "$rpm_file" \
			&& rpm -Uvh "$rpm_file" \
			&& [[ $(installed_version) == "$expected_version" ]]; then
			return 0
		fi

		warn "Detected failure (attempt $attempt of $MAX_ATTEMPTS)."
		if (( attempt < MAX_ATTEMPTS )); then
			log "Trying again in ${RETRY_DELAY}s..."
			sleep "$RETRY_DELAY"
		fi
	done
	return 1
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
	require_root
	detect_os
	init_crypto_policy

	local installed latest listing package url
	installed=$(installed_version)
	[[ -n $installed ]] || die "Unable to find existing Nessus installation."
	log "Installed Nessus version is $installed."

	listing=$(tenable_curl --silent "$BASE_URL") || die "Unable to download the release list from tenable.com."
	latest=$(parse_latest_version "$listing")
	[[ -n $latest ]] || die "Unable to determine latest Nessus version from tenable.com."
	log "Latest available Nessus version is $latest."

	if ! version_gt "$latest" "$installed"; then
		log "No update needed."
		return 0
	fi

	package=$(select_package "$listing") \
		|| die "There is no Nessus download available for $OS_ID $OS_MAJOR (looked for: ${PACKAGE_TAGS[*]})."
	url="$BASE_URL/files/$package"

	WORK_DIR=$(mktemp -d)
	log "Downloading $url"
	install_package "$url" "$WORK_DIR/Nessus-$latest.$PACKAGE_ARCH.rpm" "$latest" \
		|| die "All $MAX_ATTEMPTS attempts failed!"

	log "Restarting the Nessus service..."
	systemctl restart nessusd || die "Failed to restart the Nessus service!"
	log "Done. Please verify the scanner is reachable after a few minutes."
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"