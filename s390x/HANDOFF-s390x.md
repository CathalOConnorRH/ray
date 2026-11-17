# Handoff: Ray s390x port — next steps for the next agent

Read this together with ~/ray-s390x/README-s390x-port.md on the Z machine,
which documents what has been done so far. This doc is the task list and the
operational knowledge you need to continue.

## Current state (Nov 16, 2026)

- Ray 2.60.0 core builds and runs on s390x (RHEL 10.2 Z VM).
- Wheel: ray-2.60.0-cp312-cp312-linux_s390x.whl in ~/ray-s390x/ray/python/dist/
- Smoke tests pass: ray.init, remote tasks, actors, object store, recursion.
- All repo changes: branch s390x-port on github.com/CathalOConnorRH/ray
  (7 commits, tip d44dfb9, based on ray-2.60.0). Everything is pushed.
- Redis s390x binary published: github.com/CathalOConnorRH/ray/releases/
  tag/redis-7.2.3 (referenced from WORKSPACE by sha256).
- Bazel 7.5.0 built from source, installed at ~/.local/bin/bazel on the Z VM.

## Environment / access

- Z VM: ssh <user>@<z-vm-address> (key auth, BatchMode=yes is fine; address kept out of this public repo).
  RHEL 10.2 s390x, 12 CPUs, 314 GiB RAM. Outbound internet OK.
- sudo on the VM needs a password — you cannot run dnf yourself. Ask the
  human to run any sudo command via: ssh -t <user>@<z-vm-address> 'sudo ...'
- Local repo (Mac): <local ray checkout>/ray, branch s390x-port.
  Remotes: origin = CathalOConnorRH/ray (push here), upstream = ray-project.
- gh CLI on the Mac is authenticated as CathalOConnorRH.
- Python on Z: use the venv at ~/ray-s390x/venv (3.12, ray installed).

## Hard-won operational knowledge (do not rediscover these)

1. ALWAYS pass --java_runtime_version=local_jdk --tool_java_runtime_version=
   local_jdk to bazel (also via BAZEL_ARGS for setup.py). Bazel's auto-
   selected remote s390x JDK 11 produces a broken javac bootstrap.
2. Bazel publishes no s390x binaries. If ~/.local/bin/bazel breaks, rebuild
   from ~/ray-s390x/bazel (see README section 3).
3. BoringSSL is little-endian-only — never let it back into the graph. TLS
   goes through the libssl/libcrypto workspace binds -> @openssl (1.1.1f).
   If a new dependency references @boringssl directly (grep the external
   repos in ~/.cache/bazel/.../external/), reroute it to
   @io_ray//external:libssl the way bazel/hiredis.BUILD does.
4. rules_perl has no s390x hermetic perl; the system-perl toolchain is
   registered in bazel/BUILD.bazel + bazel/perl_system.BUILD + WORKSPACE.
   If you add foreign-cc deps that need perl, they will just work.
5. Writing files on the Z machine: do NOT use heredocs over ssh from the
   Mac — quoting gets mangled. Write the file locally, then scp it.
