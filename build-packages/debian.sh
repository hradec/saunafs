#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# if an undefined variable is referenced, or if any command in a
# pipeline fails.  This makes the script robust and easier to debug.
#set -euo pipefail

DEPENDS=""

if [ "$DISTRO" == "debian" ] ; then
	if [ "$VERSION" == "13" ] ; then
	  DEPENDS=", python3-legacy-cgi"
	fi
fi

# Create the directory on the host where the installed files from the
# container will be written.  If it already exists, this command
# succeeds silently.  The relative path ensures the folder is
# created under the current working directory.
mkdir -p $DISTRO$VERSION-installed

# Name of the Docker image to build and run.  You can change this
# if you already have an image with the same name in your local
# Docker registry.
IMAGE_NAME="saunafs-builder-${DISTRO,,}-$VERSION"

BUILD_PARALLEL_ARG="--parallel"
if [ -n "${BUILD_JOBS:-}" ] ; then
	BUILD_PARALLEL_ARG="--parallel ${BUILD_JOBS}"
fi

DOCKER_RUN_ARGS=(--rm -ti)
if [ -n "${DOCKER_RUN_CPUS:-}" ] ; then
	DOCKER_RUN_ARGS+=(--cpus "${DOCKER_RUN_CPUS}")
fi
if [ -n "${DOCKER_RUN_MEMORY:-}" ] ; then
	DOCKER_RUN_ARGS+=(--memory "${DOCKER_RUN_MEMORY}")
fi
if [ -n "${DOCKER_RUN_MEMORY_SWAP:-}" ] ; then
	DOCKER_RUN_ARGS+=(--memory-swap "${DOCKER_RUN_MEMORY_SWAP}")
fi

if [ -z "${VCPKG_ARCHIVE_CACHE_DIR:-}" ] ; then
	VCPKG_ARCHIVE_CACHE_DIR="$(pwd)/$DISTRO$VERSION-build/vcpkg-archives"
fi
mkdir -p "${VCPKG_ARCHIVE_CACHE_DIR}"
echo "[+] Using shared vcpkg archive cache at ${VCPKG_ARCHIVE_CACHE_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${SAUNAFS_REPO_DIR:-}" ] ; then
	SAUNAFS_REPO_DIR="${SCRIPT_DIR}/../saunafs"
fi

if [ -d "${SAUNAFS_REPO_DIR}" ] ; then
	SAUNAFS_REPO_DIR="$(cd "${SAUNAFS_REPO_DIR}" && pwd)"
fi

if [ -z "${SAUNAFS_SYNC_LOCAL_WORKTREE:-}" ] ; then
	if [ -n "${DEV:-}" ] ; then
		SAUNAFS_SYNC_LOCAL_WORKTREE=1
	else
		SAUNAFS_SYNC_LOCAL_WORKTREE=0
	fi
fi

if [ -n "${SAUNAFS_REPO_DIR}" ] && [ -d "${SAUNAFS_REPO_DIR}/.git" ] ; then
	echo "[+] Local worktree checkout: ${SAUNAFS_REPO_DIR}"
else
	echo "[+] Local worktree checkout not found at ${SAUNAFS_REPO_DIR}"
fi
echo "[+] Local worktree patch apply: ${SAUNAFS_SYNC_LOCAL_WORKTREE}"

export TMPDIR_BUILD=$(mktemp -d)
LOCAL_WORKTREE_PATCH="${TMPDIR_BUILD}/${DISTRO}${VERSION}-local-worktree.patch"

generate_local_worktree_patch() {
	if [ "${SAUNAFS_SYNC_LOCAL_WORKTREE}" != "1" ] ; then
		return 0
	fi

	if [ -z "${SAUNAFS_REPO_DIR}" ] || [ ! -d "${SAUNAFS_REPO_DIR}/.git" ] ; then
		echo "[-] SAUNAFS_REPO_DIR must point at a git checkout when local worktree patching is enabled"
		exit 1
	fi

	echo "[+] Collecting local worktree changes into ${LOCAL_WORKTREE_PATCH}"
	: > "${LOCAL_WORKTREE_PATCH}"
		(
			cd "${SAUNAFS_REPO_DIR}"
			git diff --binary --no-ext-diff --full-index HEAD -- . > "${LOCAL_WORKTREE_PATCH}"
			while IFS= read -r -d '' file ; do
				if [ -d "${file}" ] ; then
					continue
				fi
				git diff --no-index --binary -- /dev/null "${file}" >> "${LOCAL_WORKTREE_PATCH}"
			done < <(git ls-files --others --exclude-standard -z)
		)

	if [ ! -s "${LOCAL_WORKTREE_PATCH}" ] ; then
		echo "[+] No local worktree changes found"
		rm -f "${LOCAL_WORKTREE_PATCH}"
	fi
}

