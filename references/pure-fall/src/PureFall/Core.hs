{-# LANGUAGE TypeFamilies #-}

module PureFall.Core
  ( Kind (..),
    Rotation (..),
    Pose (..),
    Mode (..),
    Phase (..),
    Direction (..),
    Held (..),
    Command (..),
    TickInput (..),
    Cue (..),
    Spin (..),
    Clear (..),
    Settings,
    settings,
    dasTicks,
    arrTicks,
    Board,
    BoardError (..),
    board,
    cells,
    occupied,
    collapse,
    Game,
    fresh,
    seededGame,
    gameBoard,
    active,
    preview,
    heldPiece,
    holdAvailable,
    mode,
    phase,
    score,
    linesCleared,
    level,
    ticks,
    piecesLocked,
    combo,
    backToBack,
    gravityTicks,
    lockTicks,
    lockResets,
    lastClear,
    gameSettings,
    gameStep,
    step,
    PureFall (..),
    Player (..),
    AdmissionError (..),
    admittedStep,
    Observation (..),
    visibleObservation,
    greedyPolicy,
    shape,
    fits,
    shifted,
    rotated,
    landing,
    Landing,
    landingPose,
    landingPath,
    reachable,
    studySelect,
    studyCommit,
    SaveError (..),
    checkpoint,
    restore,
    validateGame,
    fixture,
    Fixture (..),
    scoring,
    spinAt,
    allKinds,
  )
where

import Data.Bits (shiftR, xor)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Word (Word64)
import Game.Arena qualified as Arena
import Game.Transition (Machine (..), Step (..))
import PureFall.Time
import Text.Read (readMaybe)

data Kind = I | O | T | S | Z | J | L deriving (Eq, Ord, Show, Read, Enum, Bounded)

data Rotation = R0 | R1 | R2 | R3 deriving (Eq, Ord, Show, Read, Enum, Bounded)

data Pose = Pose Kind Rotation Int Int deriving (Eq, Ord, Show, Read)

data Mode = Marathon | Sprint | Ultra | Practice deriving (Eq, Ord, Show, Read, Enum, Bounded)

data Phase = Falling | Paused | Studying | Won | Lost deriving (Eq, Ord, Show, Read)

data Direction = Neutral | Leftward | Rightward deriving (Eq, Ord, Show, Read)

data Held = Held Direction Bool deriving (Eq, Ord, Show, Read)

data Command = MoveLeft | MoveRight | MoveDown | Clockwise | Counterclockwise | HardDrop | SwapHold | Pause | Study deriving (Eq, Ord, Show, Read)

data TickInput = TickInput [Command] Held deriving (Eq, Show, Read)

data Spin = NoSpin | Mini | FullSpin deriving (Eq, Ord, Show, Read)

data Clear = Clear {clearRows :: [Int], clearSpin :: Spin, clearPoints :: Int, clearPerfect :: Bool, clearDifficult :: Bool} deriving (Eq, Show, Read)

data Cue = Moved | Turned | Dropped Int | HeldCue | Locked [((Int, Int), Kind)] | Cleared Clear | Finished Phase | PausedCue deriving (Eq, Show, Read)

data Settings = Settings Int Int deriving (Eq, Show)

instance Read Settings where
  readsPrec precedence = readParen (precedence > 10) $ \text -> do
    (name, afterName) <- lex text
    if name /= "Settings"
      then []
      else do
        (das, afterDas) <- readsPrec 11 afterName
        (arr, rest) <- readsPrec 11 afterDas
        case settings das arr of { Left _ -> []; Right valid -> [(valid, rest)] }

settings :: Int -> Int -> Either SaveError Settings
settings das arr
  | das >= 1 && das <= 30 && arr >= 0 && arr <= 10 = Right (Settings das arr)
  | otherwise = Left InvalidSettings

dasTicks :: Settings -> TickSpan
dasTicks (Settings das _) = tickSpan das

arrTicks :: Settings -> TickSpan
arrTicks (Settings _ arr) = tickSpan arr

newtype Board = Board (Map.Map (Int, Int) Kind) deriving (Eq, Show)

instance Read Board where
  readsPrec precedence = readParen (precedence > 10) $ \text -> do
    (name, afterName) <- lex text
    if name /= "Board"
      then []
      else do
        (value, rest) <- readsPrec 11 afterName
        case board (Map.toList value) of { Left _ -> []; Right valid -> [(valid, rest)] }

data BoardError = OutsideBoard (Int, Int) | DuplicateCell (Int, Int) deriving (Eq, Show)

board :: [((Int, Int), Kind)] -> Either BoardError Board
board entries = go Map.empty entries
  where
    go result [] = Right (Board result)
    go result ((point@(x, y), kind) : rest)
      | x < 0 || x >= 10 || y < 0 || y >= 24 = Left (OutsideBoard point)
      | Map.member point result = Left (DuplicateCell point)
      | otherwise = go (Map.insert point kind result) rest

cells :: Board -> [((Int, Int), Kind)]
cells (Board value) = Map.toAscList value

occupied :: Board -> (Int, Int) -> Bool
occupied (Board value) point@(x, y) = x < 0 || x >= 10 || y >= 24 || (y >= 0 && Map.member point value)

collapse :: Board -> (Board, [Int])
collapse value = (Board (Map.fromList remaining), full)
  where
    full = [y | y <- [0 .. 23], all (occupied value . (,y)) [0 .. 9]]
    remaining = [((x, y + length (filter (> y) full)), kind) | ((x, y), kind) <- cells value, y `notElem` full]

allKinds :: [Kind]
allKinds = [minBound .. maxBound]

shape :: Pose -> [(Int, Int)]
shape (Pose kind rotation px py) = [(x + px, y + py) | (x, y) <- oriented]
  where
    oriented = case rotation of R0 -> initial; R1 -> turn initial; R2 -> turn (turn initial); R3 -> turn (turn (turn initial))
    initial = case kind of
      I -> [(0, 1), (1, 1), (2, 1), (3, 1)]
      O -> [(1, 0), (2, 0), (1, 1), (2, 1)]
      T -> [(1, 0), (0, 1), (1, 1), (2, 1)]
      S -> [(1, 0), (2, 0), (0, 1), (1, 1)]
      Z -> [(0, 0), (1, 0), (1, 1), (2, 1)]
      J -> [(0, 0), (0, 1), (1, 1), (2, 1)]
      L -> [(2, 0), (0, 1), (1, 1), (2, 1)]
    turn points = case kind of
      O -> points
      I -> [(3 - y, x) | (x, y) <- points]
      _ -> [(2 - y, x) | (x, y) <- points]

fits :: Board -> Pose -> Bool
fits value pose = all (\point@(_, y) -> y >= 0 && not (occupied value point)) (shape pose)

shifted :: Board -> Int -> Int -> Pose -> Maybe Pose
shifted value dx dy (Pose kind rotation x y) =
  let candidate = Pose kind rotation (x + dx) (y + dy)
   in if fits value candidate then Just candidate else Nothing

rotated :: Board -> Bool -> Pose -> Maybe (Pose, Int)
rotated value clockwise pose@(Pose kind from x y)
  | kind == O = Just (pose, 0)
  | otherwise = firstFit (zip [0 ..] (kicks kind from to))
  where
    to = toEnum ((fromEnum from + if clockwise then 1 else 3) `mod` 4)
    firstFit [] = Nothing
    firstFit ((index, (dx, dy)) : rest) =
      let candidate = Pose kind to (x + dx) (y - dy)
       in if fits value candidate then Just (candidate, index) else firstFit rest

kicks :: Kind -> Rotation -> Rotation -> [(Int, Int)]
kicks kind from to
  | kind == I = case (from, to) of
      (R0, R1) -> [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)]
      (R1, R0) -> [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)]
      (R1, R2) -> [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)]
      (R2, R1) -> [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)]
      (R2, R3) -> [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)]
      (R3, R2) -> [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)]
      (R3, R0) -> [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)]
      (R0, R3) -> [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)]
      _ -> [(0, 0)]
  | otherwise = case (from, to) of
      (R0, R1) -> a
      (R2, R1) -> a
      (R1, R0) -> b
      (R1, R2) -> b
      (R2, R3) -> c
      (R0, R3) -> c
      (R3, R2) -> d
      (R3, R0) -> d
      _ -> [(0, 0)]
  where
    a = [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)]
    b = [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)]
    c = [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)]
    d = [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)]

