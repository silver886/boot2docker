#!/usr/bin/env bash
set -Eeuo pipefail

# https://tinycorelinux.net/
major='13.x'
version='13.1'

mirrors=(
	https://distro.ibiblio.org/tinycorelinux
	https://repo.tinycorelinux.net
)

# https://www.kernel.org/
kernelBase='5.15'
# https://download.docker.com/linux/static/stable/x86_64/
dockerBase='23.0'
# https://github.com/plougher/squashfs-tools/releases
squashfsBase='4.5'
# https://download.virtualbox.org/virtualbox/
vboxBase='7.0'
# https://www.parallels.com/products/desktop/download/
parallelsBase='18'
# https://github.com/bcicen/ctop/releases
ctopBase='0.7'

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

vboxLatest="$(wget -qO- 'https://download.virtualbox.org/virtualbox/LATEST-STABLE.TXT')"
if ! [[ $vboxLatest =~ ^$vboxBase[0-9.]+ ]]; then
	echo "VirtualBox has an update! ($vboxLatest)"
	exit 1
fi

if ! wget -qO- --spider "https://www.parallels.com/directdownload/pd$parallelsBase/image/"; then
	echo 'Parallels Desktop has an update!'
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
	-e 's/^ENV TCL_ROOTFS.*/ENV TCL_ROOTFS="'"$rootfs"'" TCL_ROOTFS_MD5="'"$rootfsMd5"'"/'
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
	wget -qO- 'https://api.github.com/repos/plougher/squashfs-tools/releases' \
		| jq -r --arg base "$squashfsBase" '[.[] | .tag_name | select(startswith($base + "."))][0]' \
		| sed -e 's!^v!!'
)"
seds+=(
	-e 's!^(ENV SQUASHFS_VERSION).*!\1 '"$squashfsVersion"'!'
	-e 's!^(# https://github.com/plougher/squashfs-tools/blob/).*(/squashfs-tools/Makefile#L1)$!\1'"$squashfsVersion"'\2!'
)

vboxVersion="$(
	wget -qO- 'https://download.virtualbox.org/virtualbox/' \
		| grep -oE 'href="[0-9.]+/?"' \
		| cut -d'"' -f2 | cut -d/ -f1 \
		| grep -E "^$vboxBase[.]" \
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
	$(which wget) -SO- --spider "https://www.parallels.com/directdownload/pd$parallelsBase/image/" 2>&1 >/dev/null \
		| grep -oE 'https://download.parallels.com/desktop/.* \[following]' \
		| sed -re 's|.*/([0-9.-]+)/.*|\1|'
)"
seds+=(
	-e 's!^(ENV PARALLELS_VERSION).*!\1 '"$parallelsVersion"'!'
)

xenVersion="$(
	git ls-remote --tags 'https://github.com/xenserver/xe-guest-utilities.git' \
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
	wget -qO- 'https://api.github.com/repos/bcicen/ctop/releases' \
		| jq -r --arg base "v$ctopBase" '[.[] | .tag_name | select(startswith($base + "."))][0]' \
		| sed -e 's!^v!!'
)"
seds+=(
	-e 's!^(ENV CTOP_VERSION).*!\1 '"$ctopVersion"'!'
)

set -x
sed -ri "${seds[@]}" Dockerfile
