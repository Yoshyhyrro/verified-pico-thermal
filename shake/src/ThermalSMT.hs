{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}          -- required for \case syntax

module ThermalSMT where

import Language.Hasmtlib
import Language.Hasmtlib.Solver.Yices
import Data.Vector (Vector, (!))
import qualified Data.Vector as V
import Control.Monad (forM, forM_, when)   -- added forM (was missing)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map

-- Temperature data type (fixed-point: scaled by 10 to integer)
type TempCelsius = Double
type TempScaled  = Int  -- Actual value is °C * 10 (e.g., 36.5°C → 365)

-- Image dimensions
width, height :: Int
width  = 32
height = 24

totalPixels :: Int  -- explicit type annotation added
totalPixels = width * height

-- SMT variable types
data ThermalConstraints = ThermalConstraints
    { animalMask       :: [SMTVar Bool]       -- Whether each pixel contains an animal
    , animalTemp       :: SMTVar Int          -- Animal body temperature (°C × 10)
    , groundTemp       :: SMTVar Int          -- Ground/background temperature
    , maxSolarTemp     :: SMTVar Int          -- Maximum temperature from solar reflection
    , smoothnessPenalty :: [SMTVar Int]       -- Variables for spatial smoothing
    }

-- Physical constraints (knowledge base)
-- NOTE: this helper is currently unused; kept for reference.
-- Removed erroneous 4th parameter (SMTCtx () ->) and monadic do-notation
-- so the type correctly matches a pure SBool expression.
physicalConstraints ::
    SMTVar Int ->  -- Animal body temperature
    SMTVar Int ->  -- Ground temperature
    SMTVar Int ->  -- Max solar reflection temperature
    SBool
physicalConstraints tAnimal tGround tSolar =
    let -- 1. Physiological range for animal body temperature (mammals/birds)
        --    minMammalTemp = 350  -- 35.0°C
        --    maxMammalTemp = 420  -- 42.0°C
        --    minBirdTemp   = 380  -- 38.0°C
        --    maxBirdTemp   = 440  -- 44.0°C
        --
        -- 2. Ground temperature range (shade/sunlight)
        --    minGroundTemp = 150  -- 15.0°C
        --    maxGroundTemp = 500  -- 50.0°C (under direct sunlight)
        --
        -- 3. Solar reflection characteristics (sharp peak)
        --    solarReflectMin = 450  -- 45.0°C or above (metal/glass reflection)
        --    solarReflectMax = 800  -- 80.0°C (theoretical upper limit)

        -- 4. Animal body temperature is higher than ground (while active)
        higherThanGround = tAnimal .> (tGround + 50)  -- at least 5°C higher

        -- 5. Solar reflection is significantly higher than animal temperature
        solarVsAnimal    = tSolar .> (tAnimal + 100)  -- at least 10°C higher

        -- 6. Temperature gradient constraint for solar reflection
        --    (difference with adjacent pixels — implemented in the main loop)

    in higherThanGround .&& solarVsAnimal

-- Main SMT inference engine
inferAnimalRegion ::
    Vector TempScaled ->  -- Raw thermal data (sensor value × 10)
    IO (Maybe [Bool])     -- Animal region mask