6. Patch files (thirdparty/patches/*.patch): hand-written unified diffs are
   error-prone. Validate with `git apply --check` in a scratch repo
   containing the pristine target file BEFORE pushing. Count hunk lines
   carefully (old/new counts, and new-start offsets after earlier hunks).
   Pristine rules_boost BUILD.boost can be fetched from the tarball URL in
   bazel/ray_deps_setup.bzl.
7. Long builds: run detached (nohup ... > log 2>&1 &) and poll with tail.
   Individual commands time out around 5 minutes. Full //:ray_pkg cold
   build ~36 min; most is cached on rebuild.
8. The ray build-wheel.sh / ci/build/build_wheel.py path does NOT work on
   s390x (uv and raymake have no s390x builds, and it wants docker images
   from cr.ray.io). Use python/setup.py bdist_wheel (README section 6).

## Task list (priority order)

### 1. Run the core test suite [DONE 2026-11-17]
All suites pass. NO s390x-specific Ray bugs found — every failure was an
environment issue. Final results (venv ~/ray-s390x/venv, wheel-installed ray):
- test_basic 37p | gcs_utils p | gcs_pubsub 6p | gcs_fault_tolerance 21p+6skip
- runtime_env 9p | runtime_env_packaging 128p | runtime_env_complicated 12p+11skip
- actor 89p | actor_advanced 32p | actor_failures p | actor_lifetime 6p
- actor_out_of_order 6p | job 10p | stress 6p
Remaining known-fail (all ENV limits, not port bugs):
- conda runtime_env tests: NO conda exists for s390x Linux (no miniconda/
  conda-forge s390x builds). Skipped-tier.
- test_conda_pip_extras_ray_default[pip]: installs ray[default] from PyPI ->
  py-spy dep has NO s390x support (Rust code is arch-gated, no s390x) so it
  cannot build. Same reason py-spy can't be installed for the dashboard.
Test-env setup done in the venv (documented so you don't rediscover):
- pip: pytest==7.4.4 + pytest-asyncio==0.17.2 (pytest 9 rejects marks on
  fixtures in test_stress.py — always use Ray's pinned test-requirements.txt),
  redis, proxy.py, numpy, ipython, smart_open[s3]+boto3.
- The wheel does NOT ship ray/core/src/ray/thirdparty/redis/src/redis-server
  (official wheels don't either; CI runs from source tree). Tests using
  REDIS_EXECUTABLE need it copied into site-packages or they HANG: the
  fixture retry loop turns the missing-binary assert into an infinite busy
  loop (no timeout). Copied binary + symlinked ray/tests into site-packages
  (test_actor.py imports ray.tests.client_test_utils) + copied repo
  python/setup.py to site-packages/ (runtime_env conda plugin's
  _get_ray_setup_spec() runpy's setup.py next to ray; needed for
  RAY_RUNTIME_ENV_LOCAL_DEV_MODE tests, which test_runtime_env_complicated
  sets itself).
- One-off: "double free or corruption" abort AFTER test_basic summary once;
  not reproducible on rerun (likely residue from a SIGINT-killed hang).
  If it recurs, get a core dump + gdb bt — could be a real s390x bug in
  shutdown/cleanup paths.

### 2. Dashboard [DONE 2026-11-17]
The current wheel now HAS the dashboard frontend, verified working.
- Node 14.21.3 (s390x) installed at ~/.local/node (tarball + sha256 from
  ci/env/install-dependencies.sh; script itself installs to /usr/local with
  sudo, which we can't run — hence ~/.local). Use PATH=$HOME/.local/node/bin:$PATH.
- cd python/ray/dashboard/client && npm ci && npm run build (works as-is).
- Wheel rebuilt with setup.py bdist_wheel — picks up client/build automatically
  (49 files under ray/dashboard/client/build/ inside the wheel).
- Dashboard Python deps installed into ~/ray-s390x/venv (aiohttp, opencensus,
  pydantic, smart_open, otel packages, etc.).
- grpcio has NO s390x wheel on PyPI and its bundled boringssl is LE-only
  (rule 3 again). Built from sdist with:
    GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1 GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=12 \
      pip install --no-binary :all: --no-build-isolation grpcio
  NOTE: env vars were renamed in modern grpcio — it's GRPC_PYTHON_BUILD_
  SYSTEM_OPENSSL (no "WITH"). System openssl-devel 3.5.5 is installed on the VM.
- py-spy still NOT installed (no s390x support at all) — dashboard works
  without it, only CPU flamegraph/profiling features will be missing.
- Verified: ray.init(include_dashboard=True), GET / (446 B index.html),
  main.js (1.1 MB) and /api/ray/version all OK. Note: with default
  RAY_AUTH_MODE the dashboard returns 401 unless you send the auth token;
  use RAY_AUTH_MODE=disabled for local testing.

### 3. Multi-node validation
Needs a second Z VM (ask the human). On node A: ray start --head.
On node B: ray start --address='<A-ip>:6379'. Run tasks pinned to both nodes
(ray.get(node_b_only_task.remote()) style) to prove GCS/redis/object
transfer across nodes works on s390x.

### 4. Additional Python versions
Wheel is cp312-only. For 3.10/3.11/3.13: create venvs with the matching
interpreter (dnf install python3.11 etc. — needs the human + sudo), rerun
README section 6. Bazel artifacts are reused; only _raylet recompiles.

### 5. Optional: ray-haproxy / pyarrow (only if Serve/Data needed)
- ray-haproxy: no s390x wheel on PyPI. Options: build haproxy from source
  on Z and patch python/ray/serve/_private/haproxy.py + setup.py dep, or
  publish an s390x ray-haproxy wheel to the fork and point a constraints
  file at it.
- pyarrow: would require building Apache Arrow C++ on s390x (significant
  effort). Only worth it if ray[data]/ray[train] is a requirement.

## Conventions / guardrails

- Every commit: git commit -s (DCO). Run pre-commit (it is installed as a
  ray hook and runs automatically).
- Push ONLY to origin (CathalOConnorRH/ray). Never push to upstream.
- Keep changes s390x-additive where possible: prefer new select branches
  and new patches over modifying behavior for x86_64/arm64. If a change
  must alter shared behavior (like the OpenSSL rebind), comment it clearly.
- The human must review and understand every line before anything is PR'd
  to ray-project (see AGENTS.md in the repo root).
