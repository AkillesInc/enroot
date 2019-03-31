# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

readonly hook_dirs=("${ENROOT_SYSCONF_PATH}/hooks.d" "${ENROOT_CONFIG_PATH}/hooks.d")
readonly mount_dirs=("${ENROOT_SYSCONF_PATH}/mounts.d" "${ENROOT_CONFIG_PATH}/mounts.d")
readonly environ_dirs=("${ENROOT_SYSCONF_PATH}/environ.d" "${ENROOT_CONFIG_PATH}/environ.d")
readonly environ_file="${ENROOT_RUNTIME_PATH}/environment"

readonly bundle_dir="/.enroot"
readonly bundle_libexec_dir="${bundle_dir}/libexec"
readonly bundle_sysconf_dir="${bundle_dir}/etc/system"
readonly bundle_usrconf_dir="${bundle_dir}/etc/user"

runtime::_do_mounts() {
    local -r rootfs="$1"

    # Generate the mount configuration files.
    ln -s "${rootfs}/etc/fstab" "${ENROOT_RUNTIME_PATH}/00-rootfs.fstab"
    for dir in "${mount_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.fstab' -exec ln -s "{}" "${ENROOT_RUNTIME_PATH}" \;
        fi
    done
    if declare -F mounts > /dev/null; then
        mounts > "${ENROOT_RUNTIME_PATH}/99-config.fstab"
    fi

    # Perform all the mounts specified in the configuration files.
    "${ENROOT_LIBEXEC_PATH}/mountat" --root "${rootfs}" "${ENROOT_RUNTIME_PATH}"/*.fstab
}

runtime::_do_environ() {
    local -r rootfs="$1"

    local envsubst=""

    read -r -d '' envsubst <<- 'EOF' || :
	function envsubst(key, val) {
	    printf key
	    while (match(val, /\$(([A-Za-z_][A-Za-z0-9_]*)|{([A-Za-z_][A-Za-z0-9_]*)})/)) {
	        env = substr(val, RSTART, RLENGTH); gsub(/\$|{|}/, "", env)
	        printf "%s%s", substr(val, 1, RSTART - 1), ENVIRON[env]
	        val = substr(val, RSTART + RLENGTH)
	    }
	    print val
	}
	BEGIN {FS="="; OFS=FS} { key=$1; $1=""; envsubst(key, $0) }
	EOF

    # Generate the environment configuration file.
    awk "${envsubst}" "${rootfs}/etc/environment" >> "${environ_file}"
    for dir in "${environ_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -name '*.env' -exec awk "${envsubst}" "{}" \; >> "${environ_file}"
        fi
    done
    if declare -F environ > /dev/null; then
        environ | { grep -vE "^ENROOT_" || :; } >> "${environ_file}"
    fi
}

runtime::_do_hooks() {
    local -r rootfs="$1"

    local -r pattern="(PATH|ENV|TERM|LD_.+|LC_.+|ENROOT_.+)"

    export ENROOT_PID="$$"
    export ENROOT_ROOTFS="${rootfs}"
    export ENROOT_ENVIRON="${environ_file}"

    # Execute the hooks with the environment from the container in addition with the variables defined above.
    # Exclude anything which could affect the proper execution of the hook (e.g. search path, linker, locale).
    unset $(env -0 | sed -z 's/=.*/\n/;s/^BASH_FUNC_\(.\+\)%%/\1/' | tr -d '\000' | { grep -vE "^${pattern}$" || :; })
    while read -r var; do
        if [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ && ! "${var}" =~ ^${pattern}= ]]; then
            export "${var}"
        fi
    done < "${environ_file}"

    for dir in "${hook_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            find "${dir}" -type f -executable -name '*.sh' -exec "{}" \;
        fi
    done
    if declare -F hooks > /dev/null; then
        hooks > /dev/null
    fi
}

runtime::_start() {
    local -r rootfs="$1"; shift
    local -r config="$1"; shift

    unset BASH_ENV

    # Setup the rootfs with slave propagation.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs} ${rootfs} none bind,nosuid,nodev,slave"

    # Setup a temporary working directory.
    "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "tmpfs ${ENROOT_RUNTIME_PATH} tmpfs x-create=dir,mode=600"

    # Configure the container by performing mounts, setting its environment and executing hooks.
    (
        if [ -n "${config}" ]; then
            source "${config}"
        fi
        runtime::_do_mounts "${rootfs}"
        runtime::_do_environ "${rootfs}"
        runtime::_do_hooks "${rootfs}"
    )

    # Remount the rootfs readonly if necessary.
    if [ -z "${ENROOT_ROOTFS_RW}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "none ${rootfs} none remount,bind,nosuid,nodev,ro"
    fi

    # Make the bundle directory readonly if present.
    if [ -d "${rootfs}${bundle_dir}" ]; then
        "${ENROOT_LIBEXEC_PATH}/mountat" - <<< "${rootfs}${bundle_dir} ${rootfs}${bundle_dir} none rbind,nosuid,nodev,ro"
    fi

    # Switch to the new root, and invoke the init script.
    if [ -n "${ENROOT_LOGIN_SHELL}" ]; then
        export SHELL="${ENROOT_LOGIN_SHELL}"
    fi
    exec 3< "${ENROOT_LIBEXEC_PATH}/init.sh"
    exec "${ENROOT_LIBEXEC_PATH}/switchroot" --env "${environ_file}" "${rootfs}" -3 "$@"
}

runtime::start() {
    local rootfs="$1"; shift
    local config="$1"; shift

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi

    # Resolve the container configuration path.
    if [ -n "${config}" ]; then
        config=$(common::realpath "${config}")
        if [ ! -f "${config}" ]; then
            common::err "No such file or directory: ${config}"
        fi
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec "${ENROOT_LIBEXEC_PATH}/unsharens" ${ENROOT_REMAP_ROOT:+--root} \
      "${BASH}" -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c 'runtime::_start "$@"' "${config}" "${rootfs}" "${config}" "$@"
}

runtime::create() {
    local image="$1"
    local rootfs="$2"

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi
    if ! unsquashfs -s "${image}" > /dev/null 2>&1; then
        common::err "Invalid image format: ${image}"
    fi

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        rootfs=$(basename "${image%.squashfs}")
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ -e "${rootfs}" ]; then
        common::err "File already exists: ${rootfs}"
    fi

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -d "${rootfs}" "${image}"

    # Some distributions require CAP_DAC_OVERRIDE on system directories, work around it
    # (see https://bugzilla.redhat.com/show_bug.cgi?id=517575)
    find "${rootfs}" "${rootfs}/usr" -maxdepth 1 -type d ! -perm -u+w -exec chmod u+w {} \+
}

