# Ray 2.60.0 on IBM Z (s390x) — Port Notes

Machine: RHEL 10.2, s390x, 12 CPUs, 314 GiB RAM
Date: 2026-11-16
Branch: s390x-port (github.com/CathalOConnorRH/ray), based on ray-2.60.0

## Result

Ray 2.60.0 core builds and runs on s390x. A wheel was produced and verified:

    ray-2.60.0-cp312-cp312-linux_s390x.whl  (48 MB, in ~/ray-s390x/ray/python/dist/)

Verified working: local cluster startup (GCS, raylet, workers), remote tasks,
actors, ray.put/ray.get, recursive task fan-out, resource detection.
The web dashboard (frontend + backend) builds and serves on port 8265.
The core Python test suite passes (see section 9).

## Layout on this machine

    ~/ray-s390x/
      README-s390x-port.md  this file
      redis/                redis 7.2.3 source, build, and packaged tarball
      bazel/                bazel 7.5.0 source + built binary (also in ~/.local/bin)
      ray/                  the s390x-port branch checkout
      venv/                 python 3.12 venv with ray installed
      ray-build.log         bazel build //:ray_pkg log
      wheel-build.log       setup.py bdist_wheel log

    ~/.local/node/          Node.js 14.21.3 s390x (dashboard builds, no sudo)

## What was done, step by step

### 1. OS prerequisites (sudo)

    sudo dnf groupinstall -y "Development Tools"
    sudo dnf install -y git python3-pip python3-devel patch zlib-devel \
      java-21-openjdk-devel unzip \
      perl-devel perl-ExtUtils-ParseXS perl-IPC-Cmd perl-FindBin

### 2. Redis 7.2.3 for s390x

Ray bundles redis binaries in the wheel; upstream only ships x86_64/arm64.

    cd ~/ray-s390x/redis
    curl -fsSL -o redis-7.2.3.tar.gz \
      https://github.com/ray-project/redis/archive/refs/tags/7.2.3.tar.gz
    tar xzf redis-7.2.3.tar.gz
    cd redis-7.2.3
    make -j12 MALLOC=jemalloc BUILD_TLS=no
    # smoke test
    src/redis-server --port 7799 --daemonize no --save "" --appendonly no &
    src/redis-cli -p 7799 ping   # -> PONG
    # package (arm64-release layout: redis-server + redis-cli at archive root)
    tar czf ~/ray-s390x/redis/redis-linux-s390x.tar.gz \
      -C redis-7.2.3/src redis-server redis-cli
    sha256sum redis-linux-s390x.tar.gz

Published at https://github.com/CathalOConnorRH/ray/releases/tag/redis-7.2.3
(sha256 fa7d19d92552d17b51ef573a675c0d8bb1b2a40a77da088a31a2969fb500088e)
and referenced from the WORKSPACE (redis_linux_s390x http_archive).

### 3. Bazel 7.5.0 from source

Bazel publishes no s390x binaries (bazelisk neither), so it was bootstrapped:

    cd ~/ray-s390x/bazel
    curl -fsSL -o bazel-7.5.0-dist.zip \
      https://github.com/bazelbuild/bazel/releases/download/7.5.0/bazel-7.5.0-dist.zip
    unzip -q bazel-7.5.0-dist.zip -d bazel-src
    env EXTRA_BAZEL_ARGS="--java_runtime_version=local_jdk \
      --tool_java_runtime_version=local_jdk" bash bazel-src/compile.sh
    install -D bazel-src/output/bazel ~/.local/bin/bazel

IMPORTANT: the local_jdk flags are required. Bazel auto-selects a remote
s390x JDK 11 toolchain whose fetch produces a broken javac bootstrap.

### 4. Repo changes (branch s390x-port, all pushed)

All changes are on https://github.com/CathalOConnorRH/ray/tree/s390x-port:

