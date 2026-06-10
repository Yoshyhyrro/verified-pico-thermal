{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Development.Shake
import Development.Shake.Command
import Development.Shake.FilePath
import Development.Shake.Util
import System.Directory (createDirectoryIfMissing)
import qualified System.Directory as Dir
import System.FilePath ((</>))
import Control.Monad (when, forM_)
import System.Log.Logger
import System.Process (callCommand)
import System.Log.Handler.Simple (streamHandler)
import System.IO (stdout)
import Data.List (isPrefixOf)

-- Initialize the logger
-- streamHandler does not expose 'streamHandlerFormat' as a record field;
-- just attach the handler directly.
initLogger :: IO ()
initLogger = do
  handler <- streamHandler stdout INFO
  updateGlobalLogger rootLoggerName (setLevel INFO . setHandlers [handler])

-- Check if the current OS is Ubuntu 26.x
-- It reads /etc/os-release to determine the OS ID and Version.
checkUbuntu26 :: IO Bool
checkUbuntu26 = do
  let osReleasePath = "/etc/os-release"
  exists <- Dir.doesFileExist osReleasePath
  if exists
    then do
      contents <- readFile osReleasePath
      let ls = lines contents
          isUbuntu = any (\l -> l == "ID=ubuntu" || l == "ID=\"ubuntu\"") ls
          is26 = any (\l -> "VERSION_ID=\"26" `isPrefixOf` l || "VERSION_ID=26" `isPrefixOf` l) ls
      return (isUbuntu && is26)
    else return False

main :: IO ()
main = do
  initLogger
  putStrLn "=== Thermal Camera Shake Build System ==="
  putStrLn "Stack-managed build started..."

  -- Detect Ubuntu 26
  isU26 <- checkUbuntu26
  if isU26
    then putStrLn "Notice: Ubuntu 26 detected! Applying specific configurations..."
    else putStrLn "Notice: Standard/Other OS detected."

  -- NOTE: Do NOT redefine ShakeOptions here; use Shake's built-in type.
  shakeArgs shakeOptions { shakeFiles = "_shake" } $ do

    -- ============================================
    -- Rule definitions
    -- ============================================

    -- Initialisation rule
    phony "init" $ do
      putNormal "Initializing project directories..."
      liftIO initDirectories
      -- Pass the OS detection flag to generate OS-specific configurations
      liftIO $ generateTemplateFiles isU26
      putNormal "Project initialized successfully"

    -- Chisel -> Verilog conversion
    "verilog/generated/*.v" %> \out -> do
      let moduleName = takeBaseName out
      putNormal $ "Generating Verilog for " ++ moduleName

      -- Confirm the Chisel project exists
      need ["chisel/build.sbt"]

      -- Run sbt
      -- Cwd changes the working directory for this cmd_ call without going
      -- through a shell. Using "cd chisel && sbt ..." would fail because
      -- Shake's cmd_ calls execvp directly and cd is a shell builtin.
      cmd_ (Cwd "chisel") ("sbt" :: String) ("runMain top." ++ moduleName)

      -- Copy generated file to output location
      let generatedPath = "chisel/generated/" ++ moduleName ++ ".v"
      exists <- doesFileExist generatedPath   -- Shake's Action-level doesFileExist; no liftIO needed
      when exists $ copyFile' generatedPath out

    -- C++ project build
    -- cmake builds both the testbench and libmlx90640_model.so in one pass
    -- because the testbench target links against the shared library.
    -- -DUBUNTU_26=ON activates the C++26 branch in CMakeLists.txt.
    "build/testbench" %> \out -> do
      let buildDir = "cpp/build"
      need [ "cpp/CMakeLists.txt"
           , "cpp/src/testbench.cpp"
           , "cpp/src/mlx90640_model.cpp"
           , "cpp/include/mlx90640_model.h"
           ]
      putNormal "Building C++ testbench and shared library..."
      let u26Flag = if isU26 then " -DUBUNTU_26=ON" else ""
      cmd_ $ "cmake -B " ++ buildDir ++ " -S cpp -DCMAKE_BUILD_TYPE=Release" ++ u26Flag
      cmd_ $ "cmake --build " ++ buildDir ++ " -j4"
      copyFile' (buildDir </> "testbench") out

    -- Shared library artifact
    -- Depends on "build/testbench" so the cmake build always runs first.
    -- libmlx90640_model.so lands in cpp/build/lib/ via LIBRARY_OUTPUT_DIRECTORY.
    "build/lib/libmlx90640_model.so" %> \out -> do
      need ["build/testbench"]
      let soSrc = "cpp/build" </> "lib" </> "libmlx90640_model.so"
      exists <- doesFileExist soSrc
      if exists
        then copyFile' soSrc out
        else error "libmlx90640_model.so not found; cmake may have produced a static build"

    -- Chisel -> FIRRTL intermediate representation
    -- ChiselStage emits .fir alongside .v when --emission-options
    -- emitIntermediateFiles is passed, so we first ensure the Verilog rule
    -- has run (same sbt invocation), then copy the .fir from chisel/generated/.
    -- If the .fir is missing (App object does not pass the flag), a fallback
    -- sbt run explicitly requests FIRRTL emission.
    "firrtl/generated/*.fir" %> \out -> do
      let moduleName = takeBaseName out
      need ["verilog/generated/" ++ moduleName ++ ".v"]
      let firSrc = "chisel/generated/" ++ moduleName ++ ".fir"
      exists <- doesFileExist firSrc
      if exists
        then do
          putNormal $ "Copying FIRRTL for " ++ moduleName
          copyFile' firSrc out
        else do
          putNormal $ "Emitting FIRRTL for " ++ moduleName ++ " (fallback sbt run)..."
          need ["chisel/build.sbt"]
          cmd_ (Cwd "chisel") ("sbt" :: String)
                 ("runMain top." ++ moduleName
                  ++ " --target-dir generated --emission-options emitIntermediateFiles")
          existsAfter <- doesFileExist firSrc
          when existsAfter $ copyFile' firSrc out

    -- Run tests
    phony "test" $ do
      need ["build/testbench"]
      putNormal "Running tests..."
      cmd_ (AddEnv "LANG" "C.UTF-8") ("build/testbench" :: String)

    -- Run simulation (requires both Verilog and FIRRTL for the two RTL modules)
    phony "sim" $ do
      let modules = ["I2CMaster", "ThermalNormalizer"]
      need $  ["build/testbench"]
           ++ map (\m -> "verilog/generated/" ++ m ++ ".v")   modules
           ++ map (\m -> "firrtl/generated/"  ++ m ++ ".fir") modules
      putNormal "Running simulation..."
      cmd_ (AddEnv "LANG" "C.UTF-8") ("build/testbench --verilog verilog/generated/" :: String)

    -- Collect release artifacts into dist/ and create a tarball
    -- Artifacts included:
    --   dist/lib/libmlx90640_model.so   -- C++26 shared library
    --   dist/include/mlx90640_model.h   -- public header
    --   dist/verilog/<Module>.v         -- Chisel-generated RTL
    --   dist/firrtl/<Module>.fir        -- FIRRTL intermediate
    --   dist/verified-pico-thermal.tar.gz
    phony "release" $ do
      let modules = ["I2CMaster", "ThermalNormalizer"]
      need $  [ "build/lib/libmlx90640_model.so"
              , "build/testbench"
              ]
           ++ map (\m -> "verilog/generated/" ++ m ++ ".v")   modules
           ++ map (\m -> "firrtl/generated/"  ++ m ++ ".fir") modules

      putNormal "Staging release artifacts into dist/..."
      copyFile' "build/lib/libmlx90640_model.so"  "dist/lib/libmlx90640_model.so"
      copyFile' "cpp/include/mlx90640_model.h"    "dist/include/mlx90640_model.h"

      forM_ modules $ \m -> do
        copyFile' ("verilog/generated/" ++ m ++ ".v")   ("dist/verilog/" ++ m ++ ".v")
        copyFile' ("firrtl/generated/"  ++ m ++ ".fir") ("dist/firrtl/"  ++ m ++ ".fir")

      -- :: String annotation is required because OverloadedStrings makes bare
      -- literals polymorphic; cmd_ cannot resolve IsCmdArgument without it.
      cmd_ ("tar -czf dist/verified-pico-thermal.tar.gz -C dist lib include verilog firrtl" :: String)
      putNormal "Release artifact ready: dist/verified-pico-thermal.tar.gz"

    -- Clean all build artifacts including release staging
    phony "clean" $ do
      putNormal "Cleaning build artifacts..."
      liftIO $ callCommand
        "rm -rf build/ verilog/generated/ firrtl/generated/ cpp/build/ chisel/generated/ dist/"
      removeFilesAfter "_shake" ["*"]

    -- CI target
    phony "ci" $ do
      need ["init", "test", "release"]
      putNormal "CI build completed successfully"

    -- Default targets
    want ["init", "test"]

-- ============================================
-- Helper functions
-- ============================================

initDirectories :: IO ()
initDirectories = do
  let dirs = [ "chisel/src/main/scala/i2c"
             , "chisel/src/main/scala/thermal"
             , "chisel/src/main/scala/top"
             , "chisel/project"
             , "cpp/include"
             , "cpp/src"
             , "cpp/build"
             , "scripts"
             , "verilog/generated"
             , "build"
             , "build/lib"        -- shared library output (.so)
             , "firrtl/generated" -- FIRRTL intermediate representation
             , "dist"             -- release artifact staging area
             , "dist/lib"
             , "dist/include"
             , "dist/verilog"
             , "dist/firrtl"
             ]
  forM_ dirs $ \dir -> do
    putStrLn $ "  Creating: " ++ dir
    createDirectoryIfMissing True dir

generateTemplateFiles :: Bool -> IO ()
generateTemplateFiles isU26 = do
  putStrLn "Generating template files..."

  -- build.sbt
  writeFile "chisel/build.sbt" $ unlines
    [ "scalaVersion := \"2.13.12\""
    , "libraryDependencies += \"edu.berkeley.cs\" %% \"chisel3\" % \"3.6.0\""
    , "libraryDependencies += \"edu.berkeley.cs\" %% \"chiseltest\" % \"0.6.0\" % \"test\""
    , "scalacOptions ++= Seq(\"-Xsource:2.13\", \"-deprecation\", \"-feature\")"
    ]

  -- CMakeLists.txt
  -- On Ubuntu 26 the system ships GCC 15 / Clang 19 with C++26 support.
  -- The shared library is built with POSITION_INDEPENDENT_CODE so it can be
  -- dlopen'd at runtime; the testbench links against it dynamically.
  let cxxStd = if isU26 then "26" else "17" :: String
  writeFile "cpp/CMakeLists.txt" $ unlines $
    [ "cmake_minimum_required(VERSION 3.16)"
    , "project(ThermalCameraTest)"
    , ""
    , "# C++ standard: C++26 on Ubuntu 26, C++17 elsewhere"
    , "option(UBUNTU_26 \"Build with Ubuntu 26 / C++26 settings\" OFF)"
    , "if(UBUNTU_26)"
    , "  set(CMAKE_CXX_STANDARD 26)"
    , "else()"
    , "  set(CMAKE_CXX_STANDARD " ++ cxxStd ++ ")"
    , "endif()"
    , "set(CMAKE_CXX_STANDARD_REQUIRED ON)"
    , ""
    , "include_directories(include)"
    , ""
    , "# Shared library: MLX90640 thermal sensor I2C model"
    , "# POSITION_INDEPENDENT_CODE is required for .so output."
    , "add_library(mlx90640_model SHARED"
    , "    src/mlx90640_model.cpp"
    , ")"
    , "target_include_directories(mlx90640_model PUBLIC include)"
    , "set_target_properties(mlx90640_model PROPERTIES"
    , "    POSITION_INDEPENDENT_CODE ON"
    , "    LIBRARY_OUTPUT_DIRECTORY \"${CMAKE_BINARY_DIR}/lib\""
    , ")"
    , ""
    , "# Testbench executable: links against the shared library"
    , "add_executable(testbench"
    , "    src/testbench.cpp"
    , ")"
    , "target_link_libraries(testbench PRIVATE mlx90640_model pthread)"
    ]

  -- Template header
  writeFile "cpp/include/mlx90640_model.h" $ unlines
    [ "#pragma once"
    , "#include <cstdint>"
    , "#include <vector>"
    , ""
    , "class MLX90640Model {"
    , "public:"
    , "    MLX90640Model();"
    , "    bool i2cWrite(uint8_t addr, uint8_t reg, uint8_t data);"
    , "    bool i2cRead(uint8_t addr, uint8_t reg, std::vector<uint8_t>& data, size_t len);"
    , "private:"
    , "    uint8_t regs[256];"
    , "};"
    ]

  -- Template implementation
  writeFile "cpp/src/mlx90640_model.cpp" $ unlines
    [ "#include \"mlx90640_model.h\""
    , "#include <cstring>"
    , ""
    , "MLX90640Model::MLX90640Model() {"
    , "    std::memset(regs, 0, sizeof(regs));"
    , "}"
    , ""
    , "bool MLX90640Model::i2cWrite(uint8_t addr, uint8_t reg, uint8_t data) {"
    , "    if (addr == 0x33) { regs[reg] = data; return true; }"
    , "    return false;"
    , "}"
    , ""
    , "bool MLX90640Model::i2cRead(uint8_t addr, uint8_t reg, std::vector<uint8_t>& data, size_t len) {"
    , "    if (addr != 0x33) return false;"
    , "    data.resize(len);"
    , "    for (size_t i = 0; i < len && (reg + i) < 256; i++) {"
    , "        data[i] = regs[reg + i];"
    , "    }"
    , "    return true;"
    , "}"
    ]

  -- Testbench
  writeFile "cpp/src/testbench.cpp" $ unlines
    [ "#include <iostream>"
    , "#include \"mlx90640_model.h\""
    , ""
    , "int main(int argc, char** argv) {"
    , "    MLX90640Model sensor;"
    , "    sensor.i2cWrite(0x33, 0x01, 0x42);"
    , "    std::vector<uint8_t> data;"
    , "    sensor.i2cRead(0x33, 0x01, data, 1);"
    , "    if (data[0] == 0x42) {"
    , "        std::cout << \"PASS: I2C test\" << std::endl;"
    , "        return 0;"
    , "    }"
    , "    std::cout << \"FAIL: I2C test\" << std::endl;"
    , "    return 1;"
    , "}"
    ]

  -- .gitignore
  writeFile ".gitignore" $ unlines
    [ "*.o"
    , "*.hi"
    , "*.vcd"
    , "build/"
    , "cpp/build/"
    , "verilog/generated/"
    , "chisel/generated/"
    , ".stack-work/"
    , "_shake/"
    , "bin/"
    , "dist/"
    ]

  -- README
  writeFile "README.md" $ unlines
    [ "# Thermal Camera with Chisel + Shake"
    , ""
    , "## Setup"
    , "```bash"
    , "cd shake"
    , "stack build"
    , "stack exec shake-build init"
    , "stack exec shake-build test"
    , "```"
    ]