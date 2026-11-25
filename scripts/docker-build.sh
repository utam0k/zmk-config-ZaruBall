#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${ZMK_DOCKER_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
cache_host_dir="${ZMK_CACHE_DIR:-${repo_root}/.cache/zmk-workspace}"

if [[ -z "${image}" ]]; then
  echo "ZMK_DOCKER_IMAGE is empty. Set it or use the default." >&2
  exit 1
fi

mkdir -p "${cache_host_dir}"

container_cmd='
set -euo pipefail

base_dir="/workspace"
config_dir="/workspace/config"
module_root="/workspace"
extra_cmake_args=""
log_dir="/workspace/build/logs"
mkdir -p "${log_dir}"

if [ -f /workspace/zephyr/module.yml ]; then
  base_dir="${ZMK_WORKSPACE_DIR:-/cache}"
  config_dir="${base_dir}/config"
  module_root="${base_dir}/config-module"

  mkdir -p "${base_dir}"
  rm -rf "${config_dir}" "${module_root}"
  mkdir -p "${config_dir}" "${module_root}"
  cp -R /workspace/config/* "${config_dir}/"

  tar -C /workspace -cf - \
    --exclude=.git --exclude=.west \
    --exclude=.west-workspace \
    --exclude=build --exclude=build-* \
    --exclude=zephyr --exclude=modules --exclude=zmk --exclude=zmk-* \
    --exclude=optional \
    --exclude=.cache \
    . | tar -C "${module_root}" -xf -
  mkdir -p "${module_root}/zephyr"
  cat > "${module_root}/zephyr/module.yml" <<'EOF'
build:
  settings:
    board_root: .
EOF

  extra_cmake_args="-DZMK_EXTRA_MODULES=${module_root}"

  # Clean old build dirs that may point to a different Zephyr base.
  rm -rf /workspace/build/ZaruBall_left /workspace/build/ZaruBall_right /workspace/build/settings_reset
fi

if [ ! -d "${base_dir}/.west" ]; then
  echo "Initializing west workspace at: ${base_dir}"
  (cd "${base_dir}" && west init -l "${config_dir}")
fi

(cd "${base_dir}" && west update --fetch-opt=--filter=tree:0)
(cd "${base_dir}" && west zephyr-export)

board="xiao_ble//zmk"

echo "Using workspace: ${base_dir}"
echo "Using module root: ${module_root}"
echo "Using config dir: ${config_dir}"
echo "Using board: ${board}"

if ! (cd "${base_dir}" && west build -p -s "${base_dir}/zmk/app" -d /workspace/build/ZaruBall_left -b "${board}" -- \
  -DZMK_CONFIG="${config_dir}" ${extra_cmake_args} -DSHIELD="ZaruBall_left rgbled_adapter") >"${log_dir}/ZaruBall_left.log" 2>&1; then
  echo "Left build failed. Last 200 lines:"
  tail -n 200 "${log_dir}/ZaruBall_left.log"
  exit 1
fi

if ! (cd "${base_dir}" && west build -p -s "${base_dir}/zmk/app" -d /workspace/build/ZaruBall_right -b "${board}" -S studio-rpc-usb-uart -- \
  -DZMK_CONFIG="${config_dir}" ${extra_cmake_args} -DSHIELD="ZaruBall_right rgbled_adapter" -DCONFIG_ZMK_STUDIO=y) >"${log_dir}/ZaruBall_right.log" 2>&1; then
  echo "Right build failed. Last 200 lines:"
  tail -n 200 "${log_dir}/ZaruBall_right.log"
  exit 1
fi

if ! (cd "${base_dir}" && west build -p -s "${base_dir}/zmk/app" -d /workspace/build/settings_reset -b "${board}" -- \
  -DZMK_CONFIG="${config_dir}" ${extra_cmake_args} -DSHIELD="settings_reset") >"${log_dir}/settings_reset.log" 2>&1; then
  echo "Settings reset build failed. Last 200 lines:"
  tail -n 200 "${log_dir}/settings_reset.log"
  exit 1
fi

mkdir -p /workspace/build/artifacts
for target in ZaruBall_left ZaruBall_right settings_reset; do
  cp "/workspace/build/${target}/zephyr/zmk.uf2" "/workspace/build/artifacts/${target}.uf2"
done
(cd "${base_dir}" && west manifest --freeze --active-only) > /workspace/build/artifacts/west-frozen.yml
'

docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e ZMK_WORKSPACE_DIR \
  -v "${repo_root}:/workspace" \
  -v "${cache_host_dir}:/cache" \
  -w /workspace \
  "${image}" \
  bash -lc "${container_cmd}"
