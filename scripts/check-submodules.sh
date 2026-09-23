#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

required_paths=(
  "Vendor/glslang/glslang/Include/glslang_c_interface.h"
  "Vendor/glslang/glslang/MachineIndependent/ShaderLang.cpp"
  "Vendor/spirv-cross/spirv_cross.hpp"
  "Vendor/spirv-cross/spirv_msl.cpp"
)

missing=()
for path in "${required_paths[@]}"; do
  if [[ ! -e "$path" ]]; then
    missing+=("$path")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Holoscape vendor submodules are missing or incomplete." >&2
  echo "" >&2
  echo "Missing required files:" >&2
  for path in "${missing[@]}"; do
    echo "  - $path" >&2
  done
  echo "" >&2
  echo "Run this from the repository root, then retry:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi
