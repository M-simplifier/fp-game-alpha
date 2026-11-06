module Main (main) where

import Data.List (sort)
import Data.Maybe (listToMaybe)
import PureFall.Core
import System.Exit (exitFailure)

main :: IO ()
main = do
  let boards = map makeBoard [[],[(0,21),(1,22),(2,23)],[(9,21),(8,22),(7,23)],
                             [(x,23) | x <- [0..9], x /= 4],
                             [(x,y) | x <- [2,5,8], y <- [12..23]],
                             [(x,20) | x <- [0..9]] ++ [(0,y) | y <- [21..23]]]
      poses = [Pose kind rotation x y | kind <- allKinds, rotation <- [R0,R1,R2,R3],x <- [-3..10],y <- [0..23]]
      shapeFailures = [pose | pose <- poses, sort (shape pose) /= sort (shapeRef pose)]
      probes = [(value,pose,cw) | value <- boards, pose <- poses, fitsRef value pose, cw <- [False,True]]
      rotationFailures = [(pose,cw,rotated value cw pose,rotationRef value cw pose) |
                           (value,pose,cw) <- probes, rotated value cw pose /= rotationRef value cw pose]
  putStrLn ("explicit oriented-cell probes: " ++ show (length poses) ++ "; mismatches: " ++ show (length shapeFailures))
  putStrLn ("legal-state SRS rotation probes across 6 fixed boards: " ++ show (length probes) ++ "; mismatches: " ++ show (length rotationFailures))
  print (take 3 rotationFailures)
  if null shapeFailures && null rotationFailures then pure () else exitFailure

makeBoard :: [(Int,Int)] -> Board
makeBoard positions = case board [(point,J) | point <- positions] of
  Right valid -> valid
  Left issue -> error (show issue)

fitsRef :: Board -> Pose -> Bool
fitsRef value pose = all free (shapeRef pose)
  where
    occupiedPositions = map fst (cells value)
    free point@(x,y) = x >= 0 && x < 10 && y >= 0 && y < 24 && point `notElem` occupiedPositions

shapeRef :: Pose -> [(Int,Int)]
shapeRef (Pose kind rotation x y) = [(xx+x,yy+y) | (xx,yy) <- local]
  where
    local = case (kind,rotation) of
      (I,R0) -> [(0,1),(1,1),(2,1),(3,1)]
      (I,R1) -> [(2,0),(2,1),(2,2),(2,3)]
      (I,R2) -> [(0,2),(1,2),(2,2),(3,2)]
      (I,R3) -> [(1,0),(1,1),(1,2),(1,3)]
      (O,_)  -> [(1,0),(2,0),(1,1),(2,1)]
      (T,R0) -> [(1,0),(0,1),(1,1),(2,1)]
      (T,R1) -> [(1,0),(1,1),(2,1),(1,2)]
      (T,R2) -> [(0,1),(1,1),(2,1),(1,2)]
      (T,R3) -> [(1,0),(0,1),(1,1),(1,2)]
      (S,R0) -> [(1,0),(2,0),(0,1),(1,1)]
      (S,R1) -> [(1,0),(1,1),(2,1),(2,2)]
      (S,R2) -> [(1,1),(2,1),(0,2),(1,2)]
      (S,R3) -> [(0,0),(0,1),(1,1),(1,2)]
      (Z,R0) -> [(0,0),(1,0),(1,1),(2,1)]
      (Z,R1) -> [(2,0),(1,1),(2,1),(1,2)]
      (Z,R2) -> [(0,1),(1,1),(1,2),(2,2)]
      (Z,R3) -> [(1,0),(0,1),(1,1),(0,2)]
      (J,R0) -> [(0,0),(0,1),(1,1),(2,1)]
      (J,R1) -> [(1,0),(2,0),(1,1),(1,2)]
      (J,R2) -> [(0,1),(1,1),(2,1),(2,2)]
      (J,R3) -> [(1,0),(1,1),(0,2),(1,2)]
      (L,R0) -> [(2,0),(0,1),(1,1),(2,1)]
      (L,R1) -> [(1,0),(1,1),(1,2),(2,2)]
      (L,R2) -> [(0,1),(1,1),(2,1),(0,2)]
      (L,R3) -> [(0,0),(1,0),(1,1),(1,2)]

rotationRef :: Board -> Bool -> Pose -> Maybe (Pose,Int)
rotationRef value cw pose@(Pose kind old x y)
  | kind == O = Just (pose,0)
  | otherwise = listToMaybe [(candidate,index) | (index,(dx,dy)) <- zip [0..] offsets,
                            let candidate=Pose kind new (x+dx) (y+dy),fitsRef value candidate]
  where
    new = case (old,cw) of
      (R0,True) -> R1; (R1,True) -> R2; (R2,True) -> R3; (R3,True) -> R0
      (R0,False) -> R3; (R3,False) -> R2; (R2,False) -> R1; (R1,False) -> R0
    offsets = if kind == I then iOffsets old new else normalOffsets old new

-- Independent down-positive constants. Core stores upward-positive constants
-- and flips their vertical component when applying them.
normalOffsets :: Rotation -> Rotation -> [(Int,Int)]
normalOffsets from to = case (from,to) of
  (R0,R1) -> [(0,0),(-1,0),(-1,-1),(0,2),(-1,2)]
  (R1,R0) -> [(0,0),(1,0),(1,1),(0,-2),(1,-2)]
  (R1,R2) -> [(0,0),(1,0),(1,1),(0,-2),(1,-2)]
  (R2,R1) -> [(0,0),(-1,0),(-1,-1),(0,2),(-1,2)]
  (R2,R3) -> [(0,0),(1,0),(1,-1),(0,2),(1,2)]
  (R3,R2) -> [(0,0),(-1,0),(-1,1),(0,-2),(-1,-2)]
  (R3,R0) -> [(0,0),(-1,0),(-1,1),(0,-2),(-1,-2)]
  (R0,R3) -> [(0,0),(1,0),(1,-1),(0,2),(1,2)]
  _ -> []

iOffsets :: Rotation -> Rotation -> [(Int,Int)]
iOffsets from to = case (from,to) of
  (R0,R1) -> [(0,0),(-2,0),(1,0),(-2,1),(1,-2)]
  (R1,R0) -> [(0,0),(2,0),(-1,0),(2,-1),(-1,2)]
  (R1,R2) -> [(0,0),(-1,0),(2,0),(-1,-2),(2,1)]
  (R2,R1) -> [(0,0),(1,0),(-2,0),(1,2),(-2,-1)]
  (R2,R3) -> [(0,0),(2,0),(-1,0),(2,-1),(-1,2)]
  (R3,R2) -> [(0,0),(-2,0),(1,0),(-2,1),(1,-2)]
  (R3,R0) -> [(0,0),(1,0),(-2,0),(1,2),(-2,-1)]
  (R0,R3) -> [(0,0),(-1,0),(2,0),(-1,-2),(2,1)]
  _ -> []
