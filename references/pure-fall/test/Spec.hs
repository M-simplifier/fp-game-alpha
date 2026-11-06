module Main (main) where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word64)
import Game.Arena qualified as Arena
import Game.Transition qualified as Transition
import PureFall.Core
import PureFall.Session
import PureFall.Time
import PureFall.View
import System.Exit (exitFailure)
import Test.QuickCheck hiding (label)
import Text.Read (readMaybe)

main :: IO ()
main = do
  scenarios
  propertyCheck "seven bag / 500 seeds" 500 bagProperty
  propertyCheck "collapse / independent grid oracle" 1200 collapseProperty
  propertyCheck "collision / independent occupancy oracle" 1200 collisionProperty
  propertyCheck "valid state after 300 arbitrary admitted boundaries" 250 stateProperty
  propertyCheck "trace chronological composition" 500 compositionProperty
  propertyCheck "checkpoint immediate projection + suffix effects" 400 checkpointProperty
  propertyCheck "study witness / frozen production actions" 150 witnessProperty
  putStrLn "All PURE / FALL checks passed."

check :: String -> Bool -> IO ()
check label passed = do
  putStrLn ((if passed then "PASS " else "FAIL ") ++ label)
  unless passed exitFailure

propertyCheck :: (Testable property) => String -> Int -> property -> IO ()
propertyCheck label count test = do
  putStrLn label
  result <- quickCheckWithResult stdArgs {maxSuccess = count, maxSize = 70} test
  unless (isSuccess result) exitFailure

neutral :: Held
neutral = Held Neutral False

input :: [Command] -> TickInput
input commands = TickInput commands neutral

advance :: [Command] -> Game -> Game
advance commands = fst . admittedStep (input commands)

run :: [TickInput] -> Game -> Game
run commands initial = fst (Transition.replay gameStep commands initial)

poseKind :: Pose -> Kind
poseKind (Pose kind _ _ _) = kind

activeKind :: Game -> Maybe Kind
activeKind = fmap poseKind . active

