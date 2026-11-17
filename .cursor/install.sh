#!/usr/bin/env bash
# Idempotent, non-interactive bootstrap for Cursor Cloud Agents.
# Installs the repo's system packages, the toolchain pinned in
# rust-toolchain.toml, then fetches and builds the workspace so later
# agents start warm. Does not start kumod and does not send mail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEBIAN_FRONTEND=noninteractive

if [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  if ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    sudo apt-get install -y --no-install-recommends ca-certificates curl git
  fi
fi

# Prefer the image rustup so a second toolchain is not installed under $HOME.
if [[ -x /usr/local/cargo/bin/rustup ]]; then
  export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
  export PATH="${CARGO_HOME}/bin:${PATH}"
elif [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
  export PATH="${HOME}/.cargo/bin:${PATH}"
elif ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
  export PATH="${HOME}/.cargo/bin:${PATH}"
fi

# rust-toolchain.toml is applied when rustup runs inside the repo.
# Install it before get-deps.sh, which exits if rustc is missing.
# Explicit install: rustup no longer guarantees auto-install from the file.
if [[ -f rust-toolchain.toml ]]; then
  channel="$(awk -F'"' '/^[[:space:]]*channel[[:space:]]*=/ {print $2; exit}' rust-toolchain.toml)"
  if [[ -n "${channel}" ]]; then
    rustup toolchain install "${channel}" --component rustfmt,clippy
  fi
fi
rustup show active-toolchain >/dev/null

# Login shells on the default image already include cargo. Also link the
# rustup proxies into /usr/local/bin so a non-interactive shell finds them.
cargo_bin="$(dirname "$(command -v rustup)")"
for name in cargo rustc rustdoc rustup rustfmt cargo-fmt cargo-clippy clippy-driver; do
  if [[ -e "${cargo_bin}/${name}" ]]; then
    sudo ln -sfn "${cargo_bin}/${name}" "/usr/local/bin/${name}"
  fi
done

if [[ -x ./get-deps.sh ]]; then
  ./get-deps.sh
else
  echo "warning: get-deps.sh is missing; system packages were not installed" >&2
fi

# The default image has libgcc-N-dev, so clang selects that GCC, but
# get-deps.sh only installs the distro default g++ (often an older N).
# Without the matching libstdc++ headers, C++ deps such as rocksdb fail.
if command -v clang++ >/dev/null 2>&1 \
  && ! echo '#include <memory>' | clang++ -x c++ -fsyntax-only - >/dev/null 2>&1 \
  && [[ -f /etc/debian_version ]]; then
  gcc_ver="$(clang++ -v -x c++ -fsyntax-only /dev/null 2>&1 | sed -n 's/.*Selected GCC installation: .*\/\([0-9][0-9]*\)$/\1/p' | head -1)"
  if [[ -n "${gcc_ver}" ]]; then
    sudo apt-get install -y --no-install-recommends "libstdc++-${gcc_ver}-dev"
  else
    echo "warning: clang++ cannot find <memory> and the selected GCC version was not detected" >&2
  fi
fi

# Nothing in fetch/build reads a secret. RPM signing in CI uses
# OPENREPO_GPG_PUBLIC and OPENREPO_GPG_PRIVATE; warn by name and continue.
if [[ -z "${OPENREPO_GPG_PUBLIC:-}" || -z "${OPENREPO_GPG_PRIVATE:-}" ]]; then
  echo "warning: OPENREPO_GPG_PUBLIC and OPENREPO_GPG_PRIVATE are unset; RPM signing is unavailable and is not required to build or test" >&2
fi

cargo fetch --locked
cargo build --locked
