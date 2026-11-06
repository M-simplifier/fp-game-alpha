module PureFall.View
  ( RenderModel (..),
    CellView (..),
    CellRole (..),
    renderModel,
    clearLabel,
    modeLabel,
    timeLabel,
    objectiveLabel,
  )
where

import PureFall.Core
import PureFall.Time

data CellRole = SettledCell | ActiveCell | GhostCell | StudyCell deriving (Eq, Show)

data CellView = CellView {cellX :: Int, cellY :: Int, cellKind :: Kind, cellRole :: CellRole} deriving (Eq, Show)

data RenderModel = RenderModel
  { viewCells :: [CellView],
    viewActive :: Maybe Pose,
    viewHold :: Maybe Kind,
    viewHoldReady :: Bool,
    viewNext :: [Kind],
    viewMode :: Mode,
    viewPhase :: Phase,
    viewScore :: Int,
    viewLines :: Int,
    viewLevel :: Int,
    viewTime :: String,
    viewObjective :: String,
    viewCombo :: Int,
    viewB2B :: Bool,
    viewLockFraction :: Float,
    viewLastClear :: String,
    viewPieces :: Int,
    viewStudyCount :: Int,
    viewStudyIndex :: Int,
    viewStudyPathLength :: Int,
    viewDas :: Int,
    viewArr :: Int
  }
  deriving (Eq, Show)

renderModel :: Int -> Game -> RenderModel
renderModel studyIndex game =
  RenderModel
    projected
    (active game)
    (heldPiece game)
    (holdAvailable game)
    (preview game)
    (mode game)
    (phase game)
    (score game)
    (linesCleared game)
    (level game)
    (timeLabel (ticks game))
    (objectiveLabel game)
    (combo game)
    (backToBack game)
    (fromIntegral (tickSpanCount (lockTicks game)) / 30)
    (maybe "" clearLabel (lastClear game))
    (piecesLocked game)
    (length placements)
    selected
    (maybe 0 (length . landingPath) chosen)
    (tickSpanCount (dasTicks (gameSettings game)))
    (tickSpanCount (arrTicks (gameSettings game)))
  where
    placements = if phase game == Studying then reachable game else []
    selected = if null placements then 0 else studyIndex `mod` length placements
    chosen = case drop selected placements of first : _ -> Just first; [] -> Nothing
    project role kind (x, y) = CellView x (y - 4) kind role
    poseCells role (Pose kind rotation x y) = map (project role kind) (shape (Pose kind rotation x y))
    projected =
      map (\(point, kind) -> project SettledCell kind point) (cells (gameBoard game))
        ++ maybe [] (poseCells GhostCell . landing (gameBoard game)) (active game)
        ++ maybe [] (poseCells StudyCell . landingPose) chosen
        ++ maybe [] (poseCells ActiveCell) (active game)

clearLabel :: Clear -> String
clearLabel clear = spinLabel ++ rowLabel ++ if clearPerfect clear && not (null (clearRows clear)) then " / PERFECT" else ""
  where
    spinLabel = case clearSpin clear of NoSpin -> ""; Mini -> "T-SPIN MINI "; FullSpin -> "T-SPIN "
    rowLabel = case length (clearRows clear) of 0 -> ""; 1 -> "SINGLE"; 2 -> "DOUBLE"; 3 -> "TRIPLE"; _ -> "FOUR LINES"

modeLabel :: Mode -> String
modeLabel chosen = case chosen of Marathon -> "MARATHON"; Sprint -> "40 LINE SPRINT"; Ultra -> "TWO MINUTE"; Practice -> "PRACTICE"

timeLabel :: TickNo -> String
timeLabel tick = pad (count `div` 3600) ++ ":" ++ pad ((count `div` 60) `mod` 60) ++ "." ++ pad ((count `mod` 60) * 100 `div` 60)
  where
    count = tickCount tick
    pad n = if n < 10 then '0' : show n else show n

objectiveLabel :: Game -> String
objectiveLabel game = case mode game of
  Marathon -> "ENDLESS / LEVEL " ++ show (level game)
  Sprint -> show (max 0 (40 - linesCleared game)) ++ " LINES TO GO"
  Ultra -> timeLabel (tickNo (7200 - tickCount (ticks game))) ++ " REMAINING"
  Practice -> "REWIND / EXPLORE / TRY AGAIN"