scenarios :: IO ()
scenarios = do
  check "board rejects duplicates" (isLeft (board [((1, 1), T), ((1, 1), I)]))
  check "board rejects outside bounds" (isLeft (board [((10, 0), T)]))
  check "Read cannot bypass Settings validator" ((readMaybe "Settings 0 99" :: Maybe Settings) == Nothing)
  check "Read cannot bypass Board validator" ((readMaybe "Board (fromList [((99,0),T)])" :: Maybe Board) == Nothing)
  check "SRS clockwise convention independently authored" (sort (shape (Pose T R1 0 0)) == sort [(1, 0), (1, 1), (2, 1), (1, 2)])
  check "SRS I clockwise convention" (sort (shape (Pose I R1 0 0)) == [(2, 0), (2, 1), (2, 2), (2, 3)])
  check "spawn has visible cells before first gravity deadline" (all (\kind -> any ((>= 4) . snd) (shape (Pose kind R0 3 3))) allKinds)
  let empty = gameBoard (fresh Practice 1)
  check "SRS T left wall R1 -> R0 kicks right" (rotated empty False (Pose T R1 (-1) 8) == Just (Pose T R0 0 8, 1))
  check "SRS I left wall R1 -> R0 kicks two right" (rotated empty False (Pose I R1 (-2) 8) == Just (Pose I R0 0 8, 1))
  check "SRS floor kick moves upward in down-positive coordinates" (rotated empty True (Pose T R0 3 22) == Just (Pose T R1 2 21, 2))
  check "blocked move preserves state and emits nothing" (admittedStep (input [MoveLeft]) (advance (replicate 10 MoveLeft) (fresh Practice 2)) == (advance (replicate 10 MoveLeft) (fresh Practice 2) `withTick` 1, []))
  let before = fresh Practice 15
      firstHold = advance [SwapHold] before
      secondHold = advance [SwapHold] firstHold
  check "hold once per piece" (heldPiece firstHold == activeKind before && activeKind secondHold == activeKind firstHold && not (holdAvailable secondHold))
  check "hold becomes available after lock" (holdAvailable (advance [HardDrop] firstHold))
  check "failed repeated hold does not consume queued drop" (piecesLocked (advance [SwapHold, HardDrop] firstHold) == 1)
  let (four, cues) = admittedStep (input [HardDrop]) (fixture FourLine)
  check "four-line clear and perfect clear" (linesCleared four == 4 && null (cells (gameBoard four)) && any isPerfect cues)
  check "four line score base + perfect" (scoring 1 NoSpin 4 False 0 True == (2800, True))
  let fullJ = either (const empty) id (board [((x, 23), J) | x <- [0 .. 9]])
      fullI = either (const empty) id (board [((x, 23), I) | x <- [0 .. 9]])
  check "row deletion is non-injective even at equal row count" (fullJ /= fullI && collapse fullJ == collapse fullI)
  check "game checkpoint rejects an uncleared full settled row" (restore (replaceField "rawBoard = " (show fullJ) (checkpoint before)) == Left InvalidBoard)
  check "back-to-back difficult and combo" (scoring 1 NoSpin 4 True 2 False == (1300, True))
  check "empty lock keeps B2B" (scoring 1 NoSpin 0 True (-1) False == (0, True))
  check "ordinary single breaks B2B" (scoring 2 NoSpin 1 True 0 False == (200, False))
  check "T-spin scoring" (scoring 1 FullSpin 2 False 0 False == (1200, True))
  let fullBoard = either (const empty) id (board [((3, 22), J), ((5, 22), J)])
      miniBoard = either (const empty) id (board [((3, 22), J)])
  check "T-spin full front corners" (spinAt fullBoard (Pose T R0 3 22) (Just 0) == FullSpin)
  check "T-spin mini three corners" (spinAt miniBoard (Pose T R0 3 22) (Just 0) == Mini)
  check "fifth kick upgrades mini" (spinAt miniBoard (Pose T R0 3 22) (Just 4) == FullSpin)
  check "rotation required for spin" (spinAt fullBoard (Pose T R0 3 22) Nothing == NoSpin)
  check "spin fixture produces single + full spin" (any isSpin (snd (admittedStep (input [HardDrop]) (fixture SpinSingle))))
  let grounded = fromMaybeGame (replaceField "rawActive = " "Just (Pose O R0 3 22)" (checkpoint (fresh Practice 88)))
      toggles = take 100 (cycle [input [MoveLeft], input [MoveRight]])
      groundedStates = scanl (flip (\command game -> fst (admittedStep command game))) grounded toggles
  check "lock resets never exceed 15" (all ((<= 15) . lockResets) groundedStates)
  check "reset cap still locks under repeated movement" (any ((> 0) . piecesLocked) groundedStates)
  check "lock requires thirty grounded ticks" (piecesLocked (run (replicate 29 (input [])) grounded) == 0 && piecesLocked (run (replicate 30 (input [])) grounded) == 1)
  let highLevel = fromMaybeGame (replaceField "rawLines = " "140" (checkpoint (fresh Marathon 15)))
      fastSoft = fst (admittedStep (TickInput [] (Held Neutral True)) highLevel)
  check "soft drop cannot slow level-15 gravity" (active fastSoft == (active highLevel >>= shifted (gameBoard highLevel) 0 1))
  check "all-above-visible lock tops out" (phase (advance [HardDrop] (fixture TopOut)) == Lost)
  check "40 line objective" (phase (advance [HardDrop] (fixture NearSprint)) == Won)
  check "two minute objective exact boundary" (phase (advance [] (fixture NearUltra)) == Won)
  check "marathon has no short artificial finish" (phase (advance [] (fresh Marathon 9)) == Falling)
  check "practice time freezes while studying" (let studied = advance [Study] before in ticks (advance [] studied) == ticks studied && phase studied == Studying)
  check "ordinary play has no study overlay or study search projection" (all ((/= StudyCell) . cellRole) (viewCells (renderModel 0 before)) && viewStudyCount (renderModel 0 before) == 0)
  let (paused, _) = admittedStep (input [HardDrop, Pause]) before
  check "pause wins simultaneous drop and consumes no tick" (phase paused == Paused && ticks paused == ticks before && piecesLocked paused == 0)
  check "pause blocks held controls" (fst (admittedStep (TickInput [Clockwise] (Held Leftward True)) paused) == paused)
  let initialSession = start before
      (zero, _) = advanceFrame (frameMicros 5000) [Clockwise] neutral True initialSession
      (catchup, catchupCues) = advanceFrame (frameMicros 45000) [] neutral True zero
  check "zero tick frame retains press edge" (pendingEdges zero == [Clockwise] && sessionGame zero == before)
  check "catch-up edge runs once / no time dropped" (tickCount (ticks (sessionGame catchup)) == 3 && length (filter (== Turned) catchupCues) == 1 && debtUnitCount (debtUnits catchup) == 0)
  let (tapQueued, _) = advanceFrame (frameMicros 5000) [MoveLeft] (Held Leftward False) True initialSession
      (tapReleased, _) = advanceFrame (frameMicros 11667) [] neutral True tapQueued
      (heldStart, _) = advanceFrame (frameMicros 16667) [MoveLeft] (Held Leftward False) True initialSession
      (heldCatchup, heldCues) = advanceFrame (frameMicros 50000) [] (Held Leftward False) True heldStart
      moveX game = case active game of Just (Pose _ _ x _) -> x; Nothing -> -999
  check "brief horizontal tap survives zero tick press and release" (moveX (sessionGame tapReleased) == moveX before - 1)
  check "held edge shifts once without duplicate initial repeat" (moveX (sessionGame heldStart) == moveX before - 1)
  check "catch-up held before DAS adds no duplicate movement" (moveX (sessionGame heldCatchup) == moveX before - 1 && null (filter (== Moved) heldCues))
  let (beforeDas, _) = advanceFrame (frameMicros 133333) [] (Held Leftward False) True heldStart
      (releasedBeforeDas, _) = advanceFrame (frameMicros 5000) [] neutral True beforeDas
      (repressedAtDas, repressCues) = advanceFrame (frameMicros 11667) [MoveLeft] (Held Leftward False) True releasedBeforeDas
  check "zero-tick release and repress restart DAS without duplicate" (moveX (sessionGame repressedAtDas) == moveX before - 2 && length (filter (== Moved) repressCues) == 1)
  let (unfocused, _) = advanceFrame (frameMicros 9000000) [HardDrop] (Held Leftward True) False initialSession
  check "focus loss precedes queued controls and wall time" (phase (sessionGame unfocused) == Paused && ticks (sessionGame unfocused) == ticks before && null (pendingEdges unfocused))
  let (withPending, _) = advanceFrame (frameMicros 4000) [Clockwise] (Held Leftward False) True (start before)
  check "complete session checkpoint preserves pending time and immediate view" (case restoreSession (sessionCheckpoint withPending) of Right restored -> restored == withPending && renderModel 0 (sessionGame restored) == renderModel 0 before; Left _ -> False)
  let (lockedSession, _) = tickSession (input [HardDrop]) (start before)
      (twiceSession, _) = tickSession (input [HardDrop]) lockedSession
      rewound = rewindPiece twiceSession
      (branched, _) = tickSession (input [MoveLeft]) rewound
      replayed = playReplay (restartReplay branched)
  check "rewind restores prior piece spawn and truncates branch trace" (piecesLocked (sessionGame rewound) == 1 && length (traceInputs rewound) == 1 && sessionGame replayed == sessionGame branched)
  check "post-branch session restore" (restoreSession (sessionCheckpoint branched) == Right branched)
  check "forged mid-piece rewind history is rejected" (isLeft (restoreSession (forgeHistory branched)))
  check "forged event suffix is rejected" (isLeft (restoreSession (forgeCues initialSession)))
  let (refusedSession, _) = tickSession (input (replicate 33 HardDrop)) initialSession
  check "protocol rejection preserves session codec closure" (traceInputs refusedSession == [] && restoreSession (sessionCheckpoint refusedSession) == Right refusedSession)
  let (effectSession, _) = tickSession (input [HardDrop]) (start (fixture FourLine))
  check "checkpoint restores immediate clear effects" (case restoreSession (sessionCheckpoint effectSession) of Right restored -> sessionCues restored == sessionCues effectSession && renderModel 0 (sessionGame restored) == renderModel 0 (sessionGame effectSession); _ -> False)
  check "corrupt/version checkpoint rejection" (all (isLeft . restore) ["garbage", "Saved 2 undefined", replaceOnce "Saved 1" "Saved 2" (checkpoint before), replaceField "rawScore = " "(-1)" (checkpoint before), replaceField "rawResets = " "99" (checkpoint before), replaceField "rawQueue = " "[]" (checkpoint before), replaceField "rawActive = " "Just (Pose T R0 50 50)" (checkpoint before)])
  check "corrupt temporal checkpoint rejected" (isLeft (restoreSession (replaceOnce " 0 [] (Held" " (-1) [] (Held" (sessionCheckpoint initialSession))))
  let cavity = fixture Cavity
      geometricHole = Pose T R0 1 22
  check "supported geometric fit does not imply reachability" (fits (gameBoard cavity) geometricHole && shifted (gameBoard cavity) 0 1 geometricHole == Nothing && all ((/= sort (shape geometricHole)) . sort . shape . landingPose) (reachable cavity))
  check "all demonstration fixtures satisfy stable game invariants" (all ((== Right ()) . validateGame . fixture) [FourLine, SpinSingle, Cavity, NearSprint, NearUltra, TopOut])
  let studied = advance [Study] (fresh Practice 7)
      options = reachable studied
  check "frozen board finite graph enumerates landings" (not (null options) && length options < 1000)
  check "previous study selection wraps to displayed final placement" (studySelect (-1) studied == studySelect (length options - 1) studied)
  let (manyPending, _) = advanceFrame (frameMicros 0) (replicate 40 Clockwise) neutral True (start before)
      (firstBatch, firstCues) = advanceFrame (frameMicros 16667) [] neutral True manyPending
      (secondBatch, secondCues) = advanceFrame (frameMicros 16667) [] neutral True firstBatch
  check "long pending edge queues survive admission batch bound" (length (filter (== Turned) firstCues) == 32 && length (pendingEdges firstBatch) == 8 && length (filter (== Turned) secondCues) == 8 && null (pendingEdges secondBatch))
  forM_ options $ \entry -> checkWitness studied entry
  let visible = visibleObservation before
      hiddenChanged = fromMaybeGame (replaceField "rawSeed = " "987654321" (checkpoint before))
  check "observation hides RNG and unseen bag" (visibleObservation hiddenChanged == visible)
  check "policy respects equal observations" (Arena.choose greedyPolicy [Arena.Seen visible Nothing] == Arena.choose greedyPolicy [Arena.Seen (visibleObservation hiddenChanged) Nothing])
  check "Arena admission rejects oversize batch without transition" (Arena.play PureFall () (Arena.singleton Player (input (replicate 33 HardDrop))) before == Left TooManyCommands)
  check "Arena is exactly original kernel" (Arena.play PureFall () (Arena.singleton Player (input [Clockwise])) before == Right (step (input [Clockwise]) before))
  where
    isPerfect (Cleared clear) = length (clearRows clear) == 4 && clearPerfect clear
    isPerfect _ = False
    isSpin (Cleared clear) = clearSpin clear == FullSpin && length (clearRows clear) == 1
    isSpin _ = False

