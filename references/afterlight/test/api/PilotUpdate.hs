module PilotUpdate (replacePilot) where

import Garden.Session
import Garden.Tour (Pilot)

replacePilot :: Pilot -> Simulation -> Simulation
replacePilot pilot state = state {simulationPilot = pilot}