generate_local_worktree_patch

if [ -z "${SAUNAFS_REPO_URL:-}" ] ; then
	echo "[-] SAUNAFS_REPO_URL is not set"
	exit 1
fi
if [ -z "${SAUNAFS_REPO_BRANCH:-}" ] ; then
	echo "[-] SAUNAFS_REPO_BRANCH is not set"
	exit 1
fi
echo "[+] Building source from ${SAUNAFS_REPO_URL} (${SAUNAFS_REPO_BRANCH})"

if [ ! -e ./$DISTRO$VERSION-installed/usr/bin/saunafs ] || [ "$(docker image list | grep ${IMAGE_NAME})" == "" ] ; then
   echo "[+] Building Docker image ${IMAGE_NAME} using Dockerfile..."
   docker build -t "${IMAGE_NAME}" . --file Dockerfile.${DISTRO,,}$VERSION
fi

echo "[+] Running container and copying installed files into ./installed..."
# Run the container with the installed image.  The current working
# directory's `installed` folder is mounted into the container at
# `/output`.  Inside the container we copy the contents of
# `/usr/local` (the installation prefix used in the Dockerfile) into
# `/output`.  The `cp -a` command preserves file attributes and
# copies hidden files as well.
if [ -f "${LOCAL_WORKTREE_PATCH}" ] ; then
	# Mount the generated patch so the container can apply the local edits to the clean clone.
	echo "[+] Mounting local worktree patch into the build container"
	DOCKER_RUN_ARGS+=(-v "${LOCAL_WORKTREE_PATCH}:/tmp/saunafs-local-worktree.patch:ro")
fi

cat > $TMPDIR_BUILD/$DISTRO$VERSION-saunafs-build.sh << EOF
set -euo pipefail

REPO_URL="${SAUNAFS_REPO_URL}"
REPO_BRANCH="${SAUNAFS_REPO_BRANCH}"
SYNC_LOCAL_WORKTREE="${SAUNAFS_SYNC_LOCAL_WORKTREE}"

normalize_repo_url() {
	local repo_url="\${1}"
	if command -v ssh >/dev/null 2>&1 ; then
		echo "\${repo_url}"
		return 0
	fi
	case "\${repo_url}" in
		git@github.com:*)
			echo "https://github.com/\${repo_url#git@github.com:}"
			;;
		ssh://git@github.com/*)
			echo "https://github.com/\${repo_url#ssh://git@github.com/}"
			;;
		*)
			echo "\${repo_url}"
			;;
	esac
}

REPO_URL="\$(normalize_repo_url "\${REPO_URL}")"

worktree_is_clean() {
	git diff --quiet &&
	git diff --cached --quiet &&
	[ -z "\$(git ls-files --others --exclude-standard)" ]
}

clone_repo_if_needed() {
	if [ -d /saunafs/git/.git ] ; then
		return 0
	fi
	rm -rf /saunafs/git
	if ! git clone --branch "\${REPO_BRANCH}" "\${REPO_URL}" /saunafs/git ; then
		git clone "\${REPO_URL}" /saunafs/git
	fi
}

checkout_requested_branch() {
	if ! git show-ref --verify --quiet "refs/remotes/origin/\${REPO_BRANCH}" ; then
		echo "[-] Branch not found on origin: \${REPO_BRANCH}"
		exit 1
	fi
	git checkout --force -B "\${REPO_BRANCH}" "origin/\${REPO_BRANCH}"
}

prepare_repo() {
	clone_repo_if_needed
	cd /saunafs/git
	git config --global --add safe.directory "\$PWD"
	git config --global pager.branch false
	git remote set-url origin "\${REPO_URL}"
	git fetch origin --prune --tags --recurse-submodules

	if [ "${DEV:-}" = "" ] ; then
		git reset --hard HEAD
		git clean -fd
		checkout_requested_branch
	elif [ "\${SYNC_LOCAL_WORKTREE}" = "1" ] ; then
		git reset --hard HEAD
		git clean -fd
		checkout_requested_branch
	else
		if worktree_is_clean ; then
			checkout_requested_branch
		else
			echo "[+] Keeping local modifications in /saunafs/git"
			echo "[+] Current branch: \$(git branch --show-current 2>/dev/null || echo detached)"
		fi
	fi

	git submodule sync --recursive
	if [ "${DEV:-}" = "" ] ; then
		git submodule update --init --recursive --force
	else
		git submodule update --init --recursive
	fi

	git branch
	git tag -l | sort -V | tail -10
	git tag -l > /saunafs/tags
	tag=\$(git describe --tags --abbrev=0 2>/dev/null || true)
	if [ -z "\${tag}" ] ; then
		tag=\$(sort -V /saunafs/tags | egrep -iv 'rc|donotuse|-|vv' | tail -1 || true)
	fi
	if [ -z "\${tag}" ] ; then
		tag=\$(printf '%s\n' "\${REPO_BRANCH}" | grep -oE 'v[0-9]+(\\.[0-9]+)+' | head -1 || true)
	fi
	if [ -z "\${tag}" ] ; then
		echo "[-] Could not determine a version tag from git tags or branch name"
		exit 1
	fi
		echo "[+] latest version tag \${tag}"
		echo "\${tag}" > /saunafs/tag_curr
	}

	prepare_repo
	if [ -f /tmp/saunafs-local-worktree.patch ] ; then
		echo "[+] Applying local worktree patch"
		git apply --3way --whitespace=nowarn --binary /tmp/saunafs-local-worktree.patch
	fi
	# if [ "$DISTRO" = "ubuntu" ] && [ "$VERSION" = "20.04" ] ; then
	# 	# Temporary boost 1.86.0 manifest fix until upstream includes the missing components.
	# 	if ! grep -q '"boost-format"' /saunafs/git/vcpkg.json ; then
