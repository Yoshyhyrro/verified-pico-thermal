#!/usr/bin/env bash
# =============================================================================
# setup.bash
#
# Installs system dependencies and arranges the project layout for the
# verified-pico-thermal build pipeline.
#
# What this script does:
#   1. Install APT packages  : cmake / g++ / z3 / libz3-dev / Yices2
#   2. Install JDK 17        : required by sbt, Chisel, and Siunertaq
#   3. Install sbt           : Scala build tool
#   4. Clone Siunertaq       : into siunertaq/ (never into chisel/)
#   5. Initialise Shake      : generates chisel/ skeleton + cpp/ templates
#   6. Deploy Chisel RTL     : cp shake/test/Chisel/**/*.scala → chisel/src/
#   7. Compile Chisel        : sbt compile (Scala 2.13 + chisel3)
#   8. Compile Siunertaq     : sbt compile (Scala 3.8 + Z3/Yices bridges)
#   9. Verify Siunertaq      : threshold tests + Yices smoke suite
#  10. Run Haskell SMT tests : stack test (hasmtlib + Yices2)
#
# Usage (from repository root):
#   bash setup.bash
#
# This script is idempotent: safe to re-run after partial failures.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIUNERTAQ_DIR="$REPO_ROOT/siunertaq"
CHISEL_DIR="$REPO_ROOT/chisel"
CHISEL_SRC="$CHISEL_DIR/src/main/scala"
# Committed home for hand-written Chisel RTL sources
RTL_SRC="$REPO_ROOT/shake/test/Chisel"

echo "=== verified-pico-thermal setup ==="
echo "    repo root : $REPO_ROOT"
echo ""

# =============================================================================
# 1. APT system packages
# =============================================================================
echo ">>> [1/10] Installing APT packages..."
sudo apt-get update -qq

# C++17 toolchain for the MLX90640 I2C testbench (cmake + g++)
sudo apt-get install -y cmake g++ build-essential

# Z3 SMT solver binary + shared library (required by Siunertaq z3-bridge JNI)
# io.github.p-org.solvers:z3 on Maven bundles libz3java.so, but libz3.so must
# be present on the system for the JNI wrapper to dlopen correctly.
sudo apt-get install -y z3 libz3-dev

# Yices 2 (required by hasmtlib in Haskell stack test AND by Siunertaq yices-bridge)
# The PPA provides yices-smt2, which is the SMT-LIB2 subprocess binary.
sudo apt-get install -y software-properties-common
sudo add-apt-repository ppa:sri-csl/formal-methods -y
sudo apt-get update -qq
sudo apt-get install -y yices2

echo "    z3      : $(z3 --version | head -1)"
echo "    yices   : $(yices --version | head -1)"

# =============================================================================
# 2. JDK 17 (Temurin)
# =============================================================================
echo ">>> [2/10] Checking JDK..."

need_jdk=true
if command -v java &>/dev/null; then
  jdk_ver=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
  if [ "${jdk_ver:-0}" -ge 17 ] 2>/dev/null; then
    echo "    JDK $jdk_ver already installed — skipping"
    need_jdk=false
  fi
fi

if $need_jdk; then
  echo "    Installing Eclipse Temurin 17..."
  sudo apt-get install -y wget apt-transport-https gnupg
  wget -q -O /tmp/adoptium.gpg \
    https://packages.adoptium.net/artifactory/api/gpg/key/public
  sudo mkdir -p /etc/apt/keyrings
  sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg /tmp/adoptium.gpg
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/adoptium.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y temurin-17-jdk
fi

java -version 2>&1 | head -1 | sed 's/^/    /'

# =============================================================================
# 3. sbt
# =============================================================================
echo ">>> [3/10] Checking sbt..."

if ! command -v sbt &>/dev/null; then
  echo "    sbt not found — installing from Scala repo..."
  echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" \
    | sudo tee /etc/apt/sources.list.d/sbt.list >/dev/null
  curl -sL \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" \
    | sudo apt-key add - 2>/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y sbt
else
  echo "    sbt already installed — skipping"
fi

sbt --version 2>&1 | head -1 | sed 's/^/    /'

# =============================================================================
# 4. Clone / update Siunertaq into siunertaq/
#
# Siunertaq is a Scala 3 SMT verification framework (Z3 + Yices bridges).
# It is NOT a Chisel project and must NOT be placed in chisel/.
# The two directories serve entirely different purposes:
#   chisel/     — Chisel3 RTL (Scala 2.13, sbt chisel3/chiseltest)
#   siunertaq/  — BSD quiver + threshold verifier (Scala 3.8, Z3/Yices)
# =============================================================================
echo ">>> [4/10] Setting up Siunertaq at siunertaq/..."

if [ ! -d "$SIUNERTAQ_DIR/.git" ]; then
  git clone https://github.com/Yoshyhyrro/Siunertaq.git "$SIUNERTAQ_DIR"
else
  echo "    Already cloned — pulling latest..."
  git -C "$SIUNERTAQ_DIR" pull --ff-only
fi

