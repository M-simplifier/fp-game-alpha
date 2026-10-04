{-# LANGUAGE TypeFamilies #-}

-- | 世界の一歩。時計は環境が供給し、庭師は操作を選ぶ。
-- 試行の受理と、採掘・贈り物などが世界内で成功する条件は別である。
module Garden.Arena
  ( Afterlight (..), Gardener (..), TickBoundary (..), AdmissionError (..)
  , tickChoices
  ) where

import Game.Arena
import Game.Transition
import Garden.Rules qualified as Rules
import Garden.Types qualified as Garden
import Garden.View (SceneView, project)

data Afterlight = Afterlight
data Gardener = Gardener deriving (Eq, Show)
data TickBoundary = FixedTick deriving (Eq, Show)
data AdmissionError = UnexpectedParticipants deriving (Eq, Show)

instance Machine Afterlight where
  type State Afterlight = Garden.World
  type Input Afterlight = Garden.Input
  type Output Afterlight = [Garden.Cue]
  machine _ = Step Rules.advance

instance Arena Afterlight where
  type Agent Afterlight = Gardener
  type Action Afterlight = Garden.Input
  type Context Afterlight = TickBoundary
  -- 完全な描画投影。HUDだけの観測を描画の正本と取り違えない。
  type View Afterlight = SceneView
  type Rejection Afterlight = AdmissionError
  observe _ Gardener = project
  admit _ FixedTick choices _ = case submissions choices of
    [] -> Right Garden.idleInput
    [(Gardener, controls)] -> Right controls
    _ -> Left UnexpectedParticipants

tickChoices :: Garden.Input -> Joint Gardener Garden.Input
tickChoices = singleton Gardener
