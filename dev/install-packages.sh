#!/usr/bin/env bash
set -euo pipefail

# Installs the Fedora packages HayChat builds and tests against. Runs as root inside a
# Fedora 44 container: dev/Containerfile uses it to build the dev image, and the Forgejo CI
# job runs it in its job container, so both get the same toolchain.
#
# Usage: install-packages.sh [--gui]
#   --gui   also install the runtime pieces the client needs to open a window on a Wayland
#           or X11 display passed in from the host (`./dev.sh client`)

build_packages=(
	git-core
	clang
	llvm
	llvm-devel
	lld
	pkgconf-pkg-config
	libpq-devel
	# psql: dev/live-proof.sh loads the room fixture into its throwaway database.
	postgresql
	enet-devel
	SDL3-devel
	SDL3_ttf-devel
	# libopus.so.0, loaded at runtime by client/opus for voice; the voice tests need it.
	# Not opus-devel: the client never links libopus.
	opus
	# librnnoise.so.0, loaded at runtime by client/rnnoise for noise suppression (#170); the
	# noise suppression tests need it. Not rnnoise-devel: the client never links it.
	rnnoise
	libX11-devel
	# Global push-to-talk tests (client/hotkey): a private D-Bus daemon for the mock
	# GlobalShortcuts portal (libdbus-1.so.3 is loaded at runtime), and an Xvfb display with
	# XTest for the X11 key-state poller.
	dbus-libs
	dbus-daemon
	xorg-x11-server-Xvfb
	libXtst
	openssl-devel
	which
	findutils
	procps-ng
	tar
)

gui_packages=(
	mesa-dri-drivers
	libdecor
	dbus-libs
)

packages=("${build_packages[@]}")
for arg in "$@"; do
	case "$arg" in
		--gui) packages+=("${gui_packages[@]}") ;;
		*)
			echo "Unknown option: $arg" >&2
			exit 1
			;;
	esac
done

dnf install -y --setopt=install_weak_deps=False "${packages[@]}"
dnf clean all