landing :: Board -> Pose -> Pose
landing value pose = maybe pose (landing value) (shifted value 0 1 pose)

data RawGame = RawGame
  { rawBoard :: Board,
    rawActive :: Maybe Pose,
    rawQueue :: [Kind],
    rawBag :: [Kind],
    rawSeed :: Word64,
    rawHold :: Maybe Kind,
    rawCanHold :: Bool,
    rawMode :: Mode,
    rawPhase :: Phase,
    rawScore :: Int,
    rawLines :: Int,
    rawTicks :: Int,
    rawPieces :: Int,
    rawCombo :: Int,
    rawB2B :: Bool,
    rawGravity :: Int,
    rawLock :: Int,
    rawResets :: Int,
    rawRotation :: Maybe Int,
    rawDirection :: Direction,
    rawRepeat :: Int,
    rawSettings :: Settings,
    rawClear :: Maybe Clear
  }
  deriving (Eq, Show, Read)

newtype Game = Game RawGame deriving (Eq, Show)

fresh :: Mode -> Word64 -> Game
fresh chosen seed = seededGame chosen seed (Settings 9 2)

seededGame :: Mode -> Word64 -> Settings -> Game
seededGame chosen seed config =
  fst (spawn (Game (RawGame (Board Map.empty) Nothing [] [] seed Nothing True chosen Falling 0 0 0 0 (-1) False 0 0 0 Nothing Neutral 0 config Nothing)))