# 		sed -i 's/   "prometheus-cpp"/"prometheus-cpp",\\
#     "boost-mp11",\\
#     "boost-format"/' /saunafs/git/vcpkg.json
# 		perl -0pi -e 's/(\{\n      "name": "boost-mp11",\n      "version": "1.86.0"\n    },\n)/$1    {\n      "name": "boost-format",\n      "version": "1.86.0"\n    },\n/' /saunafs/git/vcpkg.json
# 	fi
# fi
echo \$tag > /saunafs/tag_curr
export VCPKG_ROOT=/opt/vcpkg
export VCPKG_REVISION="\$(git -C /saunafs/git submodule status vcpkg | awk '{print \$1}')"
if [ -z "\${VCPKG_REVISION}" ] ; then
	echo "[-] Could not determine the pinned vcpkg revision from the source checkout"
	exit 1
fi

prepare_vcpkg_root() {
	if [ ! -d "\${VCPKG_ROOT}/.git" ] ; then
		rm -rf "\${VCPKG_ROOT}"
		git clone https://github.com/microsoft/vcpkg.git "\${VCPKG_ROOT}"
	fi

	current_revision="\$(git -C "\${VCPKG_ROOT}" rev-parse HEAD 2>/dev/null || true)"
	if [ "\${current_revision}" != "\${VCPKG_REVISION}" ] ; then
		if ! git -C "\${VCPKG_ROOT}" rev-parse --verify --quiet "\${VCPKG_REVISION}^{commit}" >/dev/null ; then
			git -C "\${VCPKG_ROOT}" fetch origin --tags --prune
		fi
		git -C "\${VCPKG_ROOT}" checkout --force "\${VCPKG_REVISION}"
		(
			cd "\${VCPKG_ROOT}"
			./bootstrap-vcpkg.sh -disableMetrics
		)
	elif [ ! -x "\${VCPKG_ROOT}/vcpkg" ] ; then
		(
			cd "\${VCPKG_ROOT}"
			./bootstrap-vcpkg.sh -disableMetrics
		)
	fi
}

prepare_vcpkg_root

if [ "$DEV" == "" ] ; then
	"\${VCPKG_ROOT}/vcpkg" install
	./tests/ci_build/run-build.sh release
fi
mkdir -p /installed/usr/
rm -rf /installed/opt/vcpkg
if [ "$DEV" != "" ] ; then
	if [ ! -f build/saunafs-release/CMakeCache.txt ] ; then
		echo "[-] Missing build/saunafs-release/CMakeCache.txt"
		echo "[-] Run 'make build' once after a clean/nuke before using 'make build_dev'"
		exit 1
	fi
	cmake -S /saunafs/git -B build/saunafs-release -DASCIIDOCTOR_AUTO_SETUP=OFF -DASCIIDOCTOR_BINARY=/usr/bin/asciidoctor
	cmake --build build/saunafs-release ${BUILD_PARALLEL_ARG} &&
	env DESTDIR=/installed cmake --install build/saunafs-release || exit -1
elif [ "$DISTRO" = "ubuntu" ] && [ "$VERSION" = "20.04" ] ; then
	cmake --build build/saunafs-release ${BUILD_PARALLEL_ARG} &&
	env DESTDIR=/installed cmake --install build/saunafs-release
else
	cmake -DCMAKE_INSTALL_PREFIX=/ -DASCIIDOCTOR_AUTO_SETUP=OFF -DASCIIDOCTOR_BINARY=/usr/bin/asciidoctor build/saunafs-release  && (\
	cmake --build build/saunafs-release ${BUILD_PARALLEL_ARG} &&
	env DESTDIR=/installed cmake --install build/saunafs-release ) || exit -1
fi
#mv  /installed/usr/etc /installed/
#mv  /installed/usr/var /installed/
mkdir -p /installed/etc/saunafs
mkdir -p /installed/usr/lib/systemd/system/
find ./ -name "*.cfg" | while read p ; do cp \$p /installed/etc/saunafs/\$(basename \$p).dist ; done
find ./ -name "*.service" | while read p ; do cp \$p /installed/usr/lib/systemd/system/ ; done
if [ -f /service-files/saunafs-uraft-elector.service ] ; then
	cp /service-files/saunafs-uraft-elector.service /installed/usr/lib/systemd/system/
fi
EOF

chmod a+x $TMPDIR_BUILD/$DISTRO$VERSION-saunafs-build.sh

if [ ! -e ./$DISTRO$VERSION-installed/usr/bin/saunafs ] || [ "$FORCE" != "" ] ; then
  docker run "${DOCKER_RUN_ARGS[@]}" \
    -v "$(pwd)/$DISTRO$VERSION-build:/saunafs/" \
    -v "$(pwd)/$DISTRO$VERSION-build/opt:/opt/" \
    -v "$(pwd)/$DISTRO$VERSION-installed:/installed/" \
    -v "$(pwd)/service-files:/service-files:ro" \
    -v "${VCPKG_ARCHIVE_CACHE_DIR}:/root/.cache/vcpkg/archives" \
    -v "$TMPDIR_BUILD/$DISTRO$VERSION-saunafs-build.sh:/tmp/saunafs-build.sh" \
    "${IMAGE_NAME}" /bin/bash /tmp/saunafs-build.sh

  docker_status=$?
  if [ $docker_status -ne 0 ] ; then
    exit $docker_status
  fi
fi
rm -rf $TMPDIR_BUILD
echo "[+] Installed files have been copied.  Preparing Debian package..."

[ ! -e ./$DISTRO$VERSION-build/tag_curr ] && ( echo "don't know the tag!" ; exit -1 )

# Build a simple .deb package from the contents of the installed folder.
# We use the same Docker image to create the package so that all
# packaging tools (dpkg-deb) are available.  The resulting .deb file
# will be written into the current working directory.  You can adjust
# PKG_VERSION and PKG_NAME below to match your packaging preferences.

PKG_NAME="saunafs"
PKG_VERSION=$(cat ./$DISTRO$VERSION-build/tag_curr | sed 's/v//')
DEB_FILE="${PKG_NAME}_$DISTRO${DEBIAN}_${PKG_VERSION}_amd64${DEV}.deb"
PKG_DEPENDS="libyaml-cpp-dev, libcrcutil-dev, libisal-dev, libjudy-dev, sudo, python3, bash-completion, arping $DEPENDS"

echo "[+] DEB_FILE=$DEB_FILE"

mkdir -p ./$DISTRO$VERSION-installed/DEBIAN
cat > ./$DISTRO$VERSION-installed/DEBIAN/control << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: admin
Priority: optional
Architecture: amd64
Maintainer: SaunaFS Maintainer <maintainer@example.com>
Description: SaunaFS built from source
Depends: $PKG_DEPENDS
EOF

cat > ./$DISTRO$VERSION-installed/DEBIAN/postinst << EOF
#!/bin/sh
SUDO_URAFT_FILE=/etc/sudoers.d/saunafs-uraft
set -e
case "\${1}" in
	configure)
		if ! getent passwd saunafs > /dev/null 2>&1
		then
			adduser --quiet --system --group --no-create-home --home /var/lib/saunafs saunafs
		fi
		echo "# Allow saunafs user to set floating ip" > \$SUDO_URAFT_FILE
		echo "saunafs\tALL=NOPASSWD:/sbin/ip" >> \$SUDO_URAFT_FILE
		;;
	abort-upgrade|abort-remove|abort-deconfigure)
		;;
	*)
		echo "postinst called with unknown argument \\\`\${1}'" >&2
		exit 1
		;;
esac
#DEBHELPER#
exit 0
EOF
chmod a+x ./$DISTRO$VERSION-installed/DEBIAN/postinst


docker run --rm \
  -v "$(pwd)/$DISTRO$VERSION-installed:/tmp_folder/:ro" \
  -v "$(pwd):/out" \
  "${IMAGE_NAME}" \
  bash -c "\
    set -euo pipefail; \
    dpkg-deb --build /tmp_folder/ /out/${DEB_FILE}; \
  "

echo "[+] Done!  The installed files are in the 'installed' directory and the Debian package is saved as ${DEB_FILE}."
