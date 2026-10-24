{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Frozen, deliberately small subsystem acceptance fixture.  The road is a
-- slice of the normal 512x512 world, not a different world-size ruleset.
module Colony.SupplyChainFixture
  ( SupplyChainDescriptor (..),
    SupplyChainPolicy (..),
    SupplyStage (..),
    fourColonySupplyChain,
    initialSupplyChainPolicy,
    supplyChainCommands,
    supplyChainBoundary,
    supplyChainTicks,
    observedFree,
  )
where

import Colony.Arena (ColonyView (..), StockView (..))
import Colony.Content
import Colony.Inventory
import Colony.Needs
import Colony.Power
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq (NFData)
import Control.Monad (foldM, replicateM, void)
import Data.Map.Strict qualified as M
import Data.Word (Word64)
import GHC.Generics (Generic)

data SupplyChainDescriptor = SupplyChainDescriptor
  { supplyFixtureVersion :: !String,
    supplyColonies :: ![EntityId],
    supplyPantries :: ![Owner],
    supplyColonyPorts :: ![RoadNode],
    supplyPump :: !EntityId,
    supplyFarm :: !EntityId,
    supplyKitchen :: !EntityId,
    supplyAquifer :: !EntityId,
    supplyGenerator :: !EntityId,
    supplyGrid :: !EntityId,
    supplyCarts :: ![EntityId],
    supplyRoadNodes :: ![RoadNode]
  }
  deriving (Eq, Show, Read, Generic, NFData)

data SupplyStage
  = StartPump
  | FirstWater
  | SecondWater
  | StartFarm
  | ShipCrops
  | StartKitchen
  | ShipRations
  | SupplyOrdered
  deriving (Eq, Show, Read, Enum, Bounded, Generic, NFData)

data SupplyChainPolicy = SupplyChainPolicy
  {supplyStage :: !SupplyStage, supplyNextSequence :: !Word64}
  deriving (Eq, Show, Read, Generic, NFData)

initialSupplyChainPolicy :: SupplyChainPolicy
initialSupplyChainPolicy = SupplyChainPolicy StartPump 1

supplyChainTicks :: Word64
supplyChainTicks = 16000

fourColonySupplyChain :: Content -> Either Failure (SupplyChainDescriptor, World)
fourColonySupplyChain content = do
  nodes <- mapM (\x -> roadNode x 0) [0 .. 30]
  topology <- foldM (\t (a, b) -> setRoad (BoundarySeq 0) a b 20 True t) emptyTopology (zip nodes (drop 1 nodes))
  ((descriptor, sites, people, pantries, grid, transport), inventory) <- runInventory (build nodes topology) (emptyInventory content)
  let world =
        (initialWorld content)
          { worldInventory = inventory,
            worldSites = M.fromList [(siteId s, s) | s <- sites],
            worldPowerGrids = M.singleton (gridId grid) grid,
            worldSiteGrids = M.singleton (supplyKitchen descriptor) (gridId grid),
            worldNeeds = NeedsState (M.fromList [(residentId r, r) | r <- people]) (M.fromList pantries),
            worldTransport = transport
          }
  validateWorld world
  pure (descriptor, world)
  where
    tx = TxId 1 1 (BoundarySeq 0) P0 0
    grant owner resource quantity =
      void
        ( mintLot
            tx
            InitialGrant
            Nothing
            resource
            quantity
            owner
            (SimTick 0)
            (if resource == Ration then Just (SimTick 576000) else Nothing)
            "four-colony-road-v1:explicit-bootstrap"
        )
    colony bootstrap = do
      cid <- freshId
      pid <- freshId
      let pantry = Owner Pantry pid
      addStorage pantry (Storage 400000 Nothing cid)
      if bootstrap then grant pantry Water 120000 >> grant pantry Ration 60000 else pure ()
      people <- replicateM 10 (freshId >>= \ident -> pure (newResident ident cid))
      pure (cid, pantry, people)
    site cid recipe natural = do
      ident <- freshId
      let src = Owner MachineInput ident; dst = Owner MachineOutput ident
      addStorage src (Storage 400000 Nothing cid)
      addStorage dst (Storage 400000 Nothing cid)
      pure (Site ident recipe src dst natural 4 True)
    build nodes topology = do
      groups <- mapM colony [True, True, True, False]
      case groups of
        [(c0, p0, r0), (c1, p1, r1), (c2, p2, r2), (c3, p3, r3)] -> do
          aquifer <- addDeposit "aquifer" Water 50000000
          pump <- site c0 "hand_water" (M.singleton "aquifer" aquifer)
          farm <- site c1 "grow" M.empty
          kitchen <- site c2 "cook" M.empty
          grant (siteInput kitchen) Fuel 1000
          generator <- freshId
          let fuel = Owner MachineInput generator
          addStorage fuel (Storage 40000 (Just Fuel) c2)
          grant fuel Fuel 40000
          gid <- freshId
          let grid = PowerGrid gid [] [Generator generator fuel True 100] [] M.empty
              positions = [RoadNode 0, RoadNode 10, RoadNode 20, RoadNode 30]
              ports =
                zip [p0, p1, p2, p3] positions
                  ++ [ (siteInput pump, RoadNode 0),
                       (siteOutput pump, RoadNode 0),
                       (siteInput farm, RoadNode 10),
                       (siteOutput farm, RoadNode 10),
                       (siteInput kitchen, RoadNode 20),
                       (siteOutput kitchen, RoadNode 20),
                       (fuel, RoadNode 20)
                     ]
          connected <- foldM (\t (o, n) -> addTransportPort o n t) (emptyTransport {transportTopology = topology}) ports
          (carts, transport) <-
            foldM
              ( \(ids, t) (cid, home, node) -> do
                  (ident, next) <- addTransportVehicle CarrierCart cid home home node (SimTick 0) t
                  pure (ids ++ [ident], next)
              )
              ([], connected)
              (zip3 [c0, c1, c2, c3] [p0, p1, p2, p3] positions)
          let descriptor =
                SupplyChainDescriptor
                  "four-colony-road-v1"
                  [c0, c1, c2, c3]
                  [p0, p1, p2, p3]
                  positions
                  (siteId pump)
                  (siteId farm)
                  (siteId kitchen)
                  aquifer
                  generator
                  gid
                  carts
                  nodes
          pure (descriptor, [pump, farm, kitchen], r0 ++ r1 ++ r2 ++ r3, [(c0, [p0]), (c1, [p1]), (c2, [p2]), (c3, [p3])], grid, transport)
        _ -> throwTx (InvariantViolation "four-colony fixture arity")

observedFree :: ColonyView -> Owner -> Resource -> Integer
observedFree observation owner resource = case M.lookup (owner, resource) (viewStock observation) of
  Nothing -> 0
  Just stock -> stockPhysical stock - stockReserved stock

-- No authoritative World is passed to this decision function.  The descriptor
-- is public initial setup, and the state contains only the policy's own choices.
-- It never creates inventory or edits world state after the initial fixture.
supplyChainCommands :: SupplyChainDescriptor -> ColonyView -> SupplyChainPolicy -> (SupplyChainPolicy, [OrderedCommand])
supplyChainCommands descriptor observation policy = case supplyStage policy of
  StartPump -> issue FirstWater [OrderProduction (supplyPump descriptor)]
  FirstWater
    | available pumpOut Water >= 60000 ->
        issue
          SecondWater
          [RequestDelivery pumpOut farmIn Water 60000 1, OrderProduction (supplyPump descriptor)]
  SecondWater
    | available pumpOut Water >= 60000 ->
        issue
          StartFarm
          [RequestDelivery pumpOut kitchenIn Water 10000 1, RequestDelivery pumpOut pantry Water 50000 1]
  StartFarm | available farmIn Water >= 60000 -> issue ShipCrops [OrderProduction (supplyFarm descriptor)]
  ShipCrops | available farmOut Crops >= 60000 -> issue StartKitchen [RequestDelivery farmOut kitchenIn Crops 20000 1]
  StartKitchen | available kitchenIn Water >= 10000 && available kitchenIn Crops >= 20000 -> issue ShipRations [OrderProduction (supplyKitchen descriptor)]
  ShipRations | available kitchenOut Ration >= 18000 -> issue SupplyOrdered [RequestDelivery kitchenOut pantry Ration 18000 1]
  _ -> (policy, [])
  where
    pumpOut = Owner MachineOutput (supplyPump descriptor)
    farmIn = Owner MachineInput (supplyFarm descriptor)
    farmOut = Owner MachineOutput (supplyFarm descriptor)
    kitchenIn = Owner MachineInput (supplyKitchen descriptor)
    kitchenOut = Owner MachineOutput (supplyKitchen descriptor)
    pantry = last (supplyPantries descriptor)
    available = observedFree observation
    issue stage commands =
      ( SupplyChainPolicy stage (supplyNextSequence policy + fromIntegral (length commands)),
        [ OrderedCommand ordinal (CommandId 1 1 (Epoch "development-authority-1" 1) (supplyNextSequence policy + ordinal)) command
        | (ordinal, command) <- zip [0 ..] commands
        ]
      )

supplyChainBoundary :: World -> [OrderedCommand] -> NativeInput
supplyChainBoundary world commands =
  Boundary
    (BoundaryHeader (worldId world) (branchId world) (boundarySeq world) True (worldAuthority world) (worldRuleset world))
    commands
    []