nextRandom :: Word64 -> Word64
nextRandom seed =
  let z = seed + 0x9e3779b97f4a7c15
      a = (z `xor` (z `shiftR` 30)) * 0xbf58476d1ce4e5b9
      b = (a `xor` (a `shiftR` 27)) * 0x94d049bb133111eb
   in b `xor` (b `shiftR` 31)

shuffle :: Word64 -> [Kind] -> ([Kind], Word64)
shuffle seed [] = ([], seed)
shuffle seed choices =
  let nextSeed = nextRandom seed
      index = fromIntegral (nextSeed `mod` fromIntegral (length choices))
      (before, selected) = splitAt index choices
   in case selected of
        [] -> ([], nextSeed)
        first : after -> let (rest, finalSeed) = shuffle nextSeed (before ++ after) in (first : rest, finalSeed)

fillQueue :: RawGame -> RawGame
fillQueue state
  | length (rawQueue state) >= 6 = state
  | otherwise = case rawBag state of
      [] -> let (bag', seed') = shuffle (rawSeed state) allKinds in fillQueue state {rawBag = bag', rawSeed = seed'}
      first : rest -> fillQueue state {rawQueue = rawQueue state ++ [first], rawBag = rest}

spawnKind :: Kind -> RawGame -> (Game, [Cue])
spawnKind kind state =
  let pose = Pose kind R0 3 3
      updated = state {rawActive = Just pose, rawGravity = 0, rawLock = 0, rawResets = 0, rawRotation = Nothing, rawDirection = Neutral, rawRepeat = 0}
   in if fits (rawBoard state) pose then (Game updated, []) else (Game updated {rawPhase = Lost}, [Finished Lost])

spawn :: Game -> (Game, [Cue])
spawn (Game state) = case rawQueue (fillQueue state) of
  [] -> (Game state {rawPhase = Lost}, [Finished Lost])
  first : rest -> spawnKind first (fillQueue ((fillQueue state) {rawQueue = rest}))

gameBoard :: Game -> Board
gameBoard (Game state) = rawBoard state

