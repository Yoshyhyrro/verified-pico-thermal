{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}

module ThermalSMT where

import Language.Hasmtlib hiding ((&&), (!))
import Language.Hasmtlib.Solver.Z3
import qualified Data.Vector as V
import Data.Vector (Vector)
import Control.Monad (forM, forM_, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map

-- Temperature data type (fixed-point: scaled by 10 to integer)
type TempCelsius = Double
type TempScaled  = Int

-- Image dimensions
width, height :: Int
width  = 32
height = 24

totalPixels :: Int
totalPixels = width * height

-- SMT variable types
data ThermalConstraints = ThermalConstraints
    { animalMask       :: [SMTVar Bool]
    , animalTemp       :: SMTVar Int
    , groundTemp       :: SMTVar Int
    , maxSolarTemp     :: SMTVar Int
    , smoothnessPenalty :: [SMTVar Int]
    }

-- Physical constraints (pure SMT expression)
physicalConstraints ::
    SMTVar Int ->
    SMTVar Int ->
    SMTVar Int ->
    SExpr
physicalConstraints tAnimal tGround tSolar =
    let higherThanGround = tAnimal .> (tGround + 50)
        solarVsAnimal    = tSolar  .> (tAnimal + 100)
    in higherThanGround .&& solarVsAnimal

-- Main SMT inference engine
inferAnimalRegion ::
    Vector TempScaled ->
    IO (Maybe [Bool])
inferAnimalRegion thermalData = do
    result <- runSolver @Z3 $ do

        -- === Variable Declaration ===
        animal  <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool
        tAnimal <- var $ sort @Int
        tGround <- var $ sort @Int
        tSolar  <- var $ sort @Int

        -- === Constraints Based on Measurements ===
        forM_ [0..totalPixels-1] $ \idx -> do
            let measuredTemp = thermalData V.! idx

            let ifAnimal = var2Bool (animal !! idx)
            let animalTempConstraint =
                    ifAnimal ==> (measuredTemp .== tAnimal)

            let notAnimal = bnot ifAnimal
            let backgroundConstraint =
                    notAnimal ==> (measuredTemp .<= tSolar)

            assert $ animalTempConstraint .&& backgroundConstraint

        -- === Physical Constraints ===
        assert $ tAnimal .>= 350 .&& tAnimal .<= 440
        assert $ tGround .>= 150 .&& tGround .<= 500
        assert $ tSolar  .>= 450 .&& tSolar  .<= 800
        assert $ tAnimal .> (tGround + 30)
        assert $ tSolar  .> (tAnimal + 80)

        -- === Spatial Smoothing Constraints ===
        forM_ [0..height-1] $ \y ->
            forM_ [0..width-1] $ \x -> do
                let idx = y * width + x
                when (x < width-1) $ do
                    let rightIdx = y * width + (x+1)
                    let sameAnimal =
                            (var2Bool $ animal !! idx) .==
                            (var2Bool $ animal !! rightIdx)

                    let tempDiff = abs (thermalData V.! idx - thermalData V.! rightIdx)

                    when (tempDiff <= 50) $
                        assert $ sameAnimal .|| (tempDiff .> 50)

        -- === Minimum Region Size Constraint ===
        let animalCount = sum [ ite (var2Bool $ animal !! i) 1 0
                              | i <- [0..totalPixels-1] ]
        assert $ animalCount .>= 4

        -- === Optimization Objective ===
        let variancePenalty =
                sum [ ite (var2Bool $ animal !! i)
                        (abs (thermalData V.! i - tAnimal))
                        0
                    | i <- [0..totalPixels-1] ]

        check $ Minimize $ MkPriorityLevel (mkSym "var") variancePenalty

        -- === Model Extraction ===
        checkSat >>= \case
            Sat -> do
                animalVals <- forM [0..totalPixels-1] $ \i ->
                    getValue (animal !! i)
                return $ Just animalVals
            _ -> return Nothing

    return result

-- Detect spectral characteristics of solar reflection
detectSolarReflection ::
    Vector TempScaled ->
    IO [Int]
detectSolarReflection thermalData = runSolver @Z3 $ do
    isSolar <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool

    forM_ [0..totalPixels-1] $ \idx -> do
        let temp = thermalData V.! idx

        let isHot = temp .>= 500

        let neighbors =
                [ idx - width - 1, idx - width, idx - width + 1
                , idx - 1,                     idx + 1
                , idx + width - 1, idx + width, idx + width + 1 ]

        let validNeighbors = filter (\n -> n >= 0 && n < totalPixels) neighbors
        let avgNeighbor =
                sum [thermalData V.! n | n <- validNeighbors]
                `div` length validNeighbors

        let isIsolated = (temp - avgNeighbor) .>= 200

        assert $ var2Bool (isSolar !! idx) .== (isHot .&& isIsolated)

    checkSat >>= \case
        Sat -> do
            solarVals <- forM [0..totalPixels-1] $ \i -> getValue (isSolar !! i)
            return [i | (i, True) <- zip [0..] solarVals]
        _ -> return []

-- Temporal filtering using time-series data
temporalFilter ::
    [Vector TempScaled] ->
    IO [Bool]
temporalFilter frames = runSolver @Z3 $ do
    let currentFrame = last frames
    let prevFrame    = if length frames >= 2
                       then frames !! (length frames - 2)
                       else currentFrame

    isAnimal <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool

    forM_ [0..totalPixels-1] $ \idx -> do
        let currentTemp = currentFrame V.! idx
        let prevTemp    = prevFrame    V.! idx
        let tempDiff    = abs (currentTemp - prevTemp)

        let stableTemp  = tempDiff .<= 5
        let rapidChange = tempDiff .>= 30

        assert $ var2Bool (isAnimal !! idx) .==
                (stableTemp .&& bnot rapidChange)

    checkSat >>= \case
        Sat -> do
            animalVals <- forM [0..totalPixels-1] $ \i -> getValue (isAnimal !! i)
            return animalVals
        _ -> return $ replicate totalPixels False

-- === Integrated Inference Pipeline ===
data AnimalDetectionResult = AnimalDetectionResult
    { resultMask            :: [Bool]
    , animalTemperatureMean :: Double
    , animalTemperatureMin  :: Double
    , animalTemperatureMax  :: Double
    , solarReflections      :: [Int]
    } deriving (Show)

analyzeThermalImage ::
    Vector TempScaled ->
    Maybe [Vector TempScaled] ->
    IO (Maybe AnimalDetectionResult)
analyzeThermalImage currentFrame pastFrames = do

    solarPixels <- detectSolarReflection currentFrame
    putStrLn $ "Detected solar reflections: " ++ show (length solarPixels) ++ " pixels"

    temporalMask <- case pastFrames of
        Just frames -> temporalFilter (frames ++ [currentFrame])
        Nothing     -> return $ replicate totalPixels True

    let filteredData = V.imap (\idx temp ->
                            if idx `elem` solarPixels
                            then 0
                            else temp) currentFrame

    animalMask <- inferAnimalRegion filteredData

    case animalMask of
        Just mask -> do
            let finalMask = zipWith (&&) mask temporalMask

            let animalTemps =
                    [ fromIntegral (currentFrame V.! i) / 10.0
                    | (i, True) <- zip [0..] finalMask ]

            return $ Just AnimalDetectionResult
                { resultMask            = finalMask
                , animalTemperatureMean = if null animalTemps then 0
                                          else sum animalTemps / fromIntegral (length animalTemps)
                , animalTemperatureMin  = if null animalTemps then 0 else minimum animalTemps
                , animalTemperatureMax  = if null animalTemps then 0 else maximum animalTemps
                , solarReflections      = solarPixels
                }
        Nothing -> return Nothing