# =============================================================================
# 5. Initialise the Shake project skeleton
#
# stack exec shake-build -- init runs the "init" phony rule in Main.hs which:
#   - Creates chisel/src/main/scala/{i2c,thermal,top}/, cpp/build/, etc.
#   - Writes chisel/build.sbt (Scala 2.13 + chisel3 3.6.0 + chiseltest 0.6.0)
#   - Writes cpp/CMakeLists.txt, mlx90640_model.h/cpp, testbench.cpp stubs
#
# This must run BEFORE step 6 so that the target directories exist.
# The || true guard preserves idempotency if run more than once.
# =============================================================================
echo ">>> [5/10] Initialising Shake project skeleton..."
(cd "$REPO_ROOT" && stack exec shake-build -- init) || true

# =============================================================================
# 6. Deploy Chisel RTL sources from shake/test/Chisel/ into chisel/src/
#
# shake/test/Chisel/ is the committed home for hand-written Chisel hardware.
# Layout mirrors chisel/src/main/scala/ so cp commands are straightforward.
#
#   shake/test/Chisel/i2c/     → chisel/src/main/scala/i2c/
#   shake/test/Chisel/thermal/ → chisel/src/main/scala/thermal/
#   shake/test/Chisel/top/     → chisel/src/main/scala/top/
#   shake/test/Chisel/*.scala  → chisel/src/main/scala/top/  (flat fallback)
#
# Shake's verilog/generated/*.v rule runs:
#   cd chisel && sbt "runMain top.<ModuleName>"
# so each RTL module must have an App object in package top.
# =============================================================================
echo ">>> [6/10] Deploying Chisel RTL sources..."

deploy_dir() {
  local src="$1" dst="$2"
  if compgen -G "$src/*.scala" &>/dev/null; then
    echo "    cp $src/*.scala  →  $dst/"
    cp -v "$src"/*.scala "$dst/"
  else
    echo "    (no .scala files in $src — skipping)"
  fi
}

deploy_dir "$RTL_SRC/i2c"    "$CHISEL_SRC/i2c"
deploy_dir "$RTL_SRC/thermal" "$CHISEL_SRC/thermal"
deploy_dir "$RTL_SRC/top"    "$CHISEL_SRC/top"

# Flat .scala files at the root of shake/test/Chisel/ go to top/ as a fallback
if compgen -G "$RTL_SRC/*.scala" &>/dev/null; then
  echo "    cp $RTL_SRC/*.scala  →  $CHISEL_SRC/top/  (flat fallback)"
  cp -v "$RTL_SRC"/*.scala "$CHISEL_SRC/top/"
fi

# =============================================================================
# 7. Compile Chisel RTL (sbt compile, not sbt test)
#
# sbt test would run chiseltest suites; we defer that to CI.
# =============================================================================
echo ">>> [7/10] Compiling Chisel RTL (Scala 2.13 + chisel3)..."
(cd "$CHISEL_DIR" && sbt compile)

# =============================================================================
# 8. Compile Siunertaq (Scala 3.8 + Pekko + Z3/Yices/Dhall/MLIR bridges)
#
# Z3_LIB_PATH points sbt to the system libz3.so installed in step 1.
# On Ubuntu the shared library lands in /usr/lib/x86_64-linux-gnu/.
# =============================================================================
echo ">>> [8/10] Compiling Siunertaq..."
export Z3_LIB_PATH=/usr/lib/x86_64-linux-gnu
(cd "$SIUNERTAQ_DIR" && sbt compile)

# =============================================================================
# 9. Run Siunertaq verification tests
#
# Two independent solver lanes (from the README):
#   core/testOnly io.siunertaq.threshold.*  — threshold + expression IR tests
#   yicesBridge/test                        — Yices 2 SMT-LIB2 cross-check
#
# RUN_YICES_SMOKE=1 activates the full smoke suite in the Yices bridge.
# z3Bridge/compile is listed separately because the JNI runtime test
# requires libz3java.so which may not be present in all environments.
# =============================================================================
echo ">>> [9/10] Running Siunertaq threshold + Yices verification..."
(
  cd "$SIUNERTAQ_DIR"
  export Z3_LIB_PATH=/usr/lib/x86_64-linux-gnu
  export RUN_YICES_SMOKE=1
  sbt \
    "core/testOnly io.siunertaq.threshold.*" \
    "z3Bridge/compile" \
    "yicesBridge/test"
)

# =============================================================================
# 10. Run Haskell SMT tests via stack test
#
# shake/src/ThermalSMT.hs uses hasmtlib to call the Yices2 solver that
# was installed in step 1.  shake/test/Spec.hs is the test entry point.
# =============================================================================
echo ">>> [10/10] Running Haskell SMT tests (hasmtlib + Yices2)..."
(cd "$REPO_ROOT" && stack test)

# =============================================================================
echo ""
echo "=== setup.bash completed ==="
echo ""
echo "  Chisel RTL  : $CHISEL_DIR"
echo "  Siunertaq   : $SIUNERTAQ_DIR"
echo "  Z3_LIB_PATH : $Z3_LIB_PATH"
echo ""
echo "Next steps:"
echo "  Add Chisel RTL to shake/test/Chisel/{i2c,thermal,top}/"
echo "  Run Verilog generation : stack exec shake-build -- sim"
echo "  Clean build artifacts  : stack exec shake-build -- clean"