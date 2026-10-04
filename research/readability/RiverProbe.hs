{-# LANGUAGE OverloadedStrings #-}

-- Compile this unchanged consumer against both revisions; it is not a new oracle.
module Main (main) where

import Control.Monad (foldM, forM_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Game.Arena (attempt, nobody, observe, play, singleton)
import Game.Transition (replay)
import Life.Adapter
import Life.Clock qualified as Clock
import Life.Domain qualified as D
import System.IO (hSetEncoding, stdout, utf8)

emit :: (Show a) => String -> a -> IO ()
emit label value = putStrLn (label ++ "\t" ++ show value)

snapshot :: String -> D.Game -> IO ()
snapshot label game = do
  emit (label ++ "/position") (D.playerPosition game, D.playerCell game, D.playerFacing game, D.buildTarget game)
  emit (label ++ "/day") (D.dayNumber game, D.dayTicks game, D.weather game, D.neighborCell game)
  emit (label ++ "/garden") (D.crops game, D.firewood game, D.roofs game, D.paths game, D.seats game)
  emit (label ++ "/progress") (D.selectedBuild game, D.turnipCount game, D.dryWoodCount game, D.dinnerStatus game)
  emit (label ++ "/text") (D.interactionLabel game, D.clockLabel game, D.forecastLabel game, D.journal game, D.lastNightReport game, D.taskProgress game)
  emit
    (label ++ "/queries")
    [ ( c,
        D.cropStageAt c game,
        D.woodDrynessAt c game,
        D.isRoofed c game,
        D.isSheltered game c,
        D.walkableCell c game,
        [D.canBuildAt kind c game | kind <- [minBound .. maxBound]]
      )
    | c <- queryCells
    ]
  emit (label ++ "/view") (observe RiverArena Villager game)
  TextIO.putStrLn (Text.pack label <> "/save\t" <> D.encodeGame game)
  emit (label ++ "/invariants") (D.invariantErrors game)

queryCells :: [D.Cell]
queryCells = D.cropCells ++ D.woodCells ++ [D.homeCell, D.cookingCell, D.mailboxCell, D.Cell 6 6, D.Cell 16 15, D.Cell 17 15, D.Cell (-1) 0, D.Cell maxBound minBound]

commands :: [D.Command]
commands =
  [D.Tick x z | x <- [-1 .. 1], z <- [-1 .. 1]]
    ++ [D.Tick maxBound minBound, D.Tick minBound maxBound, D.Interact]
    ++ [D.ChooseBuild kind | kind <- [minBound .. maxBound]]
    ++ concat [[D.BuildAt c, D.RemoveAt c] | c <- queryCells]

transition :: String -> D.Command -> D.Game -> IO ()
transition label command game = do
  let (next, effects) = D.advance command game
      (boundary, actions) = splitCommand command
  emit (label ++ "/effects") effects
  emit (label ++ "/arena") (play RiverArena boundary actions game)
  snapshot label next

restoration :: String -> Text -> IO ()
restoration label input = case D.decodeGame input of
  Left problem -> emit (label ++ "/rejected") problem
  Right restored -> do
    snapshot (label ++ "/restored") restored
    let continuation = [D.Tick 0 0, D.Interact, D.ChooseBuild D.Seat, D.BuildAt (D.Cell 6 6), D.RemoveAt (D.Cell 6 6)]
        (next, effects) = replay riverStep continuation restored
        atHome = D.walkToCell D.homeCell restored
    emit (label ++ "/continuation-effects") effects
    snapshot (label ++ "/continued") next
    transition (label ++ "/continued-sleep") D.Interact atHome

-- These are transport inputs, accepted only through the real decoder. The
-- varied plot/rack fields distinguish restoration mistakes between identities.
nightInputs :: [Text]
nightInputs =
  [ foldr
      (uncurry Text.replace)
      (D.encodeGame D.initialGame)
      [ ("rDay = 1", "rDay = " <> tshow day),
        ("rTicks = 0", "rTicks = " <> tshow ticks),
        ("rBeds = [(8,5,0,False),(9,5,0,False),(10,5,0,False)]", "rBeds = " <> tshow beds),
        ("rWood = [(7,9,0,False),(8,9,0,False)]", "rWood = " <> tshow [(7 :: Int, 9 :: Int, progress, loaded), (8, 9, 900, True)]),
        ("rRoofs = []", "rRoofs = " <> tshow covering),
        ("rTurnips = 0", "rTurnips = 1"),
        ("rDryWood = 0", "rDryWood = 9999"),
        ("rDinner = 0", "rDinner = 1"),
        ("rNight = Nothing", previousNight day)
      ]
  | day <- [1, 2, 999999, 1000000 :: Int],
    ticks <- [0, D.dayLengthTicks],
    (s, w) <- [(0, False), (1, False), (1, True), (2, False), (2, True), (3, False), (3, True)],
    let beds = [(8 :: Int, 5 :: Int, s :: Int, w), (9, 5, 1, True), (10, 5, 2, False)],
    (progress, loaded) <- [(0 :: Int, False), (0, True), (6300, True), (7200, True)],
    covering <- ([[], [(8, 5)], [(7, 9)], [(8, 5), (7, 9)]] :: [[(Int, Int)]])
  ]
  where
    previousNight 1 = "rNight = Nothing"
    previousNight day = "rNight = Just (RawNight " <> tshow (day - 1) <> " 0 0 [])"

saveInputs :: [Text]
saveInputs =
  [ "nonsense",
    Text.replicate 65536 "x",
    Text.replicate 65537 "x"
  ]
    ++ [ Text.replace old new encoded
       | (old, new) <-
           [ ("rVersion = 1", "rVersion = 9"),
             ("rX = 450", "rX = -1"),
             ("rX = 450", "rX = 18446744073709551617"),
             ("rX = 450", "rX = 350"),
             ("rZ = 650", "rZ = 250"),
             ("rFX = 0", "rFX = 2"),
             ("rFZ = 1", "rFZ = 0"),
             ("rDay = 1", "rDay = 0"),
             ("rDay = 1", "rDay = 1000001"),
             ("rTicks = 0", "rTicks = 10801"),
             ("rBeds = [(8,5,0,False)", "rBeds = [(8,5,0,True)"),
             ("rBeds = [(8,5,0,False)", "rBeds = [(8,5,4,False)"),
             ("rBeds = [(8,5,0,False)", "rBeds = [(9,5,0,False)"),
             ("rWood = [(7,9,0,False)", "rWood = [(7,9,7201,True)"),
             ("rWood = [(7,9,0,False)", "rWood = [(7,9,1,False)"),
             ("rRoofs = []", "rRoofs = [(7,9),(7,9)]"),
             ("rRoofs = []", "rRoofs = [(4,5)]"),
             ("rPaths = []", "rPaths = [(6,6)]"),
             ("rSeats = []", "rSeats = [(4,6)]"),
             ("rBuild = 0", "rBuild = 4"),
             ("rTurnips = 0", "rTurnips = 10000"),
             ("rDryWood = 0", "rDryWood = -1"),
             ("rDinner = 0", "rDinner = 4"),
             ("rNight = Nothing", "rNight = Just (RawNight 2 0 0 [])")
           ]
       ]
    ++ [ Text.replace "rVersion = 1" "rVersion = 9" (Text.replace "rDay = 1" "rDay = 0" encoded),
         Text.replace "rX = 450" "rX = -1" (Text.replace "rDinner = 0" "rDinner = 4" encoded),
         Text.replace "rPaths = []" "rPaths = [(6,6)]" (Text.replace "rSeats = []" "rSeats = [(6,6)]" encoded)
       ]
  where
    encoded = D.encodeGame D.initialGame

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

main :: IO ()
main = do
  hSetEncoding stdout utf8
  let scenes = D.initialGame : map D.scenarioGame [D.DayOne, D.DayTwo, D.DayThree, D.AfterDinner]
  forM_ (zip [0 :: Int ..] scenes) $ \(index, game) -> do
    let label = "scene/" ++ show index
    snapshot label game
    forM_ (zip [0 :: Int ..] commands) $ \(number, command) -> transition (label ++ "/command/" ++ show number) command game
    forM_ [D.NoBuild, D.Roof, D.Path, D.Seat] $ \kind -> do
      let nearSite = D.walkToCell (D.Cell 6 6) game
          selected = fst (D.advance (D.ChooseBuild kind) nearSite)
          construction = [D.BuildAt (D.Cell 6 6), D.BuildAt (D.Cell 6 6), D.RemoveAt (D.Cell 6 6), D.RemoveAt (D.Cell 6 6)]
          (after, effects) = replay riverStep construction selected
      emit (label ++ "/construction/" ++ show kind ++ "/effects") effects
      snapshot (label ++ "/construction/" ++ show kind) after
    restoration (label ++ "/save") (D.encodeGame game)
    emit (label ++ "/wrong-boundary") (attempt RiverArena InteractionBoundary (singleton Villager (D.Tick 0 0)) game)
    emit (label ++ "/wrong-participants") (attempt RiverArena MovementTick (singleton Villager D.Interact) game)
    emit (label ++ "/empty-tick") (play RiverArena MovementTick nobody game)
  forM_ (zip [0 :: Int ..] nightInputs) $ \(index, input) -> do
    let label = "night/" ++ show index
    case D.decodeGame input of
      Left problem -> fail (label ++ ": expected an accepted transport fixture, got " ++ show problem)
      Right game -> do
        snapshot (label ++ "/before") game
        restoration label input
  forM_ (zip [0 :: Int ..] saveInputs) $ \(index, input) -> restoration ("decode/" ++ show index) input
  let frames = [-1, 0, 33332, 1, 33333, 12 * 33333, 0, 0, 1000000, 0, 0]
      clockStep (clock, game) (index, elapsed) = do
        let (count, nextClock) = Clock.schedule elapsed clock
            next = D.waitTicks count game
        emit ("clock/" ++ show index) (count, Clock.debtMicros nextClock, Clock.debtMicros (Clock.clearClock nextClock))
        snapshot ("clock/" ++ show index) next
        pure (nextClock, next)
  _ <- foldM clockStep (Clock.initialClock, D.initialGame) (zip [0 :: Int ..] frames)
  emit "coverage" (length scenes, length commands, length nightInputs, length saveInputs, length frames)