active :: Game -> Maybe Pose
active (Game state) = rawActive state

preview :: Game -> [Kind]
preview (Game state) = take 5 (rawQueue state)

heldPiece :: Game -> Maybe Kind
heldPiece (Game state) = rawHold state

holdAvailable :: Game -> Bool
holdAvailable (Game state) = rawCanHold state

mode :: Game -> Mode
mode (Game state) = rawMode state

phase :: Game -> Phase
phase (Game state) = rawPhase state

score :: Game -> Int
score (Game state) = rawScore state

linesCleared :: Game -> Int
linesCleared (Game state) = rawLines state

level :: Game -> Int
level game = 1 + linesCleared game `div` 10

ticks :: Game -> TickNo
ticks (Game state) = tickNo (rawTicks state)

piecesLocked :: Game -> Int
piecesLocked (Game state) = rawPieces state

combo :: Game -> Int
combo (Game state) = rawCombo state

backToBack :: Game -> Bool
backToBack (Game state) = rawB2B state

gravityTicks :: Game -> TickSpan
gravityTicks game = tickSpan $ case mode game of Practice -> 60; _ -> max 1 (round (60 * (0.8 - fromIntegral (min 15 (level game) - 1) * 0.007) ** fromIntegral (level game - 1) :: Double))

lockTicks :: Game -> TickSpan
lockTicks (Game state) = tickSpan (rawLock state)

lockResets :: Game -> Int
lockResets (Game state) = rawResets state

lastClear :: Game -> Maybe Clear
lastClear (Game state) = rawClear state

gameSettings :: Game -> Settings
gameSettings (Game state) = rawSettings state

gameStep :: Step Game TickInput [Cue]
gameStep = Step step

step :: TickInput -> Game -> (Game, [Cue])
step (TickInput commands held) game@(Game initial)
  | Pause `elem` commands = case phase game of
      Falling -> (Game initial {rawPhase = Paused, rawDirection = Neutral, rawRepeat = 0}, [PausedCue])
      Studying -> (Game initial {rawPhase = Paused, rawDirection = Neutral, rawRepeat = 0}, [PausedCue])
      Paused -> (Game initial {rawPhase = Falling, rawDirection = Neutral, rawRepeat = 0}, [PausedCue])
      _ -> (game, [])
  | Study `elem` commands && mode game == Practice = case phase game of
      Falling -> (Game initial {rawPhase = Studying, rawDirection = Neutral, rawRepeat = 0}, [PausedCue])
      Studying -> (Game initial {rawPhase = Falling}, [PausedCue])
      _ -> (game, [])
  | phase game == Studying = applyCommands commands game
  | phase game /= Falling = (game, [])
  | otherwise =
      let clocked = Game initial {rawTicks = rawTicks initial + 1}
          (afterEdges, edgeCues) = applyCommands commands clocked
          (afterRepeat, repeatCues) = if piecesLocked afterEdges /= piecesLocked game then (afterEdges, []) else repeatHeld commands held afterEdges
          (afterTime, timeCues) = if piecesLocked afterRepeat /= piecesLocked game then (afterRepeat, []) else advanceTime held afterRepeat
          (finished, endCues) = objective afterTime
       in (finished, edgeCues ++ repeatCues ++ timeCues ++ endCues)

applyCommands :: [Command] -> Game -> (Game, [Cue])
applyCommands [] game = (game, [])
applyCommands (command : rest) game
  | phase game `notElem` [Falling, Studying] = (game, [])
  | otherwise =
      let (next, cues) = apply command game
       in if piecesLocked next /= piecesLocked game || (command == SwapHold && HeldCue `elem` cues)
            then (next, cues)
            else let (final, more) = applyCommands rest next in (final, cues ++ more)

