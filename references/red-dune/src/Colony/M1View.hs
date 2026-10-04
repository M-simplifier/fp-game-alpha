{-# LANGUAGE DeriveAnyClass,DeriveGeneric #-}
-- Public schema4 allowlist. No RNG, future weather, pending command, authority
-- handles, checkpoint hashes or private save/library paths are projected.
module Colony.M1View where
import Colony.Construction
import Colony.M1State
import Colony.Needs
import Colony.Pickup(Pickups)
import Colony.Space
import Colony.Types
import Colony.Workforce
import Control.DeepSeq(NFData)
import qualified Data.Map.Strict as M
import GHC.Generics(Generic)
data M1PublicView=M1PublicView
  {publicSpace :: !SpatialState,publicWorkforce :: !WorkforceState,publicConstruction :: !ConstructionState
  ,publicResidents :: !(M.Map EntityId Resident),publicBeds :: !(M.Map EntityId BedAssignment)
  ,publicColonyDepots :: !(M.Map EntityId EntityId),publicCredit :: !Integer,publicScenario :: !String,publicPickups :: !Pickups}
  deriving(Eq,Show,Read,Generic,NFData)
observeM1 :: NeedsState -> M1State -> M1PublicView
observeM1 needs state=M1PublicView(m1Space state)(m1Workforce state)(m1Construction state)(needsResidents needs)
  (m1Beds state)(m1ColonyDepots state)(m1Credit state)(m1Scenario state)(m1Pickups state)
