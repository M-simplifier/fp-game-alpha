-- | Disposable render data. It contains no IO handles and never feeds rules.
module Garden.View
  ( RenderModel (..), Tile (..), project, materialName, materialHint
  , effectSummary, boardX, boardY, cellSize, windowWidth, windowHeight
  ) where

import Data.List (find)
import Garden.Session
import Garden.Simulation
import Garden.World

data Tile = Tile { tileX :: !Int, tileY :: !Int, tileCell :: !Cell
                 , tileTop :: !Bool, tileSpeckle :: !Bool } deriving (Eq, Show)

data RenderModel = RenderModel
  { tiles :: ![Tile], lightPositions :: ![(Int,Int)]
  , shownTick :: !Integer, shownSeed :: !String, shownFingerprint :: !String
  , waterCount :: !Int, plantCount :: !Int, shownPaused :: !Bool
  , shownMaterial :: !Material
  } deriving (Eq, Show)

boardX, boardY, cellSize, windowWidth, windowHeight :: Int
boardX = 28
boardY = 146
cellSize = 10
windowWidth = 1120
windowHeight = 750

project :: Session -> RenderModel
project s = RenderModel
  { tiles = map tile cells
  , lightPositions = [xy p | (p,Light) <- cells]
  , shownTick = worldTick w, shownSeed = seedCode (worldSeed w)
  , shownFingerprint = fingerprint w
  , waterCount = length [() | (_,Water) <- cells]
  , plantCount = length [() | (_,c) <- cells, c `elem` [Plant,Flower]]
  , shownPaused = isPaused s, shownMaterial = selectedMaterial s
  }
  where
    w = sessionWorld s
    cells = occupied w
    tile (p,c) = let (x,y) = xy p in Tile x y c
      (maybe True ((/= c) . cellAt w) (offset p (0,-1)))
      (sample (worldSeed w) p 0 `mod` 5 == 0)

materialName :: Material -> String
materialName m = case m of
  PourWater -> "Water"
  PlaceStone -> "Stone"
  PourSand -> "Sand"
  SowSeed -> "Seed"
  PlaceLight -> "Light"
  Erase -> "Erase"

materialHint :: Material -> String
materialHint m = case m of
  PourWater -> "Pour a little. It finds the lowest open path."
  PlaceStone -> "Make a ledge, a dam, or a place to rest."
  PourSand -> "Sand settles, and sinks through water."
  SowSeed -> "A seed needs water within 3 cells and light within 10."
  PlaceLight -> "A small sun. Light stays where you leave it."
  Erase -> "Open a gap in the stone and watch the water follow."

effectSummary :: [Effect] -> Maybe String
effectSummary effects = case find important (reverse effects) of
  Just Reset -> Just "The same seed. A fresh beginning."
  Just (Germinated _) -> Just "A seed found water + light. A first green leaf."
  Just (Grew _ _ _) -> Just "One new leaf grew. One drop of water was used."
  Just (Selected m) -> Just (materialHint m)
  Just (Paused True) -> Just "Time is resting. You can still shape the garden."
  Just (Paused False) -> Just "Time is flowing, one small cause after another."
  _ -> Nothing
  where
    important (Flowed _) = False
    important (Painted _ _) = False
    important _ = True
