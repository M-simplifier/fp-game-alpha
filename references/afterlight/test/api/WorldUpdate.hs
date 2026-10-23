module WorldUpdate (replaceWorld) where

import Garden.Session
import Garden.Types (World)

replaceWorld :: World -> Simulation -> Simulation
replaceWorld world state = state {simulationWorld = world}