1. Platform plumbing (commit 6a1c9f1):
   - bazel/BUILD.bazel: linux_s390x_config config_setting
   - BUILD.bazel: s390x branches in redis-server/redis-cli selects
   - WORKSPACE: redis_linux_s390x http_archive -> fork release
   - build-wheel.sh / build-image.sh: Linux-s390x -> manylinux2014_s390x
   - ci/env/install-dependencies.sh: Node.js s390x tarball
   - install_and_start_prometheus.py: s390x arch mapping
2. BoringSSL -> OpenSSL (253a4b6, 905ec8c, b0437b0, f6b37bc):
   BoringSSL does not support big-endian architectures at all. gRPC,
   hiredis and boost asio-ssl were re-routed to the OpenSSL 1.1.1f build
   (already pinned in ray) via the libssl/libcrypto workspace binds:
   - WORKSPACE: bind libssl/libcrypto -> @openssl//:openssl, @nasm declared
   - bazel/hiredis.BUILD: deps -> @io_ray//external:libssl|libcrypto
   - thirdparty/patches/boost-headers.patch: asio_ssl dep -> libssl bind
3. System Perl toolchain (6aae843): rules_perl has no s390x perl, so a
   toolchain backed by /usr/bin/perl was registered:
   - bazel/perl_system.BUILD + bazel/BUILD.bazel + WORKSPACE registration
4. Boost.Context s390x asm (d44dfb9): upstream Boost ships s390x assembly
   but rules_boost never selected it; thirdparty/patches/
   boost-s390x-context.patch adds the select branch.

### 5. Build the C++ core

    cd ~/ray-s390x/ray
    bazel build //:ray_pkg \
      --java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk

(~36 min; rocksdb + cmake_tool are the slow foreign-cc steps.)

### 6. Build the wheel

build-wheel.sh is unusable on s390x (needs uv + raymake, neither has s390x
builds), so the classic path was used:

    python3 -m venv ~/ray-s390x/venv
    ~/ray-s390x/venv/bin/pip install -U pip setuptools wheel cython
    cd ~/ray-s390x/ray/python
    env BAZEL_ARGS="--java_runtime_version=local_jdk \
      --tool_java_runtime_version=local_jdk" \
      PATH=$HOME/.local/bin:$PATH \
      ~/ray-s390x/venv/bin/python setup.py bdist_wheel

### 7. Install + smoke test

To install the BUILT WHEEL on another s390x VM (no build required), use the
packaged release instead of the manual steps below:

    # on any RHEL/Fedora s390x VM with python3.12:
    curl -fsSL -o install-ray-s390x.sh \
      https://github.com/CathalOConnorRH/ray/releases/download/ray-2.60.0-s390x/install-ray-s390x.sh
    bash install-ray-s390x.sh            # add --with-tests for the test suite

The release (tag ray-2.60.0-s390x) contains the wheel (sha256 b1a1e0d6...)
and the installer. The installer: checks arch/python, dnf-installs build
prereqs (one sudo command), creates a venv (default ~/ray-s390x/venv,
--venv to override), downloads + sha256-verifies the wheel, installs all
dashboard/runtime deps, builds grpcio from source against system OpenSSL,
then verifies cluster + task + dashboard startup. --with-tests additionally
installs the pinned pytest stack + test deps and applies the section 9c
site-packages patches (fetching redis-server from the redis-7.2.3 release).
It was validated end-to-end on a fresh venv on the build machine
(2026-11-17), including running test_gcs_pubsub.py to completion.

Manual install on the build machine:

    ~/ray-s390x/venv/bin/pip install dist/ray-2.60.0-cp312-cp312-linux_s390x.whl
    ~/ray-s390x/venv/bin/python -c "
    import ray
    ray.init()
    r = ray.remote(lambda x: x * 2)
    print(ray.get(r.remote(21)))   # -> 42
    ray.shutdown()"

Actors, object store, recursive tasks and cluster resource detection were
also verified.

### 8. Dashboard (Node.js frontend + backend)

