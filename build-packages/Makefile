
VERSION:=13
DISTRO:=debian
#VERSION:=24.04
#DISTRO:=ubuntu

SAUNAFS_REPO_URL?=https://github.com/hradec/saunafs.git

#SAUNAFS_REPO_BRANCH?=v5.8.0-wan-fixes
SAUNAFS_REPO_BRANCH?=v5.8.0-asesso
SAUNAFS_VERSION?=5.8.0

FORCE"=""
TMP_BUILD_FOLDER=/NVME/$(DISTRO)$(VERSION)-build
BUILD_JOBS?=8
DOCKER_RUN_CPUS?=8
DOCKER_RUN_MEMORY?=
DOCKER_RUN_MEMORY_SWAP?=
VCPKG_ARCHIVE_CACHE_DIR?=$(TMP_BUILD_FOLDER)/vcpkg-archives
RPI_BUILD_FOLDER?=$(TMP_BUILD_FOLDER)/rpi
RPI_INSTALL_FOLDER?=$(CD)/rpi-installed
RPI_IMAGE_NAME?=saunafs-rpi-builder:debian13-arm64
RPI_PLATFORM?=linux/arm64
RPI_SERVICE_NAME?=saunafs-uraft-elector.service
RPI_VCPKG_TRIPLET?=arm64-linux
SAUNAFS_REPO_DIR?=$(CD)/../saunafs
SAUNAFS_SYNC_LOCAL_WORKTREE?=

SHELL := /bin/bash
CD:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

TMP_INSTALL_FOLDER=$(CD)/$(DISTRO)$(VERSION)-installed

export FORCE BUILD_JOBS DOCKER_RUN_CPUS DOCKER_RUN_MEMORY DOCKER_RUN_MEMORY_SWAP VCPKG_ARCHIVE_CACHE_DIR
export RPI_BUILD_FOLDER RPI_INSTALL_FOLDER RPI_IMAGE_NAME RPI_PLATFORM RPI_SERVICE_NAME RPI_VCPKG_TRIPLET
export SAUNAFS_REPO_DIR SAUNAFS_SYNC_LOCAL_WORKTREE SAUNAFS_REPO_URL SAUNAFS_REPO_BRANCH
help:
	@echo ""
	@echo "make build	- build debian package from configured repo/branch with a clean checkout"
	@echo "make build_dev	- rebuild existing configured tree quickly and apply the local git worktree patch"
	@echo "make rpi	- build saunafs-uraft and the elector-only service for arm64"
	@echo "make clean	- cleanup install folder"
	@echo "make nuke	- cleanup everything"
	@echo "make rpi_clean	- cleanup rpi install folder and symlink"
	@echo "make rpi_nuke	- cleanup rpi build and install folders"
	@echo "make uraft_install	- install uraft service"

	@echo ""
	@echo "Optional limits:"
	@echo "  BUILD_JOBS=8"
	@echo "  DOCKER_RUN_CPUS=8"
	@echo "  DOCKER_RUN_MEMORY=16g"
	@echo "  DOCKER_RUN_MEMORY_SWAP=16g"
	@echo "  VCPKG_ARCHIVE_CACHE_DIR=$(TMP_BUILD_FOLDER)/vcpkg-archives"
	@echo "  RPI_BUILD_FOLDER=$(RPI_BUILD_FOLDER)"
	@echo "  RPI_INSTALL_FOLDER=$(RPI_INSTALL_FOLDER)"
	@echo "  RPI_IMAGE_NAME=$(RPI_IMAGE_NAME)"
	@echo "  RPI_PLATFORM=$(RPI_PLATFORM)"
	@echo "  RPI_VCPKG_TRIPLET=$(RPI_VCPKG_TRIPLET)"
	@echo ""
	@echo "Source checkout:"
	@echo "  SAUNAFS_REPO_DIR=$(SAUNAFS_REPO_DIR)"
	@echo "  SAUNAFS_REPO_URL=$(SAUNAFS_REPO_URL)"
	@echo "  SAUNAFS_REPO_BRANCH=$(SAUNAFS_REPO_BRANCH)"
	@echo "  SAUNAFS_SYNC_LOCAL_WORKTREE=1 (apply local worktree changes into the build)"
	@echo ""
	@echo "Example:"
	@echo "  make build_dev BUILD_JOBS=8"
	@echo "  make build SAUNAFS_SYNC_LOCAL_WORKTREE=1"
	@echo "  make rpi BUILD_JOBS=8"
	@echo ""
	@echo "DISTRO=$(DISTRO)"
	@echo "VERSION=$(VERSION)"
	@echo ""