inferAnimalRegion thermalData = do
    -- Initialize the Yices solver
    result <- runSolver @Yices $ do

        -- === Variable Declaration ===
        -- Whether each pixel belongs to an animal
        animal  <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool
        -- Continuous temperature values
        tAnimal <- var $ sort @Int
        tGround <- var $ sort @Int
        tSolar  <- var $ sort @Int

        -- === Constraints Based on Measurements ===
        -- Relationship between each pixel's actual temperature and variables
        forM_ [0..totalPixels-1] $ \idx -> do
            let measuredTemp = thermalData ! idx

            -- If animal pixel: temperature must be within animal body temp range
            let ifAnimal = var2Bool (animal !! idx)
            let animalTempConstraint =
                    ifAnimal ==> (measuredTemp .== tAnimal)

            -- If non-animal (background): temperature within ground range or solar reflection
            let notAnimal = bnot ifAnimal
            let backgroundConstraint =
                    notAnimal ==> (measuredTemp .<= tSolar)

            assert $ animalTempConstraint .&& backgroundConstraint

        -- === Physical Constraints ===
        -- FIX: inlined from "let physConstraints = do" to avoid the layout-rule
        -- ambiguity where the inner do-block opened at the same column (13) as
        -- the let-binding itself, causing GHC parse error [GHC-58481] at line 105.
        --
        -- Body temperature range
        assert $ tAnimal .>= 350 .&& tAnimal .<= 440
        -- Ground temperature range
        assert $ tGround .>= 150 .&& tGround .<= 500
        -- Solar reflection range
        assert $ tSolar  .>= 450 .&& tSolar  .<= 800
        -- Animal body temp is higher than ground
        assert $ tAnimal .> (tGround + 30)
        -- Solar reflection is higher than animal temp
        assert $ tSolar  .> (tAnimal + 80)

        -- === Spatial Smoothing Constraints ===
        -- Animal region is connected and noise-free
        forM_ [0..height-1] $ \y ->
            forM_ [0..width-1] $ \x -> do
                let idx = y * width + x
                -- Smoothing with right neighbor
                when (x < width-1) $ do
                    let rightIdx   = y * width + (x+1)
                    let sameAnimal =
                            (var2Bool $ animal !! idx) .==
                            (var2Bool $ animal !! rightIdx)
                    -- If same animal region: within 5°C; otherwise no limit
                    let tempDiff = abs (thermalData ! idx - thermalData ! rightIdx)
                    when (tempDiff <= 50) $  -- high adjacency likelihood if within 5°C
                        assert $ sameAnimal .|| (tempDiff .> 50)

        -- === Minimum Region Size Constraint ===
        -- Animal region must have at least 4 pixels (to filter out small noise)
        let animalCount = sum [ite (var2Bool $ animal !! i) 1 0 | i <- [0..totalPixels-1]]
        assert $ animalCount .>= 4

        -- === Solution Search ===
        setOption $ OptSoftTimeout (MicroSeconds 1000000)  -- 1-second timeout
        setOption $ OptVerbosity 1

        -- Objective: minimize temperature variance inside the animal region
        let variancePenalty = sum [ ite (var2Bool $ animal !! i)
                                        (abs (thermalData ! i - tAnimal))
                                        0
                                  | i <- [0..totalPixels-1] ]

        -- Minimize: choose solution with minimum temperature variance
        check $ Minimize $ MkPriorityLevel (mkSym "var") variancePenalty

        -- === Model Extraction ===
        checkSat >>= \case
            Sat -> do
                -- Retrieve value of each variable
                animalVals <- forM [0..totalPixels-1] $ \i ->
                    getValue (animal !! i)
                return $ Just animalVals
            Unsat   -> return Nothing
            Unknown -> return Nothing

    return result

-- Detect spectral characteristics of solar reflection
detectSolarReflection ::
    Vector TempScaled ->
    IO [Int]  -- Suspected solar reflection pixels
detectSolarReflection thermalData = runSolver @Yices $ do
    -- Boolean variables for high-temperature pixels
    isSolar <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool

    forM_ [0..totalPixels-1] $ \idx -> do
        let temp = thermalData ! idx

        -- Solar reflection characteristics:
        -- 1. Very high temperature (>50°C)
        -- 2. Steep temperature gradient (15°C or more above adjacent pixels)
        -- 3. Isolated point (surroundings are low temperature)

        let isHot      = temp .>= 500  -- 50°C or above
        let isIsolated =
                -- At least 20°C higher than the average of surrounding 8 pixels
                let neighbors      = [ idx - width - 1, idx - width, idx - width + 1
                                     , idx - 1,                      idx + 1
                                     , idx + width - 1, idx + width, idx + width + 1 ]
                    validNeighbors = filter (\n -> n >= 0 && n < totalPixels) neighbors
                    avgNeighbor    = sum [thermalData ! n | n <- validNeighbors]
                                     `div` length validNeighbors
                in (temp - avgNeighbor) .>= 200  -- 20°C or more

        assert $ var2Bool (isSolar !! idx) .== (isHot .&& isIsolated)

    checkSat >>= \case
        Sat -> do
            solarVals <- forM [0..totalPixels-1] $ \i -> getValue (isSolar !! i)
            return [i | (i, True) <- zip [0..] solarVals]
        _ -> return []

