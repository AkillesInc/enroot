# Copyright (c) 2018-2019, NVIDIA CORPORATION. All rights reserved.

# shellcheck disable=SC2148,SC2015

[ -v _COMMON_SH_ ] && return || readonly _COMMON_SH_=1

[ -t 2 ] && readonly TTY_ON=y || readonly TTY_OFF=y

if [ -v TTY_ON ]; then
    if [ -x "$(command -v tput)" ] && [ "$(tput colors)" -ge 15 ]; then
        readonly clr=$(tput sgr0)
        readonly bold=$(tput bold)
        readonly red=$(tput setaf 1)
        readonly green=$(tput setaf 2)
        readonly yellow=$(tput setaf 3)
        readonly blue=$(tput setaf 12)
    fi
fi

common::fmt() {
    local -r fmt="$1"
    local -r str="$2"

    printf "%s%s%s" "${!fmt-}" "${str}" "${clr-}"
}

common::log() {
    local -r lvl="${1-}"
    local -r msg="${2-}"
    local -r mod="${3-}"

    local prefix=""

    if [ -n "${msg}" ]; then
        case "${lvl}" in
            INFO)  prefix=$(common::fmt blue "[INFO]") ;;
            WARN)  prefix=$(common::fmt yellow "[WARN]") ;;
            ERROR) prefix=$(common::fmt red "[ERROR]") ;;
        esac
        if [ "${msg}" = "-" ]; then
            while read -t .01 -r line; do
                printf "%s %b\n" "${prefix}" "${line}" >&2
            done
        else
            printf "%s %b\n" "${prefix}" "${msg}" >&2
        fi
    fi
    if [ -v TTY_ON ]; then
        if [ $# -eq 0 ] || [ "${mod}" = "NL" ]; then
            echo >&2
        fi
    fi
}

common::err() {
    local -r msg="$1"

    common::log ERROR "${msg}"
    exit 1
}

common::rmall() {
    local -r path="$1"

    rm --one-file-system --preserve-root -rf "${path}" 2> /dev/null || \
    { chmod -f -R +w "${path}"; rm --one-file-system --preserve-root -rf "${path}"; }
}

common::mktmpdir() {
    local -r prefix="$1"

    umask 077
    mktemp -d -p "${ENROOT_TEMP_PATH-}" "${prefix}.XXXXXXXXXX"
}

common::read() {
    # shellcheck disable=SC2162
    read "$@" || :
}

common::chdir() {
    cd "$1" 2> /dev/null || common::err "Could not change directory: $1"
}

common::curl() {
    local -i rv=0
    local -i status=0

    exec {stdout}>&1
    { status=$(curl -o "/proc/self/fd/${stdout}" -w '%{http_code}' "$@") || rv=$?; } {stdout}>&1
    exec {stdout}>&-

    if [ "${status}" -ge 400 ]; then
        for ign in ${CURL_IGNORE-}; do
            [ "${status}" -eq "${ign}" ] && return
        done
        # shellcheck disable=SC2145
        common::err "URL ${@: -1} returned error code: ${status}"
    fi
    return ${rv}
}

common::realpath() {
    local -r path="$1"

    local rpath=""

    if ! rpath=$(readlink -f "${path}" 2> /dev/null); then
        common::err "No such file or directory: ${path}"
    fi
    printf "%s" "${rpath}"
}

common::envsubst() {
    local -r file="$1"

    awk '{
        line=$0
        while (match(line, /\${[A-Za-z_][A-Za-z0-9_]*}/)) {
            output = substr(line, 1, RSTART - 1)
            envvar = substr(line, RSTART, RLENGTH)

            gsub(/\$|{|}/, "", envvar)
            printf "%s%s", output, ENVIRON[envvar]

            line = substr(line, RSTART + RLENGTH)
        }
        print line
    }' "${file}"
}

common::envfmt() {
    local -r file="$1"

    # Remove leading spaces.
    # Remove comments and empty lines.
    # Remove ill-formed environment variables.
    # Remove reserved environment variables.
    # Remove surrounding quotes.
    sed -i -e 's/^[[:space:]]\+//' \
      -e '/^#\|^$/d' \
      -e '/^[[:alpha:]_][[:alnum:]_]*=/!d' \
      -e '/^ENROOT_/d' \
      -e 's/^\([[:alpha:]_][[:alnum:]_]*\)=[\"\x27]\(.*\)[\"\x27][[:space:]]*$/\1=\2/' \
      "${file}"
}

common::runparts() {
    local -r action="$1"
    local -r suffix="$2"
    local -r dir="$3"

    shopt -s nullglob
    for file in "${dir}"/*"${suffix}"; do
        case "${action}" in
        list)
            printf "%s\n" "${file}" ;;
        exec)
            if [ -x "${file}" ]; then
                "${file}" || common::err "${file} exited with return code $?"
            fi
            ;;
        esac
    done
    shopt -u nullglob
}

common::checkcmd() {
    for cmd in "$@"; do
        command -v "${cmd}" > /dev/null || common::err "Command not found: ${cmd}"
    done
}

common::fixperms() {
    local -r path="$1"

    # Some distributions require CAP_DAC_OVERRIDE on several files and directories, fix these.
    # See https://bugzilla.redhat.com/show_bug.cgi?id=517575 for some context.
    find "${path}" -maxdepth 5 \( -type d ! -perm -u+w -exec chmod -f u+w {} \+ \) -o \( ! -perm -u+r -exec chmod -f u+r {} \+ \)
}

common::getpwent() {
    local uid=""

    read -r x uid x < /proc/self/uid_map
    getent passwd "${uid}"
}

common::getgrent() {
    local gid=""

    # shellcheck disable=SC2034
    read -r x gid x < /proc/self/gid_map
    getent group "${gid}"
}