Node.js 14.21.3 (same version/URL/sha256 as ci/env/install-dependencies.sh
uses for s390x) is installed WITHOUT sudo into ~/.local/node — the script's
own path installs to /usr/local and needs root:

    curl -fsSL -o /tmp/node.tar.xz \
      https://nodejs.org/dist/v14.21.3/node-v14.21.3-linux-s390x.tar.xz
    echo "a241aa16cbf5485ebc54955bec42a81334278808174fcfd4199bcc3256f77eb0  /tmp/node.tar.xz" \
      | sha256sum -c -
    mkdir -p ~/.local/node
    tar -xf /tmp/node.tar.xz -C ~/.local/node --strip-components=1
    rm /tmp/node.tar.xz
    export PATH=$HOME/.local/node/bin:$PATH

Build the frontend (works as-is on s390x):

    cd ~/ray-s390x/ray/python/ray/dashboard/client
    npm ci            # ~1977 packages
    npm run build     # -> client/build/ (react-scripts, ~3 min)

Then rebuild the wheel (section 6 command) — setup.py automatically picks up
ray/dashboard/client/build/ (49 files land inside the wheel under
ray/dashboard/client/build/).

Dashboard Python dependencies — most install from PyPI fine on s390x, with
two exceptions:

    ~/ray-s390x/venv/bin/pip install aiohttp aiohttp-cors colorful \
      opencensus opentelemetry-api opentelemetry-sdk \
      opentelemetry-exporter-prometheus opentelemetry-proto \
      opentelemetry-semantic-conventions prometheus_client pydantic \
      smart_open click filelock jsonschema packaging python-dateutil \
      requests virtualenv googleapis-common-protos protobuf google-api-core

grpcio has NO s390x wheel and its bundled boringssl is little-endian-only
(same problem as section 4.2). Build it from sdist against system OpenSSL:

    # requires: sudo dnf install -y openssl-devel
    GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1 GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=12 \
      ~/ray-s390x/venv/bin/pip install --no-binary :all: \
        --no-build-isolation grpcio

NOTE the env var spelling: modern grpcio renamed it from
GRPC_PYTHON_BUILD_WITH_SYSTEM_OPENSSL to GRPC_PYTHON_BUILD_SYSTEM_OPENSSL.

py-spy has NO s390x support at all (its Rust source is arch-gated) and is
NOT installed — the dashboard works, only CPU flamegraph/profiling features
are missing. It cannot be built from source either (maturin/cargo fails:
get_tstate_current_offset has no s390x implementation).

Verify:

    ~/ray-s390x/venv/bin/python -c "
    import ray, urllib.request
    ray.init(include_dashboard=True)
    html = urllib.request.urlopen('http://127.0.0.1:8265').read()
    assert b'<html' in html
    print('dashboard OK', len(html))
    ray.shutdown()"

Ray 2.60 enables token auth by default — unauthenticated GETs return 401.
Use RAY_AUTH_MODE=disabled for local testing.

### 9. Running the Python test suite

All core suites pass; every failure encountered was an environment issue,
not an s390x bug. To reproduce on a fresh wheel install:

a) Pin the test toolchain to Ray's own requirements (pytest 9 is too new —
   it rejects marks-on-fixtures in test_stress.py):

    ~/ray-s390x/venv/bin/pip install pytest==7.4.4 pytest-asyncio==0.17.2 \
      pytest-aiohttp pytest-timeout pytest-lazy-fixtures pytest-mock \
      psutil setproctitle

b) Test dependencies that PyPI provides on s390x:

    ~/ray-s390x/venv/bin/pip install redis proxy.py numpy ipython \
      "smart_open[s3]" boto3

