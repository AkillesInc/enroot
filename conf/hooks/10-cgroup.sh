#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

mount_cgroup() {
    local -r line="$1"

    local ctrl=""
    local path=""
    local mtab=""
    local root=""
    local mount=""

    IFS=':' read -r x ctrl path <<< "${line}"
    if [ -n "${ctrl}" ]; then
        mtab=$(grep -m1 "\- cgroup cgroup [^ ]*${ctrl}" /proc/self/mountinfo || :)
    else
        mtab=$(grep -m1 "\- cgroup2 cgroup" /proc/self/mountinfo || :)
    fi
    if [ -z "${mtab}" ]; then
        return
    fi
    IFS=' ' read -r x x x root mount x <<< "${mtab}"

    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" - <<< \
      "${mount}/${path#${root}} ${mount} none x-create=dir,bind,nosuid,noexec,nodev,ro"
}

while read -r line; do
    mount_cgroup "${line}"
done < /proc/self/cgroup

"${ENROOT_LIBEXEC_PATH}/mountat" --root "${ENROOT_ROOTFS}" - <<< \
  "none /sys/fs/cgroup none bind,remount,nosuid,noexec,nodev,ro"
