module Main (main) where

import Control.Monad (unless)
import Data.Map.Strict qualified as M
import Game.Arena qualified as Arena
import Garden.Arena (Gardener (..))
import Garden.Clock
import Garden.Session
import Garden.Tour (Pilot (..))
import Garden.Types
import Garden.View (sceneEye)
import Garden.World (initialWorld)

main :: IO ()
main = do
  let world = initialWorld {worldCells = M.empty, worldKin = [], worldAdversaries = []}
      initial = beginSimulation world
      controls = idleInput {moveForward = 1, lookYaw = 0.125, jumpEdge = True}
      (_, clock) = schedule (1 / 60) controls emptyClock
      renderState current currentClock prior =
        "Simulation {simulationWorld = "
          <> show current
          <> ", simulationClock = "
          <> show currentClock
          <> ", previousTickEye = "
          <> show prior
          <> ", simulationPilot = "
          <> show (Pilot 0 0)
          <> "}"
      initialText = renderState world emptyClock (eye (worldPlayer world))
  unless (simulationWorld initial == world && simulationPilot initial == Pilot 0 0) (fail "Public read accessors changed")
  unless (show initial == initialText) (fail "Initial Show vocabulary changed")
  unless (showsPrec 11 initial "" == "(" <> initialText <> ")") (fail "Initial Show precedence changed")
  case Arena.play AfterlightSession (FrameBoundary (1 / 60) Advancing HumanDriver) (frameChoices controls False) initial of
    Left rejection -> fail (show rejection)
    Right (next, effects) -> do
      let nextWorld = simulationWorld next
          nextText = renderState nextWorld clock (eye (worldPlayer world))
          suspended = suspendSimulation next
          observed = Arena.observe AfterlightSession Gardener next
      unless (worldTick nextWorld == Tick 1 && length (tickCues effects) == 1) (fail "Public transition changed")
      unless (show next == nextText) (fail "Transition Show vocabulary changed")
      unless (showsPrec 11 next "" == "(" <> nextText <> ")") (fail "Transition Show precedence changed")
      unless (simulationWorld suspended == nextWorld && simulationPilot suspended == simulationPilot next) (fail "Suspend changed persistent state")
      unless (initial == beginSimulation world && next /= suspended) (fail "Session Eq stopped observing the clock")
      unless (sceneEye (exactScene observed) == eye (worldPlayer nextWorld) && sceneEye (interpolatedScene observed) == eye (worldPlayer world)) (fail "Valid transition interpolation changed")
      print (initial == beginSimulation world, next == suspended)
      print (show initial, showsPrec 11 initial "")
      print (show next, showsPrec 11 next "")
      print (effects, Arena.observe AfterlightSession Gardener next, Arena.observe AfterlightSession Gardener suspended)
