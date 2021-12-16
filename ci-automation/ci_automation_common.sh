#!/bin/bash
#
# Copyright (c) 2021 The Flatcar Maintainers.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# CI automation common functions.

source ci-automation/ci-config.env
: ${PIGZ:=pigz}

# set up author and email so git does not complain when tagging
git -C . config user.name "${CI_GIT_AUTHOR}"  
git -C . config user.email "${CI_GIT_EMAIL}"

function init_submodules() {
    git submodule init
    git submodule update
}
# --

function update_submodule() {
    local submodule="$1"
    local commit_ish="$2"

    cd "sdk_container/src/third_party/${submodule}"
    git fetch --all --tags
    git checkout "${commit_ish}"
    cd -

}
# --

function check_version_string() {
    local version="$1"

    if ! echo "${version}" | grep -qE '^(main-|alpha-|beta-|stable-|lts-)' ; then
        echo "ERROR: invalid version '${version}', must start with 'main-', 'alpha-', 'beta-', 'stable-', or 'lts-'"
        exit 1
    fi
}
# --

function update_submodules() {
    local coreos_git="$1"
    local portage_git="$2"

    init_submodules
    update_submodule "coreos-overlay" "${coreos_git}"
    update_submodule "portage-stable" "${portage_git}"
}
# --

function update_and_push_version() {
    local version="$1"

    # Add and commit local changes
    git add "sdk_container/src/third_party/coreos-overlay"
    git add "sdk_container/src/third_party/portage-stable"
    git add "sdk_container/.repo/manifests/version.txt"

    git commit --allow-empty -m "New version: ${version}"

    git tag -f "${version}"

    if git push origin "${version}" ; then
        return
    fi
    # Push (above) may fail because a tag already exists.
    #  We check for tag presence, and for the difference
    #  between local and remote, and bail
    #  only if the remote / local contents differ.

    # Remove local tag, (re-)fetch remote tags
    git tag -d "${version}"

    # refresh tree, let origin overwrite local tags
    git fetch --all --tags --force

    # This will return != 0 if
    #  - the remote tag does not exist (rc: 127)
    #  - the remote tag has changes compared to the local tree (rc: 1)
    git diff --exit-code "${version}"
}
# --

function copy_from_buildcache() {
    local what="$1"
    local where_to="$2"

    mkdir -p "$where_to"
    curl --verbose --fail --silent --show-error --location --retry-delay 1 --retry 60 \
        --retry-connrefused --retry-max-time 60 --connect-timeout 20 \
        --remote-name --output-dir "${where_to}" "https://${BUILDCACHE_SERVER}/${what}" 
}
# --

function gen_sshcmd() {
    echo -n "ssh -o BatchMode=yes"
    echo -n " -o StrictHostKeyChecking=no"
    echo -n " -o UserKnownHostsFile=/dev/null"
    echo    " -o NumberOfPasswordPrompts=0"
}
# --

function copy_to_buildcache() {
    local remote_path="${BUILDCACHE_PATH_PREFIX}/$1"
    shift

    local sshcmd="$(gen_sshcmd)"

    $sshcmd "${BUILDCACHE_USER}@${BUILDCACHE_SERVER}" \
        "mkdir -p ${remote_path}"

    rsync -Pav -e "${sshcmd}" "$@" \
        "${BUILDCACHE_USER}@${BUILDCACHE_SERVER}:${remote_path}"
}
# --

function image_exists_locally() {
    local name="$1"
    local version="$2"
    local image="${name}:${version}"

    local image_exists="$(docker images "${image}" \
                            --no-trunc --format '{{.Repository}}:{{.Tag}}')"

    [ "${image}" = "${image_exists}" ]
}
# --

# Derive docker-safe image version string from vernum.
#
function vernum_to_docker_image_version() {
    local vernum="$1"
    echo "$vernum" | sed 's/[+]/-/g'
}
# --

# Return the full name (repo+name+tag) of an image. Useful for SDK images
#  pulled from the registry (which have the registry pre-pended)
function docker_image_fullname() {
    local image="$1"
    local version="$2"

    docker images --no-trunc --format '{{.Repository}}:{{.Tag}}' \
        | grep -E "^(${CONTAINER_REGISTRY}/)*${image}:${version}$"
}
# --

function docker_image_to_buildcache() {
    local image="$1"
    local version="$2"

    # strip potential container registry prefix
    local tarball="$(basename "$image")-${version}.tar.gz"

    docker save "${image}":"${version}" | $PIGZ -c > "${tarball}"
    copy_to_buildcache "containers/${version}" "${tarball}"
}
# --

function docker_commit_to_buildcache() {
    local container="$1"
    local image_name="$2"
    local image_version="$3"

    docker commit "${container}" "${image_name}:${image_version}"
    docker_image_to_buildcache "${image_name}" "${image_version}"
}
# --

function docker_image_from_buildcache() {
    local name="$1"
    local version="$2"
    local tgz="${name}-${version}.tar.gz"

    if image_exists_locally "${name}" "${version}" ; then
        return
    fi

    local url="https://${BUILDCACHE_SERVER}/containers/${version}/${tgz}"

    curl --verbose --fail --silent --show-error --location --retry-delay 1 --retry 60 \
        --retry-connrefused --retry-max-time 60 --connect-timeout 20 \
        --remote-name "${url}"

    cat "${tgz}" | $PIGZ -d -c | docker load

    rm "${tgz}"
}
# --

function docker_image_from_registry_or_buildcache() {
    local image="$1"
    local version="$2"

    if image_exists_locally "${CONTAINER_REGISTRY}/${image}" "${version}" ; then
        return
    fi

    if docker pull "${CONTAINER_REGISTRY}/${image}:${version}" ; then
        return
    fi

    docker_image_from_buildcache "${image}" "${version}"
}
# --