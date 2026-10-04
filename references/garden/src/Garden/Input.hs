-- | Pure device-to-command mapping, shared by the live host and checks.
module Garden.Input (keyCommand, screenCoord, buttonCommand) where

import Garden.Session
import Garden.View (boardX, boardY, cellSize)
import Garden.World

keyCommand :: Char -> Maybe Command
keyCommand k = case k of
  ' ' -> Just TogglePause
  'n' -> Just StepOnce
  'r' -> Just ResetSameSeed
  '1' -> Just (Select PourWater)
  '2' -> Just (Select PlaceStone)
  '3' -> Just (Select PourSand)
  '4' -> Just (Select SowSeed)
  '5' -> Just (Select PlaceLight)
  '6' -> Just (Select Erase)
  _ -> Nothing

-- | Reject pixels outside the board before subtracting the board origin.
-- This also avoids wrapped @Int@ arithmetic for extreme host coordinates.
screenCoord :: Int -> Int -> Maybe Coord
screenCoord x y
  | x < boardX || x >= boardX + width * cellSize = Nothing
  | y < boardY || y >= boardY + height * cellSize = Nothing
  | otherwise = coord ((x - boardX) `div` cellSize) ((y - boardY) `div` cellSize)

buttonCommand :: Int -> Int -> Maybe Command
buttonCommand x y
  | y >= 96 && y < 130 && x >= 28 && x < 160 = Just TogglePause
  | y >= 96 && y < 130 && x >= 174 && x < 310 = Just StepOnce
  | y >= 96 && y < 130 && x >= 324 && x < 480 = Just ResetSameSeed
  | y >= 612 && y < 658 = selectAt (zip [0 ..] materials)
  | otherwise = Nothing
  where
    selectAt [] = Nothing
    selectAt ((i, m) : rest)
      | x >= 28 + i * 134 && x < 28 + i * 134 + 124 = Just (Select m)
      | otherwise = selectAt rest