checkWitness :: Game -> Landing -> IO ()
checkWitness game entry = unless (witnessWorks game entry) (check "study witness failed" False)

playReplay :: Session -> Session
playReplay session = if replayAvailable session then playReplay (fst (replayNext session)) else session

data SessionWire = SavedSession Int String Integer [Command] Held [(String, Int)] [TickInput] [Cue] String [TickInput] Bool (String, Int)
  deriving (Show, Read)

forgeHistory :: Session -> String
forgeHistory session = case readMaybe (sessionCheckpoint session) of
  Just (SavedSession version saved debt pending held _ trace cues initial replay focused piece) ->
    show (SavedSession version saved debt pending held [(saved, length trace)] trace cues initial replay focused piece)
  Nothing -> "invalid"

forgeCues :: Session -> String
forgeCues session = case readMaybe (sessionCheckpoint session) of
  Just (SavedSession version saved debt pending held history trace _ initial replay focused piece) ->
    show (SavedSession version saved debt pending held history trace [Finished Won, Cleared (Clear [23, 23] NoSpin 12345 True True)] initial replay focused piece)
  Nothing -> "invalid"

withTick :: Game -> Int -> Game
withTick game count = run (replicate count (input [])) game

fromMaybeGame :: String -> Game
fromMaybeGame text = either (const (fresh Practice 999)) id (restore text)

