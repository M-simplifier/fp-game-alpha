module Main (main) where

import Control.Monad (forM_)
import Data.List (intercalate)
import Game.Arena qualified as Arena
import PureFall.Core
import PureFall.Session
import PureFall.Time
import PureFall.View
import System.Environment (getArgs)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--policy"] -> policyRun
    ["--json"] -> jsonFixtures
    _ -> fixtures

jsonFixtures :: IO ()
jsonFixtures = putStrLn ("{\"schema\":1,\"game\":\"PURE / FALL\",\"game_version\":\"1.0.0.0\",\"source_manifest\":\"docs/source-hashes.json\",\"foundation_source\":\"fp-game-alpha@da3ff4de888be9ec62407d57836b075d763a7c89\",\"coordinates\":{\"x\":\"0..9 right\",\"y\":\"0..23 down\",\"visible_y\":\"4..23\"},\"study_scope\":\"frozen board, one current piece, no gravity or lock deadlines\",\"fixtures\":[" ++ intercalate "," (map encode [FourLine, SpinSingle, Cavity, NearSprint, NearUltra, TopOut]) ++ "]}")
  where
    encode chosen =
      let game = fixture chosen
          (after, cues) = admittedStep (TickInput [HardDrop] (Held Neutral False)) game
          encodeCell ((x, y), kind) = "[" ++ show x ++ "," ++ show y ++ "," ++ quote (show kind) ++ "]"
          pose = case active game of
            Nothing -> "null"
            Just (Pose kind rotation x y) -> "{\"kind\":" ++ quote (show kind) ++ ",\"rotation\":" ++ show (fromEnum rotation) ++ ",\"x\":" ++ show x ++ ",\"y\":" ++ show y ++ "}"
          target = Pose T R0 1 22
          cavity = if chosen == Cavity then ",\"geometric_target\":{\"kind\":\"T\",\"rotation\":0,\"x\":1,\"y\":22},\"target_fits\":" ++ boolean (fits (gameBoard game) target) ++ ",\"target_supported\":" ++ boolean (shifted (gameBoard game) 0 1 target == Nothing) ++ ",\"target_reachable\":" ++ boolean (any ((== target) . landingPose) (reachable game)) else ""
       in "{\"name\":" ++ quote (show chosen) ++ ",\"board\":[" ++ intercalate "," (map encodeCell (cells (gameBoard game))) ++ "],\"active\":" ++ pose ++ ",\"operations\":[\"HardDrop\"],\"after\":{\"phase\":" ++ quote (show (phase after)) ++ ",\"score\":" ++ show (score after) ++ ",\"lines\":" ++ show (linesCleared after) ++ ",\"board\":[" ++ intercalate "," (map encodeCell (cells (gameBoard after))) ++ "]},\"cues\":[" ++ intercalate "," (map (quote . show) cues) ++ "],\"reachable_landings\":" ++ show (length (reachable game)) ++ cavity ++ "}"
    quote text = show text
    boolean value = if value then "true" else "false"

fixtures :: IO ()
fixtures = do
  putStrLn "PURE / FALL fixture version 1 | alpha da3ff4de888be9ec62407d57836b075d763a7c89"
  putStrLn "coordinates x=0..9 right; y=0..23 down; visible y=4..23; SRS quarter-turn; frozen study excludes gravity/lock deadlines"
  forM_ [FourLine, SpinSingle, Cavity, NearSprint, NearUltra, TopOut] $ \chosen -> do
    let game = fixture chosen
        (after, cues) = admittedStep (TickInput [HardDrop] (Held Neutral False)) game
    putStrLn ("FIXTURE " ++ show chosen)
    putStrLn ("BOARD " ++ show (cells (gameBoard game)))
    putStrLn ("ACTIVE " ++ show (active game))
    putStrLn ("ACTION " ++ show HardDrop)
    putStrLn ("RESULT " ++ show (phase after, score after, linesCleared after))
    putStrLn ("EFFECTS " ++ show cues)
    putStrLn ("LANDINGS " ++ show (length (reachable game)))
  let game = fst (admittedStep (TickInput [Study] (Held Neutral False)) (fixture Cavity))
  forM_ (zip [0 :: Int ..] (reachable game)) $ \(index, entry) ->
    putStrLn ("WITNESS " ++ show index ++ " " ++ show (landingPose entry) ++ " " ++ show (landingPath entry))

policyRun :: IO ()
policyRun = do
  let initial = fresh Marathon 20261026
      final = go 12000 [] (start initial)
      game = sessionGame final
  putStrLn ("headless ticks=" ++ show (tickCount (ticks game)) ++ " pieces=" ++ show (piecesLocked game) ++ " score=" ++ show (score game) ++ " phase=" ++ show (phase game))
  putStrLn ("same transition / checkpoint=" ++ show (restoreSession (sessionCheckpoint final) == Right final))
  putStrLn (viewObjective (renderModel 0 game))
  where
    go :: Int -> [Arena.Seen Observation TickInput] -> Session -> Session
    go remaining history session
      | remaining <= 0 || phase (sessionGame session) `elem` [Won, Lost] = session
      | otherwise =
          let observed = visibleObservation (sessionGame session)
              previous = case history of [] -> Nothing; first : _ -> Arena.previousOwnChoice first
              input = Arena.choose greedyPolicy [Arena.Seen observed previous]
              (next, _) = tickSession input session
           in go (remaining - 1) [Arena.Seen observed (Just input)] next
