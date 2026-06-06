{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ThermalSMT where

import Language.Hasmtlib
import Language.Hasmtlib.Solver.Yices
import Data.Vector (Vector, (!))
import qualified Data.Vector as V
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map

-- 温度データ型（固定小数点：10倍して整数に）
type TempCelsius = Double
type TempScaled = Int  -- 実際は℃ * 10（例：36.5℃ → 365）

-- 画像サイズ
width, height :: Int
width = 32
height = 24
totalPixels = width * height

-- SMT変数の型
data ThermalConstraints = ThermalConstraints
    { animalMask :: [SMTVar Bool]        -- 各ピクセルが動物かどうか
    , animalTemp :: SMTVar Int           -- 動物の体温（℃×10）
    , groundTemp :: SMTVar Int           -- 地面/背景の温度
    , maxSolarTemp :: SMTVar Int         -- 太陽光反射の最大温度
    , smoothnessPenalty :: [SMTVar Int]  -- 空間的平滑化の変数
    }

-- 物理的制約（知識ベース）
physicalConstraints :: 
    SMTVar Int ->      -- 動物体温
    SMTVar Int ->      -- 地面温度
    SMTVar Int ->      -- 太陽光反射最大温度
    SMTCtx () ->       -- 実際の測定値から計算される制約
    SBool
physicalConstraints tAnimal tGround tSolar = do
    -- 1. 動物体温の生理的範囲（哺乳類/鳥類）
    let minMammalTemp = 350  -- 35.0℃
        maxMammalTemp = 420  -- 42.0℃
        minBirdTemp = 380    -- 38.0℃
        maxBirdTemp = 440    -- 44.0℃
    
    -- 2. 地面温度の範囲（日陰/日向）
    let minGroundTemp = 150  -- 15.0℃
        maxGroundTemp = 500  -- 50.0℃（直射日光下）
    
    -- 3. 太陽光反射の特徴（急峻なピーク）
    let solarReflectMin = 450  -- 45.0℃以上（金属/ガラス反射）
        solarReflectMax = 800  -- 80.0℃（理論上限）
    
    -- 4. 動物体温は地面より高い（活動中）
    let higherThanGround = tAnimal .> (tGround + 50)  -- 最低5℃高い
    
    -- 5. 太陽反射は動物より著しく高い
    let solarVsAnimal = tSolar .> (tAnimal + 100)  -- 10℃以上高い
    
    -- 6. 太陽反射の温度勾配制約（隣接ピクセルとの差）
    --   （実際のループで実装）
    
    return $ higherThanGround .&& solarVsAnimal

-- メインのSMT推論エンジン
inferAnimalRegion :: 
    Vector TempScaled ->  -- 生の温度データ（センサー値×10）
    IO (Maybe [Bool])     -- 動物領域マスク
inferAnimalRegion thermalData = do
    -- Yicesソルバーの初期化
    result <- runSolver @Yices $ do
        
        -- === 変数宣言 ===
        -- 各ピクセルが動物かどうか
        animal <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool
        -- 体温の連続値
        tAnimal <- var $ sort @Int
        tGround <- var $ sort @Int
        tSolar <- var $ sort @Int
        
        -- === 測定値に基づく制約 ===
        -- 各ピクセルの実際の温度と変数の関係
        forM_ [0..totalPixels-1] $ \idx -> do
            let measuredTemp = thermalData ! idx
            
            -- もし動物なら、温度は動物体温範囲内
            let ifAnimal = var2Bool (animal !! idx)
            let animalTempConstraint = 
                    ifAnimal ==> (measuredTemp .== tAnimal)
            
            -- もし非動物（背景）なら、地面温度範囲または太陽反射
            let notAnimal = bnot ifAnimal
            let backgroundConstraint = 
                    notAnimal ==> (measuredTemp .<= tSolar)
            
            assert $ animalTempConstraint .&& backgroundConstraint
        
        -- === 物理的制約 ===
        let physConstraints = do
            -- 体温範囲
            assert $ tAnimal .>= 350 .&& tAnimal .<= 440
            -- 地面温度範囲
            assert $ tGround .>= 150 .&& tGround .<= 500
            -- 太陽反射範囲
            assert $ tSolar .>= 450 .&& tSolar .<= 800
            
            -- 動物体温は地面より高い
            assert $ tAnimal .> (tGround + 30)
            -- 太陽反射は動物より高い
            assert $ tSolar .> (tAnimal + 80)
        
        physConstraints
        
        -- === 空間的平滑化制約 ===
        -- 動物領域は連結で、ノイズを含まない
        forM_ [0..height-1] $ \y ->
            forM_ [0..width-1] $ \x -> do
                let idx = y * width + x
                -- 右隣との平滑化
                when (x < width-1) $ do
                    let rightIdx = y * width + (x+1)
                    let sameAnimal = 
                            (var2Bool $ animal !! idx) .== 
                            (var2Bool $ animal !! rightIdx)
                    -- 同じ動物領域なら5℃以内、異なるなら制限なし
                    let tempDiff = abs (thermalData ! idx - thermalData ! rightIdx)
                    when (tempDiff <= 50) $  -- 5℃以内なら隣接可能性が高い
                        assert $ sameAnimal .|| (tempDiff .> 50)
        
        -- === 最小領域サイズ制約 ===
        -- 動物は最低4ピクセル以上（小さすぎるノイズを除去）
        let animalCount = sum [ite (var2Bool $ animal !! i) 1 0 | i <- [0..totalPixels-1]]
        assert $ animalCount .>= 4
        
        -- === 解探索 ===
        -- 最大化：動物らしい領域の温度まとまり
        setOption $ OptSoftTimeout (MicroSeconds 1000000)  -- 1秒タイムアウト
        setOption $ OptVerbosity 1
        
        -- 目的関数：体温のまとまりを最大化
        let variancePenalty = sum [ite (var2Bool $ animal !! i) 
                                        (abs (thermalData ! i - tAnimal)) 
                                        0 
                                  | i <- [0..totalPixels-1]]
        
        -- 最小化：温度分散を最小にする解を選ぶ
        check $ Minimize $ MkPriorityLevel (mkSym "var") variancePenalty
        
        -- === モデル抽出 ===
        checkSat >>= \case
            Sat -> do
                -- 各変数の値を取得
                animalVals <- forM [0..totalPixels-1] $ \i -> 
                    getValue (animal !! i)
                return $ Just animalVals
            Unsat -> return Nothing
            Unknown -> return Nothing
    
    return result

-- 太陽光反射のスペクトル特徴を検出
detectSolarReflection :: 
    Vector TempScaled ->
    IO [Int]  -- 疑わしい太陽反射ピクセル
detectSolarReflection thermalData = runSolver @Yices $ do
    -- 高温ピクセル用のブール変数
    isSolar <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool
    
    forM_ [0..totalPixels-1] $ \idx -> do
        let temp = thermalData ! idx
        
        -- 太陽反射の特徴：
        -- 1. 非常に高温（>50℃）
        -- 2. 急峻な温度勾配（隣接より15℃以上高い）
        -- 3. 孤立点（周囲は低温）
        
        let isHot = temp .>= 500  -- 50℃以上
        let isIsolated = 
                -- 周囲8ピクセルの平均より20℃以上高い
                let neighbors = [idx - width - 1, idx - width, idx - width + 1,
                                 idx - 1,                 idx + 1,
                                 idx + width - 1, idx + width, idx + width + 1]
                    validNeighbors = filter (\n -> n >=0 && n < totalPixels) neighbors
                    avgNeighbor = sum [thermalData ! n | n <- validNeighbors] `div` 
                                 (length validNeighbors)
                in (temp - avgNeighbor) .>= 200  -- 20℃以上
        
        assert $ var2Bool (isSolar !! idx) .== (isHot .&& isIsolated)
    
    checkSat >>= \case
        Sat -> do
            solarVals <- forM [0..totalPixels-1] $ \i -> getValue (isSolar !! i)
            return $ [i | (i, True) <- zip [0..] solarVals]
        _ -> return []

-- 時系列データを使用したフィルタリング（動物体温は時間的に安定）
temporalFilter :: 
    [Vector TempScaled] ->  -- 過去フレーム（最新が最後）
    IO [Bool]               -- 最新フレームの動物領域
temporalFilter frames = runSolver @Yices $ do
    let currentFrame = last frames
    let prevFrame = if length frames >= 2 then frames !! (length frames - 2) else currentFrame
    
    isAnimal <- forM [0..totalPixels-1] $ \_ -> var $ sort @Bool
    
    forM_ [0..totalPixels-1] $ \idx -> do
        let currentTemp = currentFrame ! idx
        let prevTemp = prevFrame ! idx
        let tempDiff = abs (currentTemp - prevTemp)
        
        -- 動物体温はゆっくり変化（<0.5℃/フレーム @8Hz → <0.0625℃/秒）
        let stableTemp = tempDiff .<= 5  -- 0.5℃以内
        
        -- 太陽反射は急激に変化（雲の動き、角度変化）
        let rapidChange = tempDiff .>= 30  -- 3℃以上の変化
        
        assert $ var2Bool (isAnimal !! idx) .== (stableTemp .&& (bnot rapidChange))
    
    checkSat >>= \case
        Sat -> do
            animalVals <- forM [0..totalPixels-1] $ \i -> getValue (isAnimal !! i)
            return animalVals
        _ -> return $ replicate totalPixels False

-- === 統合推論パイプライン ===
analyzeThermalImage ::
    Vector TempScaled ->               -- 現在フレーム
    Maybe [Vector TempScaled] ->       -- 過去フレーム（時系列フィルタ用）
    IO (Maybe AnimalDetectionResult)   -- 検出結果
analyzeThermalImage currentFrame pastFrames = do
    -- ステップ1: 太陽反射の除外
    solarPixels <- detectSolarReflection currentFrame
    putStrLn $ "Detected solar reflections: " ++ show (length solarPixels) ++ " pixels"
    
    -- ステップ2: 一時的フィルタ（時系列データがある場合）
    temporalMask <- case pastFrames of
        Just frames -> temporalFilter (frames ++ [currentFrame])
        Nothing -> return $ replicate totalPixels True
    
    -- ステップ3: SMTによる動物領域推論
    -- 太陽反射ピクセルを事前にマスク
    let filteredData = V.imap (\idx temp -> 
                            if idx `elem` solarPixels 
                            then 0  -- 太陽反射は除外
                            else temp) currentFrame
    
    animalMask <- inferAnimalRegion filteredData
    
    -- ステップ4: 結果の統合
    case animalMask of
        Just mask -> do
            let finalMask = zipWith (&&) mask temporalMask
            let animalPixels = length $ filter id finalMask
            
            -- 体温統計を計算
            let animalTemps = [fromIntegral (currentFrame ! i) / 10.0 | 
                              (i, isAnimal) <- zip [0..] finalMask, isAnimal]
            
            return $ Just AnimalDetectionResult
                { resultMask = finalMask
                , animalTemperatureMean = if null animalTemps then 0 else sum animalTemps / fromIntegral (length animalTemps)
                , animalTemperatureMin = if null animalTemps then 0 else minimum animalTemps
                , animalTemperatureMax = if null animalTemps then 0 else maximum animalTemps
                , solarReflections = solarPixels
                }
        Nothing -> return Nothing

data AnimalDetectionResult = AnimalDetectionResult
    { resultMask :: [Bool]
    , animalTemperatureMean :: Double
    , animalTemperatureMin :: Double
    , animalTemperatureMax :: Double
    , solarReflections :: [Int]
    } deriving (Show)