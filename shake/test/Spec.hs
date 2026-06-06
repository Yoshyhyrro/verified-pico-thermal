{-# LANGUAGE OverloadedStrings #-}

import Test.Tasty
import Test.Tasty.HUnit
import ThermalSMT
import qualified Data.Vector as V
import Language.Hasmtlib

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Thermal SMT Tests"
    [ testCase "Animal body temperature range" $ do
        -- 37℃の動物がいる理想的なシーン
        let frame = V.fromList $ 
                replicate (32*24) 250 ++  -- 25℃背景
                [370, 371, 372, 373]      -- 37℃動物（4ピクセル）
        
        result <- inferAnimalRegion frame
        case result of
            Just mask -> 
                let animalCount = length $ filter id mask
                in assertBool "Should detect animal" (animalCount >= 4)
            Nothing -> assertFailure "SMT solver found no solution"
    
    , testCase "Exclude solar reflection" $ do
        -- 60℃の太陽反射があるシーン
        let frame = V.fromList $ 
                replicate 500 250 ++  -- 背景
                [600, 610, 590, 605]  -- 太陽反射
        solarPixels <- detectSolarReflection frame
        assertBool "Should detect solar" (length solarPixels >= 4)
    
    , testCase "Temporal consistency" $ do
        let frame1 = V.replicate (32*24) 250
        let frame2 = V.update frame1 (V.fromList [(370, 0), (371, 1)])
        let frames = [frame1, frame2]
        mask <- temporalFilter frames
        assertBool "Should be stable" (length (filter id mask) > 0)
    ]