runtime::import() {
    local -r uri="$1"
    local -r filename="$2"

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
}

runtime::export() {
    local rootfs="$1"
    local filename="$2"

    local excludeopt=""

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${rootfs}").squashfs"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Exclude the bundle directory.
    if [ -d "${rootfs}${bundle_dir}" ]; then
        excludeopt="-e ${rootfs}${bundle_dir}"
    fi

    # Export a container image from the rootfs specified.
    common::log INFO "Creating squashfs filesystem..." NL
    mksquashfs "${rootfs}" "${filename}" -all-root ${excludeopt} \
      ${TTY_OFF+-no-progress} ${ENROOT_SQUASH_OPTS}
}

runtime::list() {
    local fancy="$1"

    common::chdir "${ENROOT_DATA_PATH}"

    # List all the container rootfs along with their size.
    if [ -n "${fancy}" ]; then
        if [ -n "$(ls -A)" ]; then
            printf "%b\n" "$(common::fmt bold "SIZE\tIMAGE")"
            du -sh *
        fi
    else
        ls -1
    fi
}

runtime::remove() {
    local rootfs="$1"
    local force="$2"

    # Resolve the container rootfs path.
    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi

    # Remove the rootfs specified after asking for confirmation.
    if [ -z "${force}" ]; then
        read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    fi
    if [ -n "${force}" ] || [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        common::rmall "${rootfs}"
    fi
}

runtime::bundle() (
    local image="$1"
    local filename="$2"
    local target="$3"
    local desc="$4"

    local super=""
    local tmpdir=""
    local compress=""

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi
    if ! super=$(unsquashfs -s "${image}" 2> /dev/null); then
        common::err "Invalid image format: ${image}"
    fi

    # Generate an absolute filename if none was specified.
    if [ -z "${filename}" ]; then
        filename="$(basename "${image%.squashfs}").run"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        common::err "File already exists: ${filename}"
    fi

    # Generate a target directory if none was specified.
    if [ -z "${target}" ]; then
        target="$(basename "${filename%.run}")"
    fi

    # Use the filename as the description if none was specified.
    if [ -z "${desc}" ]; then
        desc="$(basename "${filename}")"
    fi

    # If the image data is compressed, reuse the same one for the bundle.
    if grep -q "^Data is compressed" <<< "${super}"; then
        compress=$(awk '/^Compression/ { print "--"$2 }' <<< "${super}")
    else
        compress="--nocomp"
    fi

    tmpdir=$(common::mktemp -d)
    trap "common::rmall '${tmpdir}' 2> /dev/null" EXIT

    # Extract the container rootfs from the image.
    common::log INFO "Extracting squashfs filesystem..." NL
    unsquashfs ${TTY_OFF+-no-progress} -user-xattrs -f -d "${tmpdir}" "${image}"
    common::log

    # Copy runtime components to the bundle directory.
    common::log INFO "Generating bundle..." NL
    mkdir -p "${tmpdir}${bundle_libexec_dir}" "${tmpdir}${bundle_sysconf_dir}" "${tmpdir}${bundle_usrconf_dir}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{unsharens,mountat,switchroot} "${tmpdir}${bundle_libexec_dir}"
    cp -a "${ENROOT_LIBEXEC_PATH}"/{common.sh,runtime.sh,init.sh} "${tmpdir}${bundle_libexec_dir}"

    # Copy runtime configurations to the bundle directory.
    cp -a "${hook_dirs[0]}" "${mount_dirs[0]}" "${environ_dirs[0]}" "${tmpdir}${bundle_sysconf_dir}"
    if [ -n "${ENROOT_BUNDLE_ALL}" ]; then
        [ -d "${hook_dirs[1]}" ] && cp -a "${hook_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${mount_dirs[1]}" ] && cp -a "${mount_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
        [ -d "${environ_dirs[1]}" ] && cp -a "${environ_dirs[1]}" "${tmpdir}${bundle_usrconf_dir}"
    fi

    # Make a self-extracting archive with the entrypoint being our bundle script.
    "${ENROOT_LIBEXEC_PATH}/makeself" --tar-quietly --tar-extra '--numeric-owner --owner=0 --group=0 --ignore-failed-read' \
      --nomd5 --nocrc ${ENROOT_BUNDLE_SUM:+--sha256} --header "${ENROOT_LIBEXEC_PATH}/bundle.sh" "${compress}" \
      --target "${target}" "${tmpdir}" "${filename}" "${desc}" -- "${bundle_libexec_dir}" "${bundle_sysconf_dir}" "${bundle_usrconf_dir}"
)
