module TerrainEquality (Cache, newCache, worldEq, sessionEq) where

import Control.Exception (evaluate)
import Data.IORef
import Data.Map.Strict qualified as M
import Garden.Session
import Garden.Types
import Garden.View
import System.Mem.StableName

type Terrain = M.Map Cell Material

type Cache = IORef (Maybe (StableName Terrain, StableName Terrain, Terrain, Terrain))

newCache :: IO Cache
newCache = newIORef Nothing

-- StableName equality proves object identity; a miss always uses full Eq.
-- Retain only the last successfully compared pair, never a hash or revision.
-- Strong map references keep both certified objects alive; cache size is bounded.
terrainEq :: Cache -> Terrain -> Terrain -> IO Bool
terrainEq cache a b = do
  sa <- evaluate a >>= makeStableName
  sb <- evaluate b >>= makeStableName
  known <- readIORef cache
  let hit = case known of
        Just (oldA, oldB, _, _) -> sa == oldA && sb == oldB
        Nothing -> False
  if hit
    then pure True
    else do
      same <- evaluate (a == b)
      if same then writeIORef cache (Just (sa, sb, a, b)) else pure ()
      pure same

worldEq :: Cache -> World -> World -> IO Bool
worldEq cache a b = do
  cells <- terrainEq cache (worldCells a) (worldCells b)
  if cells then evaluate (a {worldCells = M.empty} == b {worldCells = M.empty}) else pure False

sessionEq :: Cache -> SessionView -> SessionView -> IO Bool
sessionEq cache a b = do
  exact <- terrainEq cache (sceneCells (exactScene a)) (sceneCells (exactScene b))
  interpolated <-
    if exact
      then terrainEq cache (sceneCells (interpolatedScene a)) (sceneCells (interpolatedScene b))
      else pure False
  if interpolated then evaluate (withoutTerrain a == withoutTerrain b) else pure False
  where
    -- Keep the derived SessionView/SceneView Eq instances, including future fields.
    withoutTerrain v =
      v
        { exactScene = (exactScene v) {sceneCells = M.empty},
          interpolatedScene = (interpolatedScene v) {sceneCells = M.empty}
        }