-- Temporal filtering using time-series data (animal body temp is temporally stable)
temporalFilter ::
    [Vector TempScaled] ->  -- Past frames (most recent is last)
    IO [Bool]               -- Animal region in the latest frame
temporalFilter frames = runSolver @Yices $ do
    let currentFrame = last frames
    let prevFrame    = if length frames >= 2
                       then frames !! (length frames - 2)
                       else currentFrame

    isAnimal <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool

    forM_ [0..totalPixels-1] $ \idx -> do
        let currentTemp = currentFrame ! idx
        let prevTemp    = prevFrame    ! idx
        let tempDiff    = abs (currentTemp - prevTemp)

        -- Animal body temp changes slowly (<0.5°C/frame @8Hz → <0.0625°C/s)
        let stableTemp  = tempDiff .<= 5   -- within 0.5°C

        -- Solar reflection changes rapidly (cloud movement, angle change)
        let rapidChange = tempDiff .>= 30  -- 3°C or more change

        assert $ var2Bool (isAnimal !! idx) .== (stableTemp .&& bnot rapidChange)

    checkSat >>= \case
        Sat -> do
            animalVals <- forM [0..totalPixels-1] $ \i -> getValue (isAnimal !! i)
            return animalVals
        _ -> return $ replicate totalPixels False

-- === Integrated Inference Pipeline ===
analyzeThermalImage ::
    Vector TempScaled ->              -- Current frame
    Maybe [Vector TempScaled] ->      -- Past frames (for temporal filtering)
    IO (Maybe AnimalDetectionResult)  -- Detection result
analyzeThermalImage currentFrame pastFrames = do
    -- Step 1: Exclude solar reflections
    solarPixels <- detectSolarReflection currentFrame
    putStrLn $ "Detected solar reflections: " ++ show (length solarPixels) ++ " pixels"

    -- Step 2: Temporal filter (when time-series data is available)
    temporalMask <- case pastFrames of
        Just frames -> temporalFilter (frames ++ [currentFrame])
        Nothing     -> return $ replicate totalPixels True

    -- Step 3: SMT-based animal region inference
    -- Pre-mask solar reflection pixels
    let filteredData = V.imap (\idx temp ->
                            if idx `elem` solarPixels
                            then 0     -- exclude solar reflections
                            else temp) currentFrame

    animalMask <- inferAnimalRegion filteredData

    -- Step 4: Integrate results
    case animalMask of
        Just mask -> do
            let finalMask      = zipWith (&&) mask temporalMask
            let _animalPixels  = length $ filter id finalMask  -- reserved for future use

            -- Compute body temperature statistics
            let animalTemps = [ fromIntegral (currentFrame ! i) / 10.0
                              | (i, isAnimal) <- zip [0..] finalMask
                              , isAnimal ]

            return $ Just AnimalDetectionResult
                { resultMask            = finalMask
                , animalTemperatureMean = if null animalTemps then 0
                                         else sum animalTemps / fromIntegral (length animalTemps)
                , animalTemperatureMin  = if null animalTemps then 0 else minimum animalTemps
                , animalTemperatureMax  = if null animalTemps then 0 else maximum animalTemps
                , solarReflections      = solarPixels
                }
        Nothing -> return Nothing

data AnimalDetectionResult = AnimalDetectionResult
    { resultMask            :: [Bool]
    , animalTemperatureMean :: Double
    , animalTemperatureMin  :: Double
    , animalTemperatureMax  :: Double
    , solarReflections      :: [Int]
    } deriving (Show)