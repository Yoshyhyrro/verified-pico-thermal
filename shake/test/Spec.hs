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
        -- Ideal scene: one animal at 37 °C against a cool background
        let frame = V.fromList $ 
                replicate (32*24) 250 ++  -- 25 °C background
                [370, 371, 372, 373]      -- 37 °C animal body (4 pixels with slight variation)
        
        result <- inferAnimalRegion frame
        case result of
            Just mask -> 
                let animalCount = length $ filter id mask
                in assertBool "Should detect animal" (animalCount >= 4)
            Nothing -> assertFailure "SMT solver found no solution"
    
    , testCase "Exclude solar reflection" $ do
        -- Scene with 60 °C solar reflections in an otherwise cool field
        let frame = V.fromList $ 
                replicate 500 250 ++  -- background (25 °C)
                [600, 610, 590, 605]  -- solar-reflection hot-spots
        solarPixels <- detectSolarReflection frame
        assertBool "Should detect solar" (length solarPixels >= 4)
    
    , testCase "Temporal consistency" $ do
        let frame1 = V.replicate (32*24) 250
        let frame2 = V.update frame1 (V.fromList [(370, 0), (371, 1)])
        let frames = [frame1, frame2]
        mask <- temporalFilter frames
        assertBool "Should be stable" (length (filter id mask) > 0)
    ]