apply :: Command -> Game -> (Game, [Cue])
apply command game@(Game state) = case active game of
  Nothing -> (game, [])
  Just pose@(Pose kind _ _ y) -> case command of
    MoveLeft -> translate (-1) 0
    MoveRight -> translate 1 0
    MoveDown -> translate 0 1
    Clockwise -> turn True
    Counterclockwise -> turn False
    HardDrop ->
      let target@(Pose _ _ _ yy) = landing (rawBoard state) pose
          distance = yy - y
          (next, cues) = lockPiece (Game state {rawActive = Just target, rawScore = rawScore state + 2 * distance})
       in (next, Dropped distance : cues)
    SwapHold
      | rawCanHold state ->
          let heldState = state {rawHold = Just kind, rawCanHold = False}
              (next, cues) = maybe (spawn (Game heldState)) (\old -> spawnKind old heldState) (rawHold state)
           in (next, HeldCue : cues)
    _ -> (game, [])
    where
      translate dx dy = case shifted (rawBoard state) dx dy pose of
        Nothing -> (game, [])
        Just moved ->
          let changed = if dy == 0 then resetLock state pose else state
              next = changed {rawActive = Just moved, rawRotation = Nothing, rawScore = rawScore changed + if dy > 0 then 1 else 0}
           in (Game next, [Moved])
      turn clockwise = case rotated (rawBoard state) clockwise pose of
        Nothing -> (game, [])
        Just (turned, kickIndex) ->
          let changed = resetLock state pose
           in (Game changed {rawActive = Just turned, rawRotation = Just kickIndex}, [Turned])

resetLock :: RawGame -> Pose -> RawGame
resetLock state pose
  | shifted (rawBoard state) 0 1 pose == Nothing && rawResets state < 15 = state {rawLock = 0, rawResets = rawResets state + 1}
  | otherwise = state

repeatHeld :: [Command] -> Held -> Game -> (Game, [Cue])
repeatHeld commands (Held direction _) game@(Game state)
  | phase game /= Falling = (game, [])
  | direction == Neutral = (Game state {rawDirection = Neutral, rawRepeat = 0}, [])
  | otherwise =
      let age = if direction == rawDirection state && not edgeAlreadyMoved then rawRepeat state + 1 else 0
          config = rawSettings state
          das = tickSpanCount (dasTicks config)
          arr = tickSpanCount (arrTicks config)
          command = if direction == Leftward then MoveLeft else MoveRight
          edgeAlreadyMoved = command `elem` commands
          due = (age == 0 && not edgeAlreadyMoved) || (age >= das && (arr == 0 || (age - das) `mod` arr == 0))
          updated = Game state {rawDirection = direction, rawRepeat = age}
          times = if age >= das && arr == 0 then 10 else 1
       in if due then applyCommands (replicate times command) updated else (updated, [])

advanceTime :: Held -> Game -> (Game, [Cue])
advanceTime (Held _ soft) game@(Game state)
  | phase game /= Falling = (game, [])
  | otherwise = case active game of
      Nothing -> (game, [])
      Just pose ->
        let normalInterval = tickSpanCount (gravityTicks game)
            interval = if soft then min 2 normalInterval else normalInterval
            due = rawGravity state + 1 >= interval
            shiftedPose = if due then shifted (rawBoard state) 0 1 pose else Nothing
            nextPose = maybe pose id shiftedPose
            grounded = shifted (rawBoard state) 0 1 nextPose == Nothing
            nextLock = if grounded then rawLock state + 1 else 0
            next =
              Game
                state
                  { rawActive = Just nextPose,
                    rawGravity = if due then 0 else rawGravity state + 1,
                    rawLock = nextLock,
                    rawRotation = if soft && shiftedPose /= Nothing then Nothing else rawRotation state,
                    rawScore = rawScore state + if soft && shiftedPose /= Nothing then 1 else 0
                  }
         in if nextLock >= 30 then lockPiece next else (next, [])

