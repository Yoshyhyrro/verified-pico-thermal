{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Development.Shake
import Development.Shake.Command
import Development.Shake.FilePath
import Development.Shake.Util
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Control.Monad (when, forM_)
import System.Log.Logger
import System.Process (callCommand)
import System.Log.Handler.Simple (streamHandler)
import System.IO (stdout)

-- Initialize the logger
-- streamHandler does not expose 'streamHandlerFormat' as a record field;
-- just attach the handler directly.
initLogger :: IO ()
initLogger = do
  handler <- streamHandler stdout INFO
  updateGlobalLogger rootLoggerName (setLevel INFO . setHandlers [handler])

main :: IO ()
main = do
  initLogger
  putStrLn "=== Thermal Camera Shake Build System ==="
  putStrLn "Stack-managed build started..."

  -- NOTE: Do NOT redefine ShakeOptions here; use Shake's built-in type.
  shakeArgs shakeOptions { shakeFiles = "_shake" } $ do

    -- ============================================
    -- Rule definitions
    -- ============================================

    -- Initialisation rule
    phony "init" $ do
      putNormal "Initializing project directories..."
      liftIO initDirectories
      liftIO generateTemplateFiles
      putNormal "Project initialized successfully"

    -- Chisel -> Verilog conversion
    "verilog/generated/*.v" %> \out -> do
      let moduleName = takeBaseName out
      putNormal $ "Generating Verilog for " ++ moduleName

      -- Confirm the Chisel project exists
      need ["chisel/build.sbt"]

      -- Run sbt
      cmd_ $ "cd chisel && sbt \"runMain top." ++ moduleName ++ "\""

      -- Copy generated file to output location
      let generatedPath = "chisel/generated/" ++ moduleName ++ ".v"
      exists <- doesFileExist generatedPath   -- Shake's Action-level doesFileExist; no liftIO needed
      when exists $ copyFile' generatedPath out

    -- C++ project build
    "build/testbench" %> \out -> do
      let buildDir = "cpp/build"
      need [ "cpp/CMakeLists.txt"
           , "cpp/src/testbench.cpp"
           , "cpp/src/mlx90640_model.cpp"
           ]

      putNormal "Building C++ testbench..."
      -- Note the space after "-B" and "--build" to avoid "cmake -Bcpp/build"
      cmd_ $ "cmake -B " ++ buildDir ++ " -S cpp -DCMAKE_BUILD_TYPE=Release"
      cmd_ $ "cmake --build " ++ buildDir ++ " --target testbench -j4"
      copyFile' (buildDir </> "testbench") out

    -- Run tests
    phony "test" $ do
      need ["build/testbench"]
      putNormal "Running tests..."
      cmd_ "build/testbench --run-tests"

    -- Run simulation
    phony "sim" $ do
      need [ "verilog/generated/I2CMaster.v"
           , "verilog/generated/ThermalNormalizer.v"
           , "build/testbench"
           ]
      putNormal "Running simulation..."
      cmd_ "build/testbench --verilog verilog/generated/"

    -- Clean build artifacts
    phony "clean" $ do
      putNormal "Cleaning build artifacts..."
      liftIO $ callCommand "rm -rf build/ verilog/generated/ cpp/build/ chisel/generated/"
      removeFilesAfter "_shake" ["*"]

    -- CI target
    phony "ci" $ do
      need ["init", "test"]
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
             ]
  forM_ dirs $ \dir -> do
    putStrLn $ "  Creating: " ++ dir
    createDirectoryIfMissing True dir

generateTemplateFiles :: IO ()
generateTemplateFiles = do
  putStrLn "Generating template files..."

  -- build.sbt
  writeFile "chisel/build.sbt" $ unlines
    [ "scalaVersion := \"2.13.12\""
    , "libraryDependencies += \"edu.berkeley.cs\" %% \"chisel3\" % \"3.6.0\""
    , "libraryDependencies += \"edu.berkeley.cs\" %% \"chiseltest\" % \"0.6.0\" % \"test\""
    , "scalacOptions ++= Seq(\"-Xsource:2.13\", \"-deprecation\", \"-feature\")"
    ]

  -- CMakeLists.txt
  writeFile "cpp/CMakeLists.txt" $ unlines
    [ "cmake_minimum_required(VERSION 3.10)"
    , "project(ThermalCameraTest)"
    , "set(CMAKE_CXX_STANDARD 17)"
    , "include_directories(include)"
    , "add_executable(testbench"
    , "    src/testbench.cpp"
    , "    src/mlx90640_model.cpp"
    , ")"
    , "target_link_libraries(testbench pthread)"
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