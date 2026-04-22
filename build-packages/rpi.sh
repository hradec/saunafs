#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${RPI_SOURCE_DIR:-${SCRIPT_DIR}/..}"
BUILD_DIR="${RPI_BUILD_FOLDER:-${SCRIPT_DIR}/../rpi-build}"
INSTALL_DIR="${RPI_INSTALL_FOLDER:-${SCRIPT_DIR}/../rpi-installed}"
IMAGE_NAME="${RPI_IMAGE_NAME:-saunafs-rpi-builder:debian13-arm64}"
PLATFORM="${RPI_PLATFORM:-linux/arm64}"
DOCKERFILE="${RPI_DOCKERFILE:-${SCRIPT_DIR}/Dockerfile.debian13}"
CONTEXT_DIR="${RPI_CONTEXT_DIR:-${SCRIPT_DIR}}"
SERVICE_NAME="${RPI_SERVICE_NAME:-saunafs-uraft-elector.service}"
VCPKG_TRIPLET="${RPI_VCPKG_TRIPLET:-arm64-linux}"
VCPKG_ARCHIVE_CACHE_DIR="${VCPKG_ARCHIVE_CACHE_DIR:-${BUILD_DIR}/vcpkg-archives}"
BUILD_JOBS="${BUILD_JOBS:-1}"
DOCKER_RUN_ARGS=(--rm -ti --platform "${PLATFORM}")

if [ -n "${DOCKER_RUN_CPUS:-}" ] ; then
	DOCKER_RUN_ARGS+=(--cpus "${DOCKER_RUN_CPUS}")
fi
if [ -n "${DOCKER_RUN_MEMORY:-}" ] ; then
	DOCKER_RUN_ARGS+=(--memory "${DOCKER_RUN_MEMORY}")
fi
if [ -n "${DOCKER_RUN_MEMORY_SWAP:-}" ] ; then
	DOCKER_RUN_ARGS+=(--memory-swap "${DOCKER_RUN_MEMORY_SWAP}")
fi

GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
GIT_BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD)"

mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${VCPKG_ARCHIVE_CACHE_DIR}"
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
	echo "[+] Building arm64 Docker image ${IMAGE_NAME}"
	docker buildx build --platform "${PLATFORM}" --load --progress=plain -t "${IMAGE_NAME}" -f "${DOCKERFILE}" "${CONTEXT_DIR}"
fi

echo "[+] Building saunafs-uraft for ${PLATFORM}"
docker run "${DOCKER_RUN_ARGS[@]}" \
	-e BUILD_JOBS="${BUILD_JOBS}" \
	-e GIT_COMMIT="${GIT_COMMIT}" \
	-e GIT_BRANCH="${GIT_BRANCH}" \
	-e SERVICE_NAME="${SERVICE_NAME}" \
	-e VCPKG_TRIPLET="${VCPKG_TRIPLET}" \
	-v "${ROOT_DIR}:/src:ro" \
	-v "${BUILD_DIR}:/build" \
	-v "${INSTALL_DIR}:/install" \
	-v "${VCPKG_ARCHIVE_CACHE_DIR}:/root/.cache/vcpkg/archives" \
	"${IMAGE_NAME}" \
	bash -lc '
		set -euo pipefail

		VCPKG_SOURCE=/src/vcpkg
		VCPKG_ROOT=/build/vcpkg

		prepare_vcpkg_root() {
			local source_revision
			git config --global --add safe.directory "${VCPKG_SOURCE}"
			source_revision="$(git -C "${VCPKG_SOURCE}" rev-parse HEAD)"
			if [ ! -x "${VCPKG_ROOT}/vcpkg" ] || [ ! -d "${VCPKG_ROOT}/.git" ] || [ ! -f "${VCPKG_ROOT}/.rpi-vcpkg-revision" ] || [ "$(cat "${VCPKG_ROOT}/.rpi-vcpkg-revision")" != "${source_revision}" ]; then
				rm -rf "${VCPKG_ROOT}"
				git clone https://github.com/microsoft/vcpkg.git "${VCPKG_ROOT}"
				(
					cd "${VCPKG_ROOT}"
					git checkout --force "${source_revision}"
				)
				(
					cd "${VCPKG_ROOT}"
					./bootstrap-vcpkg.sh -disableMetrics
				)
				printf "%s\n" "${source_revision}" > "${VCPKG_ROOT}/.rpi-vcpkg-revision"
			fi
		}

		prepare_vcpkg_root

		cmake -S /src -B /build \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=/ \
			-DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
			-DVCPKG_TARGET_TRIPLET="${VCPKG_TRIPLET}" \
			-DVCPKG_HOST_TRIPLET="${VCPKG_TRIPLET}" \
			-DENABLE_URAFT=ON \
			-DENABLE_DOCS=OFF \
			-DENABLE_TESTS=OFF \
			-DENABLE_UTILS=OFF \
			-DENABLE_CLIENT_LIB=OFF \
			-DENABLE_PROMETHEUS=OFF \
			-DENABLE_FOUNDATIONDB=OFF \
			-DENABLE_NFS_GANESHA=OFF \
			-DASCIIDOCTOR_AUTO_SETUP=OFF \
			-DGIT_COMMIT="${GIT_COMMIT}" \
			-DGIT_BRANCH="${GIT_BRANCH}" \
			-DGENERATE_GIT_INFO=OFF

		cmake --build /build --target saunafs-uraft --parallel "${BUILD_JOBS}"

		install -Dm755 /build/src/uraft/saunafs-uraft "/install/usr/sbin/saunafs-uraft"
		install -Dm755 /build/src/uraft/saunafs-uraft-helper "/install/usr/sbin/saunafs-uraft-helper"
		install -Dm644 /src/build-packages/service-files/saunafs-uraft-elector.service "/install/usr/lib/systemd/system/${SERVICE_NAME}"
	'

echo "[+] Staged files under ${INSTALL_DIR}"
echo "[+] Binary: ${INSTALL_DIR}/usr/sbin/saunafs-uraft"
echo "[+] Unit:   ${INSTALL_DIR}/usr/lib/systemd/system/${SERVICE_NAME}"