spinAt :: Board -> Pose -> Maybe Int -> Spin
spinAt value (Pose T rotation x y) (Just kickIndex)
  | length (filter (occupied value) corners) >= 3 = if all (occupied value) front || kickIndex == 4 then FullSpin else Mini
  | otherwise = NoSpin
  where
    corners = [(x, y), (x + 2, y), (x, y + 2), (x + 2, y + 2)]
    front = case rotation of
      R0 -> [(x, y), (x + 2, y)]
      R1 -> [(x + 2, y), (x + 2, y + 2)]
      R2 -> [(x, y + 2), (x + 2, y + 2)]
      R3 -> [(x, y), (x, y + 2)]
spinAt _ _ _ = NoSpin

scoring :: Int -> Spin -> Int -> Bool -> Int -> Bool -> (Int, Bool)
scoring currentLevel spin count previousB2B currentCombo perfect = (points, nextB2B)
  where
    difficult = count == 4 || (spin /= NoSpin && count > 0)
    basePoints = case (spin, count) of
      (FullSpin, 0) -> 400
      (FullSpin, 1) -> 800
      (FullSpin, 2) -> 1200
      (FullSpin, _) -> 1600
      (Mini, 0) -> 100
      (Mini, 1) -> 200
      (Mini, _) -> 400
      (_, 1) -> 100
      (_, 2) -> 300
      (_, 3) -> 500
      (_, 4) -> 800
      _ -> 0
    b2bPoints = if difficult && previousB2B then basePoints `div` 2 else 0
    comboPoints = if count > 0 then 50 * max 0 currentCombo else 0
    perfectPoints = if perfect && count > 0 then case count of 1 -> 800; 2 -> 1200; 3 -> 1800; _ -> 2000 else 0
    points = currentLevel * (basePoints + b2bPoints + comboPoints + perfectPoints)
    nextB2B = if count == 0 then previousB2B else difficult