replaceOnce :: String -> String -> String -> String
replaceOnce old new text
  | old `isPrefixOf` text = new ++ drop (length old) text
replaceOnce old new (first : rest) = first : replaceOnce old new rest
replaceOnce _ _ [] = []

replaceField :: String -> String -> String -> String
replaceField field value text = case splitField field text of
  Nothing -> text
  Just (prefix, rest) -> prefix ++ field ++ value ++ dropValue 0 rest
  where
    splitField _ [] = Nothing
    splitField needle source@(first : rest)
      | needle `isPrefixOf` source = Just ([], drop (length needle) source)
      | otherwise = fmap (\(prefix, suffix) -> (first : prefix, suffix)) (splitField needle rest)
    dropValue :: Int -> String -> String
    dropValue _ [] = []
    dropValue depth source@(first : rest)
      | first == ',' && depth == 0 = source
      | first == '}' && depth == 0 = source
      | first `elem` "([{" = dropValue (depth + 1) rest
      | first `elem` ")] }" && first /= ' ' = dropValue (depth - 1) rest
      | otherwise = dropValue depth rest

bagProperty :: Word64 -> Bool
bagProperty seed =
  let game = fresh Practice seed
      held = advance [SwapHold] game
      firstSeven = maybe [] (: []) (activeKind game) ++ preview game ++ drop 4 (preview held)
   in sort firstSeven == sort allKinds

