{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- Schema4-only state. References existing authoritative stock/resident/device
-- entities; no duplicate physical assets, portable IO handles or duty closures.
module Colony.M1State where

import Colony.Construction
import Colony.Content
import Colony.M1Rules
import Colony.Needs
import Colony.Pickup (Pickups)
import Colony.Space qualified as Space
import Colony.Types
import Colony.Units (quantityMax)
import Colony.Workforce qualified as Workforce
import Control.DeepSeq (NFData)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)

data BedAssignment = BedAssignment {bedBuilding :: !EntityId, bedSlot :: !Integer}
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data M1State = M1State
  { m1Space :: !Space.SpatialState,
    m1Workforce :: !Workforce.WorkforceState,
    m1Construction :: !ConstructionState,
    m1ColonyDepots :: !(M.Map EntityId EntityId),
    m1Beds :: !(M.Map EntityId BedAssignment),
    m1Credit :: !Integer,
    m1Scenario :: !String,
    m1RulesVersion :: !Word64,
    m1RulesHash :: !BS.ByteString,
    m1Pickups :: !Pickups
  }
  deriving (Eq, Show, Read, Generic, NFData)

validateM1State :: Content -> Inventory -> NeedsState -> SimTick -> Workforce.TargetCatalog -> M1State -> Either Failure ()
validateM1State content inventory needs tick catalog state = do
  let check b = unless b . Left . InvariantViolation
      space = m1Space state
      placements = Space.spatialPlacements space
  check (m1RulesVersion state == m1RuleVersion && m1RulesHash state == m1RuleHash) "unknown M1 numerical rules contract"
  check (m1Scenario state `elem` ["S01-short-v1", "red-dune-live-1"]) "unknown M1 scenario"
  check (m1Credit state >= 0 && m1Credit state <= quantityMax) "M1 credit bounds"
  check (all (\storage -> M.member (storageColony storage) (m1ColonyDepots state)) (M.elems (invStorage inventory))) "physical owner belongs to unknown M1 colony"
  check (all (\placement -> M.member (Space.placementColony placement) (m1ColonyDepots state)) (M.elems placements)) "placement belongs to unknown M1 colony"
  either (Left . Space.spaceFailure) Right (Space.validateSpatial content inventory space)
  validateConstruction content inventory space (m1Construction state)
  either (Left . Workforce.workforceFailure) Right (Workforce.validateWorkforce catalog needs (m1Workforce state))
  check (Workforce.workforceLastAccountedTick (m1Workforce state) == tick) "workforce duty tick differs from world"
  let beds = M.elems (m1Beds state)
  check (length beds == S.size (S.fromList beds)) "housing slot assigned twice"
  forM_ (M.toList (m1ColonyDepots state)) $ \(colony, depot) -> do
    placement <- maybe (Left (InvariantViolation "colony depot placement absent")) Right (M.lookup depot placements)
    check (Space.placementColony placement == colony && Space.placementStage placement == Space.Built) "colony depot identity/stage"
    case Space.placementShape placement of
      Space.BuildingShape "depot" _ _ -> pure ()
      _ -> Left (InvariantViolation "colony root is not a depot")
  forM_ (M.toList (needsResidents needs)) $ \(ident, resident) -> do
    check (M.member (residentColony resident) (m1ColonyDepots state)) "resident colony has no depot root"
    check (residentBed resident == M.member ident (m1Beds state)) "resident bed flag lacks physical assignment"
  forM_ (M.toList (m1Beds state)) $ \(ident, BedAssignment building slot) -> do
    resident <- maybe (Left (InvariantViolation "bed references absent resident")) Right (M.lookup ident (needsResidents needs))
    placement <- maybe (Left (InvariantViolation "bed housing placement absent")) Right (M.lookup building placements)
    check (Space.placementStage placement == Space.Built && Space.placementColony placement == residentColony resident && slot >= 0 && slot < 10) "invalid housing slot/colony"
    case Space.placementShape placement of
      Space.BuildingShape "housing" _ _ -> pure ()
      _ -> Left (InvariantViolation "bed is not in housing")