lockPiece :: Game -> (Game, [Cue])
lockPiece game@(Game state) = case active game of
  Nothing -> (game, [])
  Just pose@(Pose kind _ _ _) ->
    let additions = [(point, kind) | point <- shape pose]
        Board previous = rawBoard state
        (collapsed, rows) = collapse (Board (foldl' (\value (point, tile) -> Map.insert point tile value) previous additions))
        spin = spinAt (rawBoard state) pose (rawRotation state)
        count = length rows
        nextCombo = if count > 0 then rawCombo state + 1 else -1
        perfect = null (cells collapsed)
        (points, b2b) = scoring (level game) spin count (rawB2B state) nextCombo perfect
        result = Clear rows spin points perfect (count == 4 || (spin /= NoSpin && count > 0))
        locked =
          state
            { rawBoard = collapsed,
              rawActive = Nothing,
              rawScore = rawScore state + points,
              rawLines = rawLines state + count,
              rawPieces = rawPieces state + 1,
              rawCanHold = True,
              rawCombo = nextCombo,
              rawB2B = b2b,
              rawClear = Just result
            }
        lockOut = all ((< 4) . snd) (shape pose)
        (next, spawnCues) = if lockOut then (Game locked {rawPhase = Lost}, [Finished Lost]) else spawn (Game locked)
     in (next, [Locked additions] ++ [Cleared result | count > 0 || spin /= NoSpin] ++ spawnCues)

objective :: Game -> (Game, [Cue])
objective game@(Game state)
  | phase game /= Falling = (game, [])
  | (mode game == Sprint && linesCleared game >= 40) || (mode game == Ultra && rawTicks state >= 7200) = (Game state {rawPhase = Won}, [Finished Won])
  | otherwise = (game, [])

data PureFall = PureFall

data Player = Player deriving (Eq, Show)

data AdmissionError = InvalidParticipant | TooManyCommands deriving (Eq, Show)

instance Machine PureFall where
  type State PureFall = Game
  type Input PureFall = TickInput
  type Output PureFall = [Cue]
  machine _ = gameStep

instance Arena.Arena PureFall where
  type Agent PureFall = Player
  type Action PureFall = TickInput
  type Context PureFall = ()
  type View PureFall = Observation
  type Rejection PureFall = AdmissionError
  observe _ _ = visibleObservation
  admit _ _ choices _ = case Arena.submissions choices of
    [] -> Right (TickInput [] (Held Neutral False))
    [(Player, input@(TickInput commands _))]
      | length commands <= 32 -> Right input
      | otherwise -> Left TooManyCommands
    _ -> Left InvalidParticipant

admittedStep :: TickInput -> Game -> (Game, [Cue])
admittedStep input game = case Arena.play PureFall () (Arena.singleton Player input) game of
  Right result -> result
  Left _ -> (game, [])

data Observation = Observation
  { observedBoard :: Board,
    observedActive :: Maybe Pose,
    observedPreview :: [Kind],
    observedHold :: Maybe Kind,
    observedMode :: Mode,
    observedPhase :: Phase,
    observedScore :: Int,
    observedLines :: Int
  }
  deriving (Eq, Show)

visibleObservation :: Game -> Observation
visibleObservation game = Observation (gameBoard game) (active game) (preview game) (heldPiece game) (mode game) (phase game) (score game) (linesCleared game)

greedyPolicy :: Arena.Policy Observation TickInput
greedyPolicy = Arena.Policy $ \history -> case history of
  [] -> TickInput [] (Held Neutral False)
  latest : _ -> case observedActive (Arena.view latest) of
    Nothing -> TickInput [] (Held Neutral False)
    Just pose ->
      let value = observedBoard (Arena.view latest)
          candidates = reachableFrom value pose
          quality entry = let Pose _ _ x y = landingPose entry in (y, negate (abs (x - 3)))
          chosen = foldl' (\best candidate -> if quality candidate > quality best then candidate else best) (Landing pose []) candidates
       in TickInput (take 1 (landingPath chosen ++ [HardDrop])) (Held Neutral False)

data Landing = Landing Pose [Command] deriving (Eq, Show)

landingPose :: Landing -> Pose
landingPose (Landing pose _) = pose

landingPath :: Landing -> [Command]
landingPath (Landing _ path) = path

reachable :: Game -> [Landing]
reachable game = maybe [] (reachableFrom (gameBoard game)) (active game)

reachableFrom :: Board -> Pose -> [Landing]
reachableFrom value initial
  | not (fits value initial) = []
  | otherwise = search (Set.singleton initial) (Seq.singleton (initial, [])) []
  where
    search seen queue result = case Seq.viewl queue of
      Seq.EmptyL -> reverse result
      (pose, path) Seq.:< rest ->
        let choices =
              [ (MoveLeft, shifted value (-1) 0 pose),
                (MoveRight, shifted value 1 0 pose),
                (MoveDown, shifted value 0 1 pose),
                (Clockwise, fst <$> rotated value True pose),
                (Counterclockwise, fst <$> rotated value False pose)
              ]
            novel = [(next, path ++ [command]) | (command, Just next) <- choices, Set.notMember next seen]
            updatedSeen = foldl' (\known (next, _) -> Set.insert next known) seen novel
            updatedResult = if shifted value 0 1 pose == Nothing then Landing pose path : result else result
         in search updatedSeen (rest Seq.>< Seq.fromList novel) updatedResult

studySelect :: Int -> Game -> Maybe Landing
studySelect index game = case reachable game of
  [] -> Nothing
  options -> case drop (index `mod` length options) options of first : _ -> Just first; [] -> Nothing

studyCommit :: Landing -> Game -> (Game, [Cue])
studyCommit entry game
  | phase game /= Studying = (game, [])
  | entry `notElem` reachable game = (game, [])
  | otherwise = foldl' playAction (game, []) (landingPath entry ++ [HardDrop])
  where
    playAction (current, cues) command = let (next, more) = admittedStep (TickInput [command] (Held Neutral False)) current in (next, cues ++ more)

data SaveError = InvalidSyntax | UnsupportedVersion | InvalidBoard | InvalidQueue | InvalidActive | InvalidCounters | InvalidSettings | InvalidClear deriving (Eq, Show)

data Saved = Saved Int RawGame deriving (Show, Read)

checkpoint :: Game -> String
checkpoint (Game state) = show (Saved 1 state)

restore :: String -> Either SaveError Game
restore text
  | length text > 200000 = Left InvalidSyntax
  | otherwise = case readMaybe text of
      Nothing -> Left InvalidSyntax
      Just (Saved version raw)
        | version /= 1 -> Left UnsupportedVersion
        | otherwise -> let game = Game raw in validateGame game >> Right game

validateGame :: Game -> Either SaveError ()
validateGame game@(Game state)
  | either (const True) (const False) (board (cells (rawBoard state))) = Left InvalidBoard
  | any (\y -> all (occupied (rawBoard state) . (,y)) [0 .. 9]) [0 .. 23] = Left InvalidBoard
  | length (rawQueue state) /= 6 || length (rawBag state) > 7 || length (Set.fromList (rawBag state)) /= length (rawBag state) = Left InvalidQueue
  | phase game `elem` [Falling, Paused, Studying] && maybe True (not . fits (rawBoard state)) (rawActive state) = Left InvalidActive
  | any (< 0) [rawScore state, rawLines state, rawTicks state, rawPieces state, rawGravity state, rawLock state, rawResets state, rawRepeat state]
      || rawCombo state < -1
      || rawCombo state > rawPieces state
      || rawResets state > 15
      || rawLock state > 30
      || rawGravity state > 60
      || rawRepeat state > 1000000000
      || rawTicks state > 1000000000
      || rawLines state > 1000000
      || rawPieces state > 10000000
      || rawScore state > 1000000000000 =
      Left InvalidCounters
  | maybe False (\index -> index < 0 || index > 4) (rawRotation state) = Left InvalidCounters
  | phase game == Studying && mode game /= Practice = Left InvalidActive
  | maybe False (any (\(x, y) -> x < 0 || x >= 10 || y < 0 || y >= 24) . shape) (rawActive state) = Left InvalidActive
  | either (const True) (const False) (settings (tickSpanCount (dasTicks (rawSettings state))) (tickSpanCount (arrTicks (rawSettings state)))) = Left InvalidSettings
  | maybe False invalidClear (rawClear state) = Left InvalidClear
  | otherwise = Right ()
  where
    invalidClear clear = clearPoints clear < 0 || length (clearRows clear) > 4 || any (\y -> y < 0 || y >= 24) (clearRows clear) || sort (Set.toList (Set.fromList (clearRows clear))) /= sort (clearRows clear)

data Fixture = FourLine | SpinSingle | Cavity | NearSprint | NearUltra | TopOut deriving (Eq, Show, Read)

fixture :: Fixture -> Game
fixture chosen =
  Game
    ( base
        { rawBoard = value,
          rawActive = Just pose,
          rawMode = chosenMode,
          rawLines = lineCount,
          rawTicks = initialTick,
          rawRotation = if chosen == SpinSingle then Just 0 else Nothing
        }
    )
  where
    Game base = fresh Practice 20261026
    (entries, pose, chosenMode, lineCount, initialTick) = case chosen of
      FourLine -> ([((x, y), J) | y <- [20 .. 23], x <- [0 .. 9], x /= 4], Pose I R1 2 20, Practice, 0, 0)
      SpinSingle -> ([((x, 23), J) | x <- [0 .. 9], x `notElem` [3, 4, 5]] ++ [((3, 22), J), ((5, 22), J)], Pose T R0 3 22, Practice, 0, 0)
      Cavity -> ([((x, 20), J) | x <- [0 .. 5]] ++ [((0, y), J) | y <- [21 .. 23]] ++ [((5, y), J) | y <- [21 .. 23]], Pose T R0 3 2, Practice, 0, 0)
      NearSprint -> ([((x, y), J) | y <- [20 .. 23], x <- [0 .. 9], x /= 4], Pose I R1 2 20, Sprint, 36, 0)
      NearUltra -> ([], Pose T R0 3 2, Ultra, 0, 7199)
      TopOut -> ([((x, 4), J) | x <- [3 .. 6]], Pose O R0 3 2, Practice, 0, 0)
    value = Board (Map.fromList entries)
