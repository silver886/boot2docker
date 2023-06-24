#!/usr/bin/env bash
set -Eeuo pipefail

# http://tinycorelinux.net/
major='14.x'
version='14.0'
mirrors=(
	https://distro.ibiblio.org/tinycorelinux
)

# https://www.kernel.org/
kernelBase='6.1'
# https://download.docker.com/linux/static/stable/x86_64/
dockerBase='24.0'

# avoid issues with slow Git HTTP interactions (*cough* sourceforge *cough*)
export GIT_HTTP_LOW_SPEED_LIMIT='100'
export GIT_HTTP_LOW_SPEED_TIME='2'
# ... or servers being down
wget() { command wget --timeout=2 "$@" -o /dev/null; }

tclLatest="$(wget -qO- 'https://distro.ibiblio.org/tinycorelinux/latest-x86_64')"
if [ $tclLatest != $version ]; then
	echo "Tiny Core Linux has an update! ($tclLatest)"
	exit 1
fi

kernelLatest="$(
	wget -qO- 'https://www.kernel.org/releases.json' \
		| jq -r '[.releases[] | select(.moniker == "longterm")] | sort_by(.version | split(".") | map(tonumber)) | reverse | .[0].version'
)"
if ! [[ $kernelLatest =~ ^$kernelBase[0-9.]+ ]]; then
	echo "Linux Kernel has an update! ($kernelLatest)"
	exit 1
fi

dockerLatest="$(
	wget -qO- 'https://api.github.com/repos/moby/moby/releases' \
		| jq -r '[.[] | select(.prerelease | not)] | sort_by(.tag_name | sub("^v"; "") | split(".") | map(tonumber)) | reverse | .[0].tag_name'
)"
if ! [[ $dockerLatest =~ ^v$dockerBase[0-9.]+ ]]; then
	echo "Docker has an update! ($dockerLatest)"
	exit 1
fi

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

seds=(
	-e 's!^(ENV TCL_MIRRORS).*!\1 '"${mirrors[*]}"'!'
	-e 's!^(ENV TCL_MAJOR).*!\1 '"$major"'!'
	-e 's!^(ENV TCL_VERSION).*!\1 '"$version"'!'
)

fetch() {
	local file
	for file; do
		local mirror
		for mirror in "${mirrors[@]}"; do
			if wget -qO- "$mirror/$major/$file"; then
				return 0
			fi
		done
	done
	return 1
}

arch='x86_64'
rootfs='rootfs64.gz'

rootfsMd5="$(
	fetch \
		"$arch/archive/$version/distribution_files/$rootfs.md5.txt" \
		"$arch/release/distribution_files/$rootfs.md5.txt"
)"
rootfsMd5="${rootfsMd5%% *}"
seds+=(
	-e 's!^ENV TCL_ROOTFS.*!ENV TCL_ROOTFS="'"$rootfs"'" TCL_ROOTFS_MD5="'"$rootfsMd5"'"!'
)

kernelVersion="$(
	wget -qO- 'https://www.kernel.org/releases.json' \
		| jq -r --arg base "$kernelBase" '.releases[] | .version | select(startswith($base + "."))'
)"
seds+=(
	-e 's!^(ENV LINUX_VERSION).*!\1 '"$kernelVersion"'!'
)

dockerVersion="$(
	wget -qO- 'https://api.github.com/repos/moby/moby/releases' \
		| jq -r --arg base "v$dockerBase" '[.[] | .tag_name | select(startswith($base + "."))][0]' \
		| sed -e 's!^v!!'
)"
seds+=(
	-e 's!^(ENV DOCKER_VERSION).*!\1 '"$dockerVersion"'!'
)

squashfsVersion="$(
	git ls-remote --tags 'https://github.com/plougher/squashfs-tools' \
		| cut -d/ -f3 \
		| cut -d^ -f1 \
		| grep -E '^squashfs-tools-[[:digit:]]+' \
		| cut -d- -f3- \
		| sort -rV \
		| head -1
)"
seds+=(
	-e 's!^(ENV SQUASHFS_VERSION).*!\1 '"$squashfsVersion"'!'
	-e 's!^(# https://github.com/plougher/squashfs-tools/blob/).*(/squashfs-tools/Makefile#L1)$!\1'"$squashfsVersion"'\2!'
)

vboxVersion="$(
	wget -qO- 'https://download.virtualbox.org/virtualbox/' \
		| grep -oE 'href="[0-9.]+/?"' \
		| cut -d'"' -f2 \
		| cut -d/ -f1 \
		| tail -1
)"
vboxSha256="$(
	{
		wget -qO- "https://download.virtualbox.org/virtualbox/$vboxVersion/SHA256SUMS" \
		|| wget -qO- "https://www.virtualbox.org/download/hashes/$vboxVersion/SHA256SUMS"
	} | awk '$2 ~ /^[*]?VBoxGuestAdditions_.*[.]iso$/ { print $1 }'
)"
seds+=(
	-e 's!^(ENV VBOX_VERSION).*!\1 '"$vboxVersion"'!'
	-e 's!^(ENV VBOX_SHA256).*!\1 '"$vboxSha256"'!'
)

parallelsVersion="$(
	command wget -SO- --spider "$(
		wget -qO- "https://download.parallels.com/website_links/$(
			wget -qO- https://download.parallels.com/website_links/desktop/index.json \
				| jq -r 'to_entries | sort_by(.key) | reverse | .[0].value.builds.en_US'
		)" \
		| jq -r '.[] | select(.category.name | startswith("Parallels Desktop")) | .contents[] | select(.name | startswith("Parallels Desktop")) | .files.DMG'
	)" 2>&1 >/dev/null \
	| grep -oE 'https://download.parallels.com/desktop/.* \[following]' \
	| sed -re 's|.*/([0-9.-]+)/.*|\1|'
)"
seds+=(
	-e 's!^(ENV PARALLELS_VERSION).*!\1 '"$parallelsVersion"'!'
)

xenVersion="$(
	git ls-remote --tags 'https://github.com/xenserver/xe-guest-utilities' \
		| cut -d/ -f3 \
		| cut -d^ -f1 \
		| grep -E '^v[[:digit:]]+' \
		| cut -dv -f2- \
		| sort -rV \
		| head -1
)"
seds+=(
	-e 's!^(ENV XEN_VERSION).*!\1 '"$xenVersion"'!'
)

ctopVersion="$(
	git ls-remote --tags 'https://github.com/bcicen/ctop' \
		| cut -d/ -f3 \
		| cut -d^ -f1 \
		| grep -E '^v[[:digit:]]+' \
		| cut -dv -f2- \
		| sort -rV \
		| head -1
)"
seds+=(
	-e 's!^(ENV CTOP_VERSION).*!\1 '"$ctopVersion"'!'
)

set -x
sed -ri "${seds[@]}" Dockerfile
