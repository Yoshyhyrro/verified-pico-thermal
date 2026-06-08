{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE DataKinds           #-}   -- required for @BoolSort / @IntSort

module ThermalSMT where

-- Disambiguate Language.Hasmtlib.Boolean.(&&) and .not from Prelude;
-- hasmtlib's Boolean class has Bool instances so behaviour is identical.
import Prelude hiding (not, (&&))
import Language.Hasmtlib                  -- exports Boolean, Orderable, Equatable, ite …
import Data.Vector (Vector)               -- NOT (!): that would clash with Relation.!
import qualified Data.Vector as V         -- use V.! throughout
import Control.Monad (forM, forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe, join)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- Temperature data type (fixed-point: scaled by 10 to integer)
type TempCelsius = Double
type TempScaled  = Int   -- °C × 10  (e.g. 36.5 °C → 365)

-- Image dimensions
width, height :: Int
width  = 32
height = 24

totalPixels :: Int
totalPixels = width * height

-- Container for the SMT variables of one problem instance.
-- Uses Expr rather than SMTVar because Language.Hasmtlib.var returns Expr t.
data ThermalConstraints = ThermalConstraints
    { animalMask        :: [Expr BoolSort]   -- whether each pixel contains an animal
    , animalTemp        :: Expr IntSort      -- animal body temperature (°C × 10)
    , groundTemp        :: Expr IntSort      -- ground / background temperature
    , maxSolarTemp      :: Expr IntSort      -- maximum solar-reflection temperature
    , smoothnessPenalty :: [Expr IntSort]    -- auxiliary variables for spatial smoothing
    }

-- ---------------------------------------------------------------------------
-- Physical constraints helper (currently unused; kept as reference)
-- ---------------------------------------------------------------------------

-- | Pure conjunction of the physical domain constraints.
--   Does NOT require any monadic context – just builds an Expr BoolSort.
physicalConstraints
    :: Expr IntSort   -- ^ animal body temperature
    -> Expr IntSort   -- ^ ground temperature
    -> Expr IntSort   -- ^ max solar-reflection temperature
    -> Expr BoolSort
physicalConstraints tAnimal tGround tSolar =
    -- 1–3. Physiological / environment ranges
    (tAnimal >=? 350 && tAnimal <=? 440)  -- 35–44 °C
 && (tGround >=? 150 && tGround <=? 500)  -- 15–50 °C
 && (tSolar  >=? 450 && tSolar  <=? 800)  -- 45–80 °C
    -- 4. Animal is warmer than ground (active)
 && tAnimal >? (tGround + 50)             -- ≥ 5 °C above ground
    -- 5. Solar spike is much hotter than animal
 && tSolar  >? (tAnimal + 100)            -- ≥ 10 °C above animal

-- ---------------------------------------------------------------------------
-- Main SMT inference engine
-- ---------------------------------------------------------------------------

-- | Given a raw thermal frame, infer which pixels belong to an animal.
--
-- Uses hasmtlib's 'interactiveWith' (incremental, Pipe-based) so that we can
-- call 'checkSat' and 'getValue' inside the solver context.
-- 'interactiveWith' returns @m (Maybe a)@; we 'join' the outer layer away.
inferAnimalRegion
    :: Vector TempScaled    -- ^ raw thermal frame (sensor value × 10)
    -> IO (Maybe [Bool])    -- ^ animal-region mask, or Nothing if UNSAT
inferAnimalRegion thermalData = do
    let n = V.length thermalData   -- actual frame size (may differ from totalPixels)
    mResult <- interactiveWith yices $ do
        setOption $ ProduceModels True
        -- NOTE: do NOT send (set-option :incremental …) to Yices2.
        -- Yices2 replies with the plain word "unsupported" instead of the
        -- S-expression (error "…") form that hasmtlib's parser expects; the
        -- parser falls to its catch-all branch which calls error "string".
        -- interactiveWith already manages the incremental session internally.
        setLogic "QF_LIA"          -- quantifier-free linear integer arithmetic

        -- === Variable Declaration ===
        -- One Bool variable per pixel (is it an animal pixel?)
        animal  <- forM [0..n-1] $ \_ -> var @BoolSort
        -- Shared continuous temperatures
        tAnimal <- var @IntSort
        tGround <- var @IntSort
        tSolar  <- var @IntSort

        -- === Measurement-Based Constraints ===
        -- Relate each pixel's measured temperature to the class variables.
        forM_ [0..n-1] $ \idx -> do
            let measuredTemp = fromIntegral (thermalData V.! idx) :: Expr IntSort

            -- Animal pixel  → temperature must equal the animal-body value
            let isAnimal = animal !! idx
            assert $ isAnimal ==> (measuredTemp === tAnimal)

            -- Background pixel → temperature must be at most the solar spike
            assert $ not isAnimal ==> (measuredTemp <=? tSolar)

        -- === Physical Constraints ===
        -- Body temperature range (35–44 °C)
        assert $ tAnimal >=? 350 && tAnimal <=? 440
        -- Ground temperature range (15–50 °C)
        assert $ tGround >=? 150 && tGround <=? 500
        -- Solar-reflection range (45–80 °C)
        assert $ tSolar  >=? 450 && tSolar  <=? 800
        -- Animal is warmer than ground
        assert $ tAnimal >? (tGround + 30)
        -- Solar spike is much hotter than animal
        assert $ tSolar  >? (tAnimal + 80)

        -- === Spatial Smoothing Constraints ===
        -- Adjacent pixels with similar measured temperature → same class.
        forM_ [0..height-1] $ \row ->
            forM_ [0..width-1] $ \col -> do
                let idx = row * width + col
                when (col < width - 1) $ do
                    let rightIdx = row * width + (col + 1)
                    let tempDiff = abs (thermalData V.! idx - thermalData V.! rightIdx)
                    when (tempDiff <= 50) $   -- within 5 °C → same region
                        assert $ (animal !! idx) === (animal !! rightIdx)

        -- === Minimum Region-Size Constraint ===
        -- Require at least 4 animal pixels (filters single-pixel noise).
        let animalCount =
                sum [ ite (animal !! i) (1 :: Expr IntSort) 0
                    | i <- [0..n-1] ]
        assert $ animalCount >=? 4

        -- === Solve & Extract ===
        checkSat >>= \case
            Sat -> do
                -- getValue returns Maybe (HaskellType t):
                --   Expr BoolSort  →  Maybe Bool
                animalVals <- forM [0..n-1] $ \i ->
                    getValue (animal !! i)
                return $ Just (map (fromMaybe False) animalVals)
            _   -> return Nothing

    -- interactiveWith returns IO (Maybe a); join collapses Maybe (Maybe [Bool])
    return $ join mResult

-- ---------------------------------------------------------------------------
-- Detect solar-reflection pixels (pure Haskell – no SMT needed)
-- ---------------------------------------------------------------------------

-- | Return indices of pixels that look like solar reflections:
--   very hot AND significantly hotter than their neighbourhood.
detectSolarReflection
    :: Vector TempScaled
    -> IO [Int]          -- suspected solar-reflection pixel indices
detectSolarReflection thermalData = return
    [ idx
    | idx <- [0..n-1]      -- n = actual frame size, NOT the global totalPixels
    , let temp = thermalData V.! idx
    -- 1. Very high temperature (≥ 50 °C)
    , temp >= 500
    , let neighbors =
            filter (\k -> k >= 0 && k < n)   -- bound by actual length
                [ idx - width - 1, idx - width, idx - width + 1
                , idx - 1,                       idx + 1
                , idx + width - 1, idx + width,  idx + width + 1 ]
    , not (null neighbors)
    -- 2. At least 20 °C hotter than the average of surrounding pixels
    , let avgNeighbor =
            sum [ thermalData V.! k | k <- neighbors ]
            `div` length neighbors
    , (temp - avgNeighbor) >= 200
    ]
  where n = V.length thermalData

-- ---------------------------------------------------------------------------
-- Temporal filter (pure Haskell)
-- ---------------------------------------------------------------------------

-- | Classify pixels by temporal stability:
--   stable temperature ≈ animal, rapidly-changing ≈ solar reflection.
temporalFilter
    :: [Vector TempScaled]  -- past frames, most recent last
    -> IO [Bool]            -- animal-region mask for the latest frame
temporalFilter frames = return
    [ let ct = currentFrame V.! idx
          pt = prevFrame    V.! idx
          d  = abs (ct - pt)
      in  d <= 5 && not (d >= 30)   -- stable AND not rapidly-changing
    | idx <- [0..V.length currentFrame - 1]   -- use actual frame size
    ]
  where
    currentFrame = last frames
    prevFrame    = if length frames >= 2
                   then frames !! (length frames - 2)
                   else currentFrame

-- ---------------------------------------------------------------------------
-- Integrated inference pipeline
-- ---------------------------------------------------------------------------

-- | Full analysis pipeline: exclude solar artefacts, apply temporal filter,
--   then run SMT-based region inference.
analyzeThermalImage
    :: Vector TempScaled              -- current frame
    -> Maybe [Vector TempScaled]      -- past frames (for temporal filter)
    -> IO (Maybe AnimalDetectionResult)
analyzeThermalImage currentFrame pastFrames = do
    -- Step 1: exclude solar-reflection pixels
    solarPixels <- detectSolarReflection currentFrame
    putStrLn $ "Detected solar reflections: "
             ++ show (length solarPixels) ++ " pixels"

    -- Step 2: temporal filter (when history is available)
    temporalMask <- case pastFrames of
        Just frames -> temporalFilter (frames ++ [currentFrame])
        Nothing     -> return $ replicate (V.length currentFrame) True

    -- Step 3: SMT-based animal-region inference on the masked frame
    let filteredData = V.imap
            (\idx temp ->
                if idx `elem` solarPixels
                then 0      -- zero-out solar reflections
                else temp)
            currentFrame

    animalMask <- inferAnimalRegion filteredData

    -- Step 4: combine results
    case animalMask of
        Nothing   -> return Nothing
        Just mask -> do
            let finalMask   = zipWith (&&) mask temporalMask
                animalTemps =
                    [ fromIntegral (currentFrame V.! i) / 10.0
                    | (i, isAnimal) <- zip [0..] finalMask
                    , isAnimal ]
                mean  = if null animalTemps then 0
                        else sum animalTemps / fromIntegral (length animalTemps)
            return $ Just AnimalDetectionResult
                { resultMask            = finalMask
                , animalTemperatureMean = mean
                , animalTemperatureMin  = if null animalTemps then 0 else minimum animalTemps
                , animalTemperatureMax  = if null animalTemps then 0 else maximum animalTemps
                , solarReflections      = solarPixels
                }

-- ---------------------------------------------------------------------------
-- Result type
-- ---------------------------------------------------------------------------

data AnimalDetectionResult = AnimalDetectionResult
    { resultMask            :: [Bool]
    , animalTemperatureMean :: Double
    , animalTemperatureMin  :: Double
    , animalTemperatureMax  :: Double
    , solarReflections      :: [Int]
    } deriving (Show)