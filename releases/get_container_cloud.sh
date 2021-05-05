#!/usr/bin/env bash
set -eou pipefail

: "${DEBUG:=}"
if [ -n "${DEBUG}" ]; then
  set -x
fi

## Parameters

: "${KAAS_RELEASE_YAML:=}"
: "${KAAS_CDN_REGION:=public}"
: "${DOWNLOAD_TOOL:=}" # can be curl or wget, default to first available
: "${TARGET_DIR:=kaas-bootstrap}"
: "${KAAS_CDN_BASE_URL:=}"
: "${KAAS_RELEASES_BASE_URL:=}"
: "${CLUSTER_RELEASES_DIR:=}"

## Functions

function main {
    local use_latest=no
    ensure_base_url
    ensure_release_url
    if [ -z "${KAAS_RELEASE_YAML}" ]; then
        get_latest_release
        use_latest=yes
    fi
    local bootstrap_version bootstrap_url
    bootstrap_version="$(get_bootstrap_version "${KAAS_RELEASE_YAML}")"
    bootstrap_url="$(get_bootstrap_url "${bootstrap_version}")"
    if [ -d "${TARGET_DIR}" ]; then
        if [ "$(ls -A "${TARGET_DIR}")" ]; then
            die "Target directory ${TARGET_DIR} exists and not empty"
        fi
    elif [ -e "${TARGET_DIR}" ]; then
        die "${TARGET_DIR} is not a directory"
    fi
    ensure_temp_dir
    local bootstrap_tarball="${TEMP_DIR}/bootstrap-${bootstrap_version}.tar.gz"
    log "Downloading KaaS bootstrap tarball from ${bootstrap_url} ..."
    get_url "${bootstrap_url}" "${bootstrap_tarball}"
    log "Unpacking KaaS bootstrap tarball into ${TARGET_DIR} ..."
    mkdir -p "${TARGET_DIR}"
    tar -xf "${bootstrap_tarball}" -C "${TARGET_DIR}"
    rm -f "${TARGET_DIR}/bootstrap.env"
    if [ "${use_latest}" = "yes" ]; then
        rm -rf "${TARGET_DIR}/releases"
        mkdir -p "${TARGET_DIR}/releases/kaas"
        cp "${KAAS_RELEASE_YAML}" "${TARGET_DIR}/releases/kaas"
        cp -r "${TEMP_DIR}/cluster" "${TARGET_DIR}/releases/"
        KAAS_RELEASE_YAML="${TARGET_DIR}/releases/kaas/${LATEST_KAAS_VERSION}.yaml"
        CLUSTER_RELEASES_DIR="${TARGET_DIR}/releases/cluster"
    fi
    set_absolute_paths
    cat >> "${TARGET_DIR}/bootstrap.env" <<EOF
KAAS_RELEASE_YAML=${KAAS_RELEASE_YAML}
CLUSTER_RELEASES_DIR=${CLUSTER_RELEASES_DIR}
KAAS_CDN_REGION=${KAAS_CDN_REGION}
EOF
}

LATEST_KAAS_VERSION="2.8.0"
declare -a LATEST_CLUSTER_VERSIONS=("5.11.0" "5.14.0" "5.15.0" "6.14.0")

function get_latest_release {
    ensure_temp_dir
    mkdir -p "${TEMP_DIR}/kaas" "${TEMP_DIR}/cluster"
    KAAS_RELEASE_YAML="${TEMP_DIR}/kaas/${LATEST_KAAS_VERSION}.yaml"
    log "Downloading latest KaaS release..."
    get_url "${KAAS_RELEASES_BASE_URL}/kaas/${LATEST_KAAS_VERSION}.yaml" "${KAAS_RELEASE_YAML}"
    log "Downloading latest cluster releases..."
    local release
    for release in "${LATEST_CLUSTER_VERSIONS[@]}"; do
        get_url "${KAAS_RELEASES_BASE_URL}/cluster/${release}.yaml" "${TEMP_DIR}/cluster/${release}.yaml"
    done
}

