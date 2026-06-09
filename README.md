# verified-pico-thermal

A Haskell library that uses an SMT solver to classify pixels in a thermal camera frame, distinguishing animal body heat from ground background and solar reflections.
<s>The project also integrates a Chisel hardware module ([Siunertaq](https://github.com/Yoshyhyrro/Siunertaq)) compiled through SBT, with a Shake-based build system orchestrating the full pipeline.</s>

---

## How it works

Pixel classification is framed as a satisfiability problem.
For each frame the library declares one SMT Boolean variable per pixel and three integer variables representing the representative temperatures of animals, ground, and solar reflections, then asserts:

| Constraint class | What it encodes |
|---|---|
| **Measurement** | Each pixel's measured temperature must lie within ±3 °C of the animal temperature (if classified as animal) or must not exceed the solar temperature (if background). |
| **Physical knowledge base** | Animal body temperature 35–44 °C, ground 15–50 °C, solar reflection 45–80 °C; animal warmer than ground by ≥3 °C; solar spike hotter than animal by ≥8 °C. |
| **Spatial smoothing** | Adjacent pixels whose measured temperatures differ by ≤5 °C must be assigned the same class. |
| **Minimum region size** | At least 4 pixels must be classified as animal (rejects single-pixel noise). |

The Yices2 solver is invoked via [hasmtlib](https://hackage.haskell.org/package/hasmtlib) (`interactiveWith yices`).
If the problem is satisfiable, `getValue` retrieves the Boolean assignment for every pixel.

Two pre-processing stages run before the SMT call:

1. **Solar reflection filter** — a pixel is flagged as a solar hot-spot when its temperature is ≥50 °C **and** it is ≥20 °C hotter than the average of its cool (< 50 °C) 8-neighbours. Flagged pixels are zeroed before the SMT problem is built.
2. **Temporal filter** — when a frame history is available, pixels whose temperature changed by more than 3 °C since the previous frame are masked out as non-animal (solar reflections change rapidly; animal body heat does not).

---

## Project structure

```
.
├── src/
│   └── ThermalSMT.hs          # Library: SMT analysis pipeline
├── app/
│   └── Main.hs                # Shake build rules (C++ testbench + Chisel)
├── test/
│   └── Spec.hs                # tasty-hunit test suite (3 tests)
├── package.yaml               # hpack manifest
├── stack.yaml                 # Stack resolver + extra-deps
└── .github/workflows/ci.yml  # GitHub Actions CI
```

### Key functions (`ThermalSMT`)

| Function | Description |
|---|---|
| `analyzeThermalImage` | Top-level pipeline: runs all three stages and returns `AnimalDetectionResult`. |
| `inferAnimalRegion` | SMT core: asserts all constraints, calls Yices2, extracts the pixel mask. |
| `detectSolarReflection` | Pure Haskell hot-spot filter (no solver involved). |
| `temporalFilter` | Pure Haskell stability filter over a list of past frames. |

### Result type

```haskell
data AnimalDetectionResult = AnimalDetectionResult
    { resultMask            :: [Bool]    -- True = animal pixel
    , animalTemperatureMean :: Double    -- °C (mean over animal pixels)
    , animalTemperatureMin  :: Double
    , animalTemperatureMax  :: Double
    , solarReflections      :: [Int]     -- pixel indices flagged as solar
    }
```

Temperature values are stored as `TempScaled = Int` (°C × 10) inside the vector; the result converts them back to `Double` °C.

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| GHC | 9.10.3 | via Stack |
| Stack | any recent | [haskellstack.org](https://docs.haskellstack.org/) |
| Yices2 | 2.6+ | SMT solver, see install note below |
| JDK | 17 (Temurin) | required for Chisel / SBT |
| SBT | any recent | [scala-sbt.org](https://www.scala-sbt.org/) |
| CMake + C++ | — | for the C++ testbench |

**Installing Yices2 on Ubuntu/Debian:**

```bash
sudo add-apt-repository ppa:sri-csl/formal-methods -y
sudo apt-get update
sudo apt-get install -y yices2
yices --version   # verify
```

---

## Getting started

```bash
# 1. Clone
git clone https://github.com/<your-org>/verified-pico-thermal.git
cd verified-pico-thermal

# 2. Initialise the Shake workspace (generates template Chisel / C++ stubs)
stack run init

# 3. (Optional) replace the stub with the real Chisel project
rm -rf chisel
git clone https://github.com/Yoshyhyrro/Siunertaq.git chisel

# 4. Build and run all tests
stack test
```

### Running only the Haskell unit tests

```bash
stack test --test-arguments "--pattern /Thermal SMT Tests/"
```

### Running only the Chisel compilation

```bash
cd chisel
sbt compile
```

---

## Shake build targets

The `shake-build` executable wraps the full build pipeline.

```bash
stack run shake-build -- <target>
```

| Target | What it does |
|---|---|
| `build` | Compiles the C++ testbench with CMake. |
| `test` | Runs the compiled testbench binary. |
| `sim` | Runs the testbench against generated Verilog. |
| `verilog` | Runs `sbt` to compile Chisel → Verilog under `verilog/generated/`. |
| `clean` | Removes build artefacts. |

---

## Test suite

Three tests in `test/Spec.hs`, run with `stack test`:

| Test | What it checks |
|---|---|
| Animal body temperature range | `inferAnimalRegion` returns `Just mask` with ≥ 4 animal pixels when given a frame containing known 37 °C pixels. |
| Exclude solar reflection | `detectSolarReflection` flags all 60 °C hot-spot pixels in a 500-pixel background frame. |
| Temporal consistency | `temporalFilter` correctly separates stable pixels from rapidly-changing ones across two frames. |

---

## Dependencies

Core Haskell libraries (see `package.yaml` for full version bounds):

- **hasmtlib** ≥ 2.8.1 — SMT modelling and Yices2 interface
- **vector** ≥ 0.13 — thermal frame storage
- **shake** ≥ 0.19.3 — build system DSL
- **tasty** + **tasty-hunit** — test framework

---

## License

GPL-3.0-only — see [LICENSE](LICENSE).

Author: Yoshihiro Hasegawa
