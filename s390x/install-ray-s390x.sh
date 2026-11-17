#!/bin/bash
# install-ray-s390x.sh — install Ray 2.60.0 (s390x port) on a RHEL/Fedora
# IBM Z (s390x) VM, no Ray build required.
#
# Usage:
#   ./install-ray-s390x.sh [--venv DIR] [--with-tests] [--no-sudo-check]
#
#   --venv DIR       target venv directory (default: ~/ray-s390x/venv)
#   --with-tests     also set up everything needed to run Ray's Python
#                    test suite from a source checkout (pinned pytest,
#                    test deps, site-packages patches incl. redis-server
#                    from the redis-7.2.3 release)
#   --no-sudo-check  skip the dnf prerequisite check (you already did it)
#
# Source: https://github.com/CathalOConnorRH/ray/releases/tag/ray-2.60.0-s390x
set -euo pipefail

VENV=~/ray-s390x/venv
WITH_TESTS=0
SUDO_CHECK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv) VENV="$2"; shift 2 ;;
    --with-tests) WITH_TESTS=1; shift ;;
    --no-sudo-check) SUDO_CHECK=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

WHEEL_URL=https://github.com/CathalOConnorRH/ray/releases/download/ray-2.60.0-s390x/ray-2.60.0-cp312-cp312-linux_s390x.whl
WHEEL_SHA256=b1a1e0d6c8fd366fd8774e3ad0f3eca8f978d4381222b034ee42707ca50c480c
REDIS_URL=https://github.com/CathalOConnorRH/ray/releases/download/redis-7.2.3/redis-linux-s390x.tar.gz

ARCH=$(uname -m)
if [[ "$ARCH" != "s390x" ]]; then
  echo "ERROR: this installer is for s390x, you are on $ARCH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi
PYVER=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
if [[ "$PYVER" != "3.12" ]]; then
  echo "ERROR: the wheel is cp312-only; found python $PYVER." >&2
  echo "       Install python3.12 (e.g. sudo dnf install python3.12 python3.12-devel)" >&2
  exit 1
fi

# --- 1. OS prerequisites (only things pip/compilers need; one dnf command) ---
DNF_PKGS=(gcc gcc-c++ make tar curl python3-devel openssl-devel)
NEED=()
for p in "${DNF_PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || NEED+=("$p"); done
if [[ ${#NEED[@]} -gt 0 && $SUDO_CHECK -eq 1 ]]; then
  echo "Missing packages: ${NEED[*]}"
  if command -v sudo >/dev/null; then
    sudo dnf install -y "${NEED[@]}"
  else
    echo "Run this yourself, then re-run with --no-sudo-check:" >&2
    echo "  dnf install -y ${NEED[*]}" >&2
    exit 1
  fi
fi

# --- 2. venv ---
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Creating venv at $VENV"
  python3 -m venv "$VENV"
fi
PIP="$VENV/bin/pip"
PY="$VENV/bin/python"
"$PIP" install -q -U pip setuptools wheel

# --- 3. wheel ---
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WHEEL_NAME=ray-2.60.0-cp312-cp312-linux_s390x.whl
echo "Downloading wheel..."
curl -fsSL -o "$WORK/$WHEEL_NAME" "$WHEEL_URL"
echo "$WHEEL_SHA256  $WORK/$WHEEL_NAME" | sha256sum -c -
"$PIP" install -q "$WORK/$WHEEL_NAME"

# --- 4. dashboard/runtime Python deps (all pure-python or s390x-wheeled) ---
"$PIP" install -q aiohttp aiohttp-cors colorful click filelock jsonschema \
  packaging prometheus_client psutil pydantic python-dateutil requests \
  setproctitle smart_open virtualenv \
  opencensus opencensus-context \
  opentelemetry-api opentelemetry-sdk \
  opentelemetry-exporter-prometheus opentelemetry-proto \
  opentelemetry-semantic-conventions \
  googleapis-common-protos protobuf google-api-core

# --- 5. grpcio: no s390x wheel; boringssl is LE-only -> system OpenSSL ---
if ! "$PY" -c "import grpc" 2>/dev/null; then
  echo "Building grpcio from source (several minutes)..."
  GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1 GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=$(nproc) \
    "$PIP" install -q --no-binary :all: --no-build-isolation grpcio
fi

# --- 6. verify ---
echo "Verifying local cluster + dashboard..."
"$PY" - <<'EOF'
import ray, urllib.request
ray.init(include_dashboard=True)
html = urllib.request.urlopen("http://127.0.0.1:8265", timeout=120).read()
assert b"<html" in html, html[:200]
@ray.remote
def f(x): return x * 2
assert ray.get(f.remote(21)) == 42
print("OK: cluster started, task executed, dashboard served on :8265")
ray.shutdown()
EOF

# --- 7. optional: test-suite support ---
if [[ $WITH_TESTS -eq 1 ]]; then
  echo "Setting up test-suite support..."
  # pinned test toolchain (pytest 9 rejects marks-on-fixtures in ray's tests)
  "$PIP" install -q pytest==7.4.4 pytest-asyncio==0.17.2 pytest-aiohttp \
    pytest-timeout pytest-lazy-fixtures pytest-mock
  "$PIP" install -q redis proxy.py numpy ipython "smart_open[s3]" boto3
  SITEPKG=$("$PY" -c 'import ray, os; print(os.path.dirname(os.path.dirname(ray.__file__)))')
  # redis-server: not shipped in any ray wheel; without it some tests hang
  curl -fsSL -o "$WORK/redis.tgz" "$REDIS_URL"
  mkdir -p "$SITEPKG/ray/core/src/ray/thirdparty/redis/src"
  # tarball has redis-server and redis-cli at the archive root
  tar xzf "$WORK/redis.tgz" -C "$SITEPKG/ray/core/src/ray/thirdparty/redis/src/" redis-server
  # note: ray/tests symlink + setup.py copy require a source checkout at
  # ~/ray-s390x/ray — see README-s390x-port.md section 9c if running tests.
  if [[ -d ~/ray-s390x/ray/python/ray/tests ]]; then
    ln -sfn ~/ray-s390x/ray/python/ray/tests "$SITEPKG/ray/tests"
    cp ~/ray-s390x/ray/python/setup.py "$SITEPKG/setup.py"
    echo "Source checkout detected: ray/tests symlink + setup.py copied."
  else
    echo "NOTE: no source checkout at ~/ray-s390x/ray — for the full test"
    echo "suite, clone the s390x-port branch there and re-run --with-tests."
  fi
fi

cat <<EOF

Done. Ray is installed in $VENV

  $VENV/bin/python -c "import ray; ray.init()"

Notes:
- Ray 2.60 token auth is ON by default (dashboard/API return 401 without a
  token). For local testing: RAY_AUTH_MODE=disabled
- py-spy is NOT installed (no s390x support upstream) — CPU flamegraph
  features of the dashboard are unavailable.
EOF