# force the use of one shell for all shell lines, instead of one shell per line.
.ONESHELL:
.SHELL = /bin/bash

all: help

.PHONY: rpi rpi_clean rpi_nuke

build:
	cd ${CD}
	export DISTRO=$(DISTRO)
	export $${DISTRO^^}=$(VERSION)
	export DEBIAN=$(VERSION)
	export VERSION=$(VERSION)
	mkdir -p $(TMP_BUILD_FOLDER)/
	#rm -rf ./$$(basename $(TMP_BUILD_FOLDER))
	[ ! -e $$(basename $(TMP_BUILD_FOLDER)) ] && ln -s $(TMP_BUILD_FOLDER) ./$$(basename $(TMP_BUILD_FOLDER))
	sudo rm -rf $(TMP_INSTALL_FOLDER)/usr/bin/saunafs
	./debian.sh

build_dev:
	cd ${CD}
	export DISTRO=$(DISTRO)
	export $${DISTRO^^}=$(VERSION)
	export DEBIAN=$(VERSION)
	export VERSION=$(VERSION)
	export DEV="_dev"
	if [ -z "$${SAUNAFS_SYNC_LOCAL_WORKTREE:-}" ] ; then export SAUNAFS_SYNC_LOCAL_WORKTREE=1 ; fi
	mkdir -p $(TMP_BUILD_FOLDER)/
	[ ! -e $$(basename $(TMP_BUILD_FOLDER)) ] && ln -s $(TMP_BUILD_FOLDER) ./$$(basename $(TMP_BUILD_FOLDER))
	sudo rm -rf $(TMP_INSTALL_FOLDER)/usr/bin/saunafs
	./debian.sh

rpi:
	cd ${CD}
	mkdir -p $(RPI_BUILD_FOLDER)
	ln -sfn $(RPI_BUILD_FOLDER) ./$$(basename $(RPI_BUILD_FOLDER))
	sudo rm -rf $(RPI_INSTALL_FOLDER)
	./rpi.sh

install:
	sudo rsync -avpP $(CD)/saunafs_$(DISTRO)$(VERSION)_$(SAUNAFS_VERSION)*.deb  /SAUNAFS/.install/saunafs/

uraft_install: install
	if [ "$(DISTRO)" == "debian" ] && [ "$(VERSION)" == "12" ] ; then
		for n in 240.0.0.27 240.0.1.1 240.1.1.1 ; do
		echo "Installing on $$n"
			ssh root@$$n 'apt reinstall -y /SAUNAFS/.install/saunafs/saunafs_$(DISTRO)$(VERSION)_$(SAUNAFS_VERSION)_amd64_dev.deb ; systemctl daemon-reload'
		done
	fi
	if [ "$(DISTRO)" == "debian" ] && [ "$(VERSION)" == "13" ] ; then 
		for n in 240.0.0.70 240.1.0.69 240.0.0.10 240.0.0.240 ; do 
			echo "Installing on $$n"
			ssh root@$$n 'apt reinstall -y /SAUNAFS/.install/saunafs/saunafs_$(DISTRO)$(VERSION)_$(SAUNAFS_VERSION)_amd64_dev.deb ; systemctl daemon-reload' 
		done 
	fi
	if [ "$(DISTRO)" == "UBUNTU" ] && [ "$(VERSION)" == "24.04" ] ; then 
		for n in ubuntu@240.10.0.11 ; do 
			echo "Installing on $$n"
			ssh $$n 'sudo apt reinstall -y /SAUNAFS/.install/saunafs/saunafs_$(DISTRO)$(VERSION)_$(SAUNAFS_VERSION)_amd64_dev.deb ; systemctl daemon-reload' 
		done 
	fi

clean:
	sudo rm -rf ./$(DISTRO)$(VERSION)-installed
	sudo rm -rf ./$(DISTRO)$(VERSION)-build/git
	sudo rm -rf ./$(DISTRO)$(VERSION)-build/tag*

nuke: clean
	sudo rm -rf ./$(DISTRO)$(VERSION)-build

rpi_clean:
	sudo rm -rf $(RPI_INSTALL_FOLDER)
	rm -f ./$$(basename $(RPI_BUILD_FOLDER))

rpi_nuke: rpi_clean
	rm -rf $(RPI_BUILD_FOLDER)