function set_absolute_paths {
    if [ -z "${KAAS_RELEASE_YAML}" ]; then
        die "KAAS_RELEASE_YAML must be set"
    fi
    if [ ! -f "${KAAS_RELEASE_YAML}" ]; then
        die "File ${KAAS_RELEASE_YAML} does not exist or is not a regular file"
    fi
    KAAS_RELEASE_YAML="$(cd "$(dirname "${KAAS_RELEASE_YAML}")"; pwd)/$(basename "${KAAS_RELEASE_YAML}")"
    if [ -z "${CLUSTER_RELEASES_DIR}" ]; then
        die "CLUSTER_RELEASES_DIR must be set"
    fi
    if [ ! -d "${CLUSTER_RELEASES_DIR}" ]; then
        die "Directory ${CLUSTER_RELEASES_DIR} does not exist or is not a directory"
    fi
    CLUSTER_RELEASES_DIR="$(cd "${CLUSTER_RELEASES_DIR}"; pwd)"
}

function get_bootstrap_version {
    local release="$1"
    local res
    res="$(awk 'f == 1 { print $2; exit } /bootstrap:/ { f = 1 }' "${release}")"
    if [ -z "${res}" ]; then
        echo "0.2.29"
    else
        echo "${res}"
    fi
}

function ensure_base_url {
    if [ "${KAAS_CDN_BASE_URL}" ]; then
        return
    fi
    case "${KAAS_CDN_REGION}" in
        internal-ci )
            KAAS_CDN_BASE_URL="https://artifactory.mcp.mirantis.net/binary-dev-kaas-virtual"
            ;;
        internal-eu )
            KAAS_CDN_BASE_URL="https://binary-dev-kaas-virtual-binary-eu.mcp.mirantis.net"
            ;;
        public-ci )
            KAAS_CDN_BASE_URL="https://binary-dev-kaas-mirantis-com.s3.amazonaws.com"
            ;;
        public )
            KAAS_CDN_BASE_URL="https://binary.mirantis.com"
            ;;
        * )
            die "Unknown CDN region: ${KAAS_CDN_REGION}"
            ;;
    esac
}

function ensure_release_url {
    if [ "${KAAS_RELEASES_BASE_URL}" ]; then
        return
    fi
    KAAS_RELEASES_BASE_URL="${KAAS_CDN_BASE_URL}/releases"
}

function get_bootstrap_url {
    local bootstrap_version="$1"
    local os_tag
    case "$(uname -s)" in
        Linux*) os_tag=linux;;
        Darwin*) os_tag=darwin;;
        *) die "Unexpected system: $(uname -s)"
    esac
    echo "${KAAS_CDN_BASE_URL}/core/bin/bootstrap-${os_tag}-${bootstrap_version}.tar.gz"
}

## Temp dir

TEMP_DIR=

function cleanup_temp_dir {
    if [ "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}"
    fi
}

function ensure_temp_dir {
    if [ -z "${TEMP_DIR}" ]; then
        TEMP_DIR="$(mktemp -d)"
        trap cleanup_temp_dir EXIT
    fi
}

## Download

function get_download_tool {
    if hash curl 2>/dev/null; then
        echo "curl"
    elif hash wget 2>/dev/null; then
        echo "wget"
    else
        die "Neither wget nor curl tool found"
    fi
}

function get_url_wget {
    wget -q --show-progress "$1" -O "$2"
    echo 1>&2
}

function get_url_curl {
    curl -f#L "$1" -o "$2"
    echo 1>&2
}

function get_url {
    if [ -z "${DOWNLOAD_TOOL}" ]; then
        DOWNLOAD_TOOL="$(get_download_tool)"
    fi
    "get_url_${DOWNLOAD_TOOL}" "$@"
}

## Logging

if [[ -z "${color_start-}" ]]; then
    declare -r color_start="\033["
    declare -r color_red="${color_start}0;31m"
    declare -r color_yellow="${color_start}0;33m"
    declare -r color_green="${color_start}0;32m"
    declare -r color_norm="${color_start}0m"
fi

function logr {
    echo -e "${color_red}$1${color_norm}" 1>&2
}
function logy {
    echo -e "${color_yellow}$1${color_norm}" 1>&2
}
function log {
    echo -e "${color_green}$1${color_norm}" 1>&2
}
function die {
    logr "$1"
    exit 1
}

##

main "$@"
