#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

source "${ENROOT_LIBEXEC_PATH}/common.sh"

cli_args=("--no-cgroups" "--ldconfig=@$(command -v ldconfig.real || command -v ldconfig)")

# https://github.com/nvidia/nvidia-container-runtime#nvidia_visible_devices
if [ -z "${NVIDIA_VISIBLE_DEVICES-}" ] || [ "${NVIDIA_VISIBLE_DEVICES-}" = "void" ]; then
    exit 0
fi
if [ "${NVIDIA_VISIBLE_DEVICES}" != "none" ]; then
    cli_args+=("--device=${NVIDIA_VISIBLE_DEVICES}")
fi

# https://github.com/nvidia/nvidia-container-runtime#nvidia_driver_capabilities
if [ -z "${NVIDIA_DRIVER_CAPABILITIES-}" ]; then
    NVIDIA_DRIVER_CAPABILITIES="utility"
fi
for cap in ${NVIDIA_DRIVER_CAPABILITIES//,/ }; do
    case "${cap}" in
    all)
        cli_args+=("--compute" "--compat32" "--display" "--graphics" "--utility" "--video")
        break
        ;;
    compute|compat32|display|graphics|utility|video)
        cli_args+=("--${cap}") ;;
    *)
        common::err "Unknown NVIDIA driver capability: ${cap}" ;;
    esac
done

# https://github.com/nvidia/nvidia-container-runtime#nvidia_require_
if [ -z "${NVIDIA_DISABLE_REQUIRE:-}" ]; then
    for req in $(compgen -e "NVIDIA_REQUIRE_"); do
        cli_args+=("--require=${!req}")
    done
fi

if ! command -v nvidia-container-cli > /dev/null; then
    common::err "Command not found: nvidia-container-cli, see https://github.com/NVIDIA/libnvidia-container"
fi
if ! grep -q nvidia_uvm /proc/modules; then
    common::log WARN "Kernel module nvidia_uvm is not loaded. Make sure the NVIDIA device driver is installed and loaded."
fi

exec nvidia-container-cli --user ${NVIDIA_DEBUG_LOG+--debug=/dev/stderr} configure "${cli_args[@]}" "${ENROOT_ROOTFS}"