genBoard :: Gen Board
genBoard = do
  fullRows <- sublistOf [15 .. 23]
  sparse <- sublistOf [(x, y) | y <- [4 .. 23], x <- [0 .. 9]]
  let positions = Set.toList (Set.fromList ([(x, y) | y <- fullRows, x <- [0 .. 9]] ++ sparse))
  pure (either (const (gameBoard (fresh Practice 1))) id (board [(point, J) | point <- positions]))

referenceCollapse :: Board -> Board
referenceCollapse value = either (const value) id (board [((x, y), tile) | (y, row) <- zip [0 ..] padded, (x, Just tile) <- zip [0 ..] row])
  where
    table = Map.fromList (cells value)
    rows = [[Map.lookup (x, y) table | x <- [0 .. 9]] | y <- [0 .. 23]]
    retained = filter (any (== Nothing)) rows
    padded = replicate (24 - length retained) (replicate 10 Nothing) ++ retained

collapseProperty :: Property
collapseProperty = forAll genBoard $ \value -> fst (collapse value) == referenceCollapse value

collisionProperty :: Property
collisionProperty = forAll genBoard $ \value -> forAll (elements allKinds) $ \kind ->
  forAll (elements [R0, R1, R2, R3]) $ \rotation -> forAll (chooseInt (-4, 11)) $ \x -> forAll (chooseInt (-2, 25)) $ \y ->
    let pose = Pose kind rotation x y
        occupiedPoints = map fst (cells value)
        reference = all (\(xx, yy) -> xx >= 0 && xx < 10 && yy >= 0 && yy < 24 && (xx, yy) `notElem` occupiedPoints) (shape pose)
     in fits value pose == reference

genInput :: Gen TickInput
genInput = do
  command <- elements [[], [], [], [MoveLeft], [MoveRight], [Clockwise], [Counterclockwise], [HardDrop], [SwapHold], [Pause]]
  direction <- elements [Neutral, Leftward, Rightward]
  soft <- arbitrary
  pure (TickInput command (Held direction soft))

stateProperty :: Word64 -> Property
stateProperty seed = forAll (vectorOf 300 genInput) $ \inputs -> all ((== Right ()) . validateGame) (scanl (flip (\command game -> fst (admittedStep command game))) (fresh Practice seed) inputs)

compositionProperty :: Word64 -> Property
compositionProperty seed = forAll (listOf genInput) $ \inputs -> forAll (chooseInt (0, length inputs)) $ \index ->
  let (before, after) = splitAt index inputs
      initial = fresh Marathon seed
      (middle, leftCues) = Transition.replay gameStep before initial
      (final, rightCues) = Transition.replay gameStep after middle
   in Transition.replay gameStep inputs initial == (final, leftCues ++ rightCues)

checkpointProperty :: Word64 -> Property
checkpointProperty seed = forAll (listOf genInput) $ \inputs -> forAll (listOf genInput) $ \suffix ->
  let game = run inputs (fresh Practice seed)
   in case restore (checkpoint game) of
        Left failure -> counterexample (show failure) False
        Right restored -> property (renderModel 0 game == renderModel 0 restored && Transition.replay gameStep suffix game == Transition.replay gameStep suffix restored)

witnessWorks :: Game -> Landing -> Bool
witnessWorks game entry = active (run (map (input . (: [])) (landingPath entry)) game) == Just (landingPose entry)

witnessProperty :: Word64 -> Property
witnessProperty seed = forAll genBoard $ \generated ->
  let lower = fst (collapse (either (const generated) id (board (filter ((>= 10) . snd . fst) (cells generated)))))
      wire = replaceField "rawBoard = " (show lower) (checkpoint (fresh Practice seed))
   in case restore wire of
        Left failure -> counterexample (show failure) False
        Right restored -> let game = advance [Study] restored in property (all (witnessWorks game) (reachable game))