c) The wheel is not a source tree — three things CI gets for free must be
   reproduced in site-packages (SITEPKG=~/ray-s390x/venv/lib64/python3.12/
   site-packages below):

    # redis-server binary is NOT in the wheel (official wheels don't ship it
    # either; CI runs tests from the source tree). Without it, tests using
    # REDIS_EXECUTABLE HANG forever (fixture retry loop has no timeout).
    mkdir -p $SITEPKG/ray/core/src/ray/thirdparty/redis/src
    cp ~/ray-s390x/ray/python/ray/core/src/ray/thirdparty/redis/src/redis-server \
      $SITEPKG/ray/core/src/ray/thirdparty/redis/src/

    # test_actor.py imports ray.tests.client_test_utils (source-tree only)
    ln -sfn ~/ray-s390x/ray/python/ray/tests $SITEPKG/ray/tests

    # runtime_env conda plugin _get_ray_setup_spec() runpy's setup.py from
    # the directory above ray/ — needed because our wheel's ray.__commit__
    # is the literal {{RAY_COMMIT_SHA}} placeholder, so ray looks
    # "source-built" to current_ray_pip_specifier()
    cp ~/ray-s390x/ray/python/setup.py $SITEPKG/setup.py

d) Run (always with the venv's bin on PATH — the http-proxy fixture shells
   out to the `proxy` command):

    cd ~/ray-s390x/ray
    PATH=$HOME/ray-s390x/venv/bin:$PATH \
      ~/ray-s390x/venv/bin/python -m pytest python/ray/tests/test_basic.py -q

Results (2026-11-17):

    test_basic 37p | gcs_utils p | gcs_pubsub 6p | gcs_fault_tolerance 21p+6skip
    runtime_env 9p | runtime_env_packaging 128p | runtime_env_complicated 12p+11skip
    actor 89p | actor_advanced 32p | actor_failures p | actor_lifetime 6p
    actor_out_of_order 6p | job 10p | stress 6p

Known environment-limited failures (NOT port bugs):
- conda runtime_env tests: no conda exists for s390x Linux (no
  miniconda/conda-forge s390x builds).
- test_conda_pip_extras_ray_default[pip]: pip-installs ray[default] from
  PyPI, which pulls py-spy (no s390x, see section 8).
- One-off "double free or corruption" abort after test_basic's summary was
  seen once (right after a SIGINT-killed hang); not reproducible. If it
  recurs, capture the core dump and gdb it — possible shutdown-path bug.

## Next steps

1. DONE 2026-11-17 — core test suite (section 9): all suites pass, no
   s390x-specific Ray bugs found.
2. DONE 2026-11-17 — dashboard (section 8): frontend builds, wheel includes
   it, serves on 8265.
3. Multi-node: start a second Z VM and try ray start --head / ray start
   --address to validate redis, GCS and inter-process networking across
   nodes.
4. Other Python versions: wheel is cp312 only; repeat section 6 with
   3.10/3.11/3.13 venvs (bazel artifacts are reused, only _raylet
   recompiles).
5. Known gaps:
   - ray-haproxy (Ray Serve router): no s390x wheel on PyPI; needs a source
     build or an s390x release, or Serve is unusable.
   - pyarrow (Ray Data/Train): no s390x wheels; would need an Arrow build.
   - ray[llm] / RayLLM: not feasible (torch/vllm).
   - py-spy / conda: no s390x support upstream (see sections 8-9).
6. Upstreaming: the most discussion-worthy changes are the BoringSSL->
   OpenSSL rebind (affects all platforms) and the rules_boost s390x patch.
   The redis binary would ideally live in ray-project/redis releases.

## Rebuild cheat sheet (after pulling new commits)

    cd ~/ray-s390x/ray && git pull
    bazel build //:ray_pkg --java_runtime_version=local_jdk \
      --tool_java_runtime_version=local_jdk
    cd python
    env BAZEL_ARGS="--java_runtime_version=local_jdk \
      --tool_java_runtime_version=local_jdk" PATH=$HOME/.local/bin:$PATH \
      ~/ray-s390x/venv/bin/python setup.py bdist_wheel
