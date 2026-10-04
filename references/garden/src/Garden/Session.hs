-- | Commands edit/control the world without advancing logical time. Tick is a
-- different event. StepOnce is the sole explicit command that advances a tick.
module Garden.Session
  ( Session, newSession, sessionWorld, isPaused, selectedMaterial
  , Command (..), Event (..), advance, applyEvents
  ) where

import Data.List (foldl')
import Garden.Simulation
import Garden.World

data Session = Session !World !Bool !Material deriving (Eq, Show)

data Command = TogglePause | StepOnce | ResetSameSeed | Select !Material
  | Paint !Coord | EraseAt !Coord deriving (Eq, Show)

data Event = Input !Command | Tick deriving (Eq, Show)

newSession :: Seed -> Session
newSession s = Session (initialWorld s) True PourWater

sessionWorld :: Session -> World
sessionWorld (Session w _ _) = w

isPaused :: Session -> Bool
isPaused (Session _ p _) = p

selectedMaterial :: Session -> Material
selectedMaterial (Session _ _ m) = m

advance :: Event -> Session -> (Session, [Effect])
advance Tick s@(Session w paused material)
  | paused = (s, [])
  | otherwise = let (w',fx) = stepWorld w in (Session w' False material, fx)
advance (Input command) (Session w paused material) = case command of
  TogglePause -> (Session w (not paused) material, [Paused (not paused)])
  StepOnce -> let (w',fx) = stepWorld w in (Session w' True material, Paused True : fx)
  ResetSameSeed -> (Session (initialWorld (worldSeed w)) True material, [Reset])
  Select m -> (Session w paused m, [Selected m])
  Paint p -> paint material p
  EraseAt p -> paint Erase p
  where
    paint m p =
      let radius = if m `elem` [SowSeed,PlaceLight] then 0 else 1
          edits = [ (q,materialCell m)
                  | dy <- [-radius .. radius], dx <- [-radius .. radius]
                  , dx*dx + dy*dy <= radius*radius, Just q <- [offset p (dx,dy)]
                  , cellAt w q /= materialCell m ]
       in (Session (writeCells edits w) paused material,
             [Painted m (length edits) | not (null edits)])

-- | Ordered, lossless events, including repeated presses.
applyEvents :: [Event] -> Session -> (Session, [Effect])
applyEvents events initial =
  let (s, reversed) = foldl' go (initial, []) events
   in (s, reverse reversed)
  where
    go (s, effects) event = let (s',fx) = advance event s in (s', reverse fx ++ effects)
