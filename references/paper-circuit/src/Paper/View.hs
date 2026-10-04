module Paper.View (render) where
import Paper.Game
import Game.Arena (observe)
import qualified Data.Set as S

render :: World -> String
render world =
  "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 480 600' role='img' aria-label='Paper Circuit puzzle'>" ++
  "<rect width='480' height='600' rx='24' fill='#f6f1e7'/>" ++
  label 32 43 13 "#687660" "A SMALL GARDEN / A WATER PUZZLE" ++
  label 32 85 32 "#23372e" "Paper Circuit" ++
  label 32 117 15 "#536459" (show (sceneMoves scene) ++ " turns left - connect both gardens") ++
  "<path d='M 8 173 H 35' stroke='#259ba6' stroke-width='8'/><path d='M 24 163 L 37 173 L 24 183 Z' fill='#259ba6'/>" ++
  label 4 157 9 "#167781" "IN" ++
  concatMap tile (sceneTiles scene) ++
  label 32 512 17 "#23372e" status ++
  label 32 541 12 "#687660" "Click a tile to rotate. Blue pipes carry water." ++
  "<g data-command='undo' role='button' tabindex='0' aria-label='Undo once per attempt'><rect x='208' y='553' width='108' height='30' rx='15' fill='" ++ (if sceneUndo scene then "#536f65" else "#bcc5b8") ++ "'/>" ++
  label 225 574 13 "#ffffff" "Undo once" ++ "</g>" ++
  "<g data-command='reset' role='button' tabindex='0' aria-label='Restart puzzle'><rect x='330' y='553' width='116' height='30' rx='15' fill='#23372e'/>" ++
  label 347 574 13 "#ffffff" "Start again" ++ "</g></svg>"
  where
    scene = observe Circuit Gardener world
    status = case scenePhase scene of
      Playing -> "Connect the inlet to both garden dots."
      Won -> "Both gardens are watered. Beautiful work."
      OutOfMoves -> "Out of turns. Try a different route."
    tile (c,p,r) =
      let n = cellNumber c; x = 40 + (n `mod` 4)*100; y = 140 + (n `div` 4)*85
          wet = c `S.member` sceneWet scene
          ink = if wet then "#259ba6" else "#a6b1a6"
          path d = let (dx,dy) = directionOffset d
                   in "<path d='M " ++ show (x+40) ++ " " ++ show (y+33) ++ " l " ++ show dx ++ " " ++ show dy ++ "' stroke='" ++ ink ++ "' stroke-width='12' fill='none' stroke-linecap='round'/>"
          garden = if c `elem` goals then "<circle cx='" ++ show (x+69) ++ "' cy='" ++ show (y+13) ++ "' r='9' fill='" ++ (if wet then "#48a36e" else "#c6c986") ++ "'/>" else ""
      in "<g data-cell='" ++ show n ++ "' role='button' tabindex='0' aria-label='Rotate tile " ++ show (n+1) ++ "'>" ++
         "<rect x='" ++ show x ++ "' y='" ++ show y ++ "' width='80' height='66' rx='13' fill='white' stroke='#e0ddd1'/>" ++
         concatMap path (ports c p r) ++ garden ++ "</g>"

label :: Int -> Int -> Int -> String -> String -> String
label x y size color value = "<text x='" ++ show x ++ "' y='" ++ show y ++ "' font-family='system-ui,sans-serif' font-size='" ++ show size ++ "' fill='" ++ color ++ "'>" ++ value ++ "</text>"

directionOffset :: Direction -> (Int,Int)
directionOffset North = (0,-42)
directionOffset East = (50,0)
directionOffset South = (0,42)
directionOffset West = (-50,0)
