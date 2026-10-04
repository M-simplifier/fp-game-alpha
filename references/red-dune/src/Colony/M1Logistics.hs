-- Schema4 empty pickup dispatch. Saved claims supplement real Transport routes;
-- movement, directional capacity, paid edges and cargo ownership stay there.
module Colony.M1Logistics where
import Colony.Inventory
import Colony.M1State
import Colony.Pickup
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import Control.Monad(foldM)
import Control.Monad.State.Strict(get)
import Data.List(sortOn,groupBy)
import qualified Data.Map.Strict as M
import Data.Word(Word64)

preparePickupFuel :: SimTick -> World -> Either Failure World
preparePickupFuel tick world=case worldM1 world of
  Nothing->Right world
  Just state->do
    ((transport,pickups),inventory)<-runInventory(foldM prepare(worldTransport world,m1Pickups state)(M.keys(m1Pickups state)))(worldInventory world)
    pure world{worldInventory=inventory,worldTransport=transport,worldM1=Just state{m1Pickups=pickups}}
  where
    prepare(current,pickups) ident=case M.lookup ident pickups of
      Nothing->pure(current,pickups)
      Just claim|pickupFuelReady claim->pure(current,pickups)
      Just claim->do
        vehicle<-lookupVehicle ident current
        request<-maybe(throwTx TargetGone)pure(M.lookup(pickupRequestId claim)(transportRequests current))
        let route=vehicleRoute vehicle
            ready=case requestPathResult request of PathFound _ _->not(null route);_->False
        if not ready then pure(current,pickups)else do
          let vehicleAnchor=case vehiclePosition vehicle of AtRoadNode node->node;Traversing _ to _ _->to
              pickupEdges=toInteger(length route)
              deliveryEdges=case requestPathResult request of PathFound path _->toInteger(length path)-1;_->0
              -- Current position is physically at its fuel/home node. Reverse
              -- delivery + reverse pickup is a legal return witness. Reserve
              -- twenty percent over ALL four legs, not just loaded travel.
              fuelEdges=2*(pickupEdges+deliveryEdges)
              requiredFuel=120*fuelEdges
          attempted<-tryInventory $ do
            home<-port(vehicleHome vehicle)current;fuelNode<-port(vehicleFuelSource vehicle)current
            require(vehiclePosition vehicle==AtRoadNode home&&home==fuelNode)(InvalidReference "Pickup fuel requires physical garage node")
            inventory<-get
            let existing=sum[qtyValue(lotQty lot)-lotReserved inventory(lotId lot)|lot<-M.elems(invLots inventory),lotOwner lot==vehicleOwner vehicle,lotResource lot==Fuel]
                additional=max 0(requiredFuel-existing)
            if additional==0 then pure()else moveFree tick(vehicleFuelSource vehicle)(vehicleOwner vehicle)Fuel additional
          case attempted of
            Right()->pure(current,M.insert ident claim{pickupFuelReady=True,pickupFuelRouteEdges=fuelEdges,pickupReturnToHomeEdges=pickupEdges,pickupReturnPath=reverse(vehicleAnchor:route)}pickups)
            Left reason|reason `elem` [MissingStock,NoCapacity]->pure(current{transportVehicles=M.adjust(\v->v{vehicleBlock=Just WaitingFuel})ident(transportVehicles current)},pickups)
            Left reason->throwTx reason

-- One P5 attempt per delivery request, whether it loads immediately or starts
-- an empty pickup. A second pass would starve pickup when256 requests already
-- consume the full attempt budget. Both branches share the same persistent
-- ageing/cursor and32-per-request/512-per-boundary match limits.
assignM1Transport :: SimTick -> Word64 -> World -> Either Failure World
assignM1Transport tick budget world=case worldM1 world of
  Nothing->Right world
  Just state->do
    catalog<-workTargetCatalog world
    let original=worldTransport world
        ordered=sortOn(\request->(effectiveRequest tick request,requestReadySince request,requestId request))
          [request|request<-M.elems(transportRequests original),requestStatus request==RequestOpen,requestRemaining request>0]
        rotate peers=case transportAssignCursor original of
          Nothing->peers
          Just cursor->case break((==cursor).requestId)peers of (_,[])->peers;(before,current:after)->after++before++[current]
        candidates=take(fromIntegral budget)(concatMap rotate(groupBy(\a b->effectiveRequest tick a==effectiveRequest tick b)ordered))
        reset=original{transportLastAssignments=0,transportLastMatches=0}
    ((transport,pickups),inventory)<-runInventory(foldM(assign catalog)(reset,m1Pickups state)candidates)(worldInventory world)
    pure world{worldInventory=inventory,worldTransport=transport,worldM1=Just state{m1Pickups=pickups}}
  where
    SimTick currentTick=tick
    context=W.TickContext tick(toInteger(currentTick `mod`28800 `div`9600))
    assign catalog(transport,pickups) request=do
      let counted=transport{transportLastAssignments=transportLastAssignments transport+1,transportAssignCursor=Just(requestId request)}
      if requestRouteRevision request/=topologyRevision(transportTopology transport)
        then pure(setRequestBlock(requestId request)Searching counted,pickups)
        else case requestPathResult request of
          PathSearching->pure(setRequestBlock(requestId request)Searching counted,pickups)
          PathUnavailable->pure(setRequestBlock(requestId request)NoRoute counted,pickups)
          PathFound route _->do
            loaded<-assignReadyWithFuelPolicy True(pickupRequestMap pickups)(returnBounds transport pickups)tick request route counted
            let changed=maybe False((<requestRemaining request).requestRemaining)(M.lookup(requestId request)(transportRequests loaded))
            if changed||requestId request `elem` M.elems(pickupRequestMap pickups)
              then pure(loaded,pickups)
              else dispatch catalog loaded pickups request(32-(transportLastMatches loaded-transportLastMatches counted))
    dispatch catalog transport pickups request requestBudget=do
      source<-port(requestSource request)transport
      inventory<-get
      storage<-maybe(throwTx MissingOwner)pure(M.lookup(requestSource request)(invStorage inventory))
      state<-maybe(throwTx(InvariantViolation "M1 dispatch absent"))pure(worldM1 world)
      let eligible vehicle=vehicleJob vehicle==Nothing&&not(M.member(vehicleId vehicle)pickups)
            &&vehicleColony vehicle==storageColony storage
            &&case vehiclePosition vehicle of
              AtRoadNode node->node/=source&&(vehicleKind vehicle==CarrierCart||Just node==M.lookup(vehicleHome vehicle)(transportPorts transport)&&Just node==M.lookup(vehicleFuelSource vehicle)(transportPorts transport))
              _->False
          candidates=filter eligible(M.elems(transportVehicles transport))
          ordered=case M.lookup(requestId request)(transportMatchCursors transport)of
            Nothing->candidates
            Just cursor->let(before,after)=span((<=cursor).vehicleId)candidates in after++before
          pool=take(fromIntegral(min requestBudget(512-transportLastMatches transport)))ordered
          hasCrew vehicle=case W.observeCrew context catalog(worldNeeds world)(m1Workforce state)(W.DriveVehicle(vehicleId vehicle))of Right crew->W.crewReady crew;_->False
          chosen=case filter hasCrew pool of vehicle:_->Just vehicle;_->Nothing
          nextCursors=case reverse pool of []->transportMatchCursors transport;lastVehicle:_->M.insert(requestId request)(vehicleId lastVehicle)(transportMatchCursors transport)
          counted=transport{transportLastMatches=transportLastMatches transport+fromIntegral(length pool),transportMatchCursors=nextCursors}
      case chosen of
        Nothing->pure(counted,pickups)
        Just vehicle->case vehiclePosition vehicle of
          AtRoadNode node->case requestPath(transportTopology counted)(vehicleId vehicle)node source(requestPriority request)tick(dropPath(vehicleId vehicle)(transportPaths counted))of
            Left PathQueueFull->pure(counted,pickups)
            Left reason->throwTx reason
            Right queue->do
              let claim=PickupClaim(requestId request)(requestSource request)tick(vehicleKind vehicle==CarrierCart)0 0 []
                  changed=vehicle{vehicleRoute=[],vehicleRouteRevision=topologyRevision(transportTopology counted),vehiclePriority=requestPriority request,vehicleWaitingSince=tick,vehicleBlock=Just Searching}
              pure(counted{transportPaths=queue,transportVehicles=M.insert(vehicleId vehicle)changed(transportVehicles counted),transportMatchCursors=M.delete(requestId request)(transportMatchCursors counted)},M.insert(vehicleId vehicle)claim pickups)
          _->throwTx(InvariantViolation "pickup candidate stopped being at node")

-- At a remote source an idle truck may take another job only after a legal
-- source→home route is known, and only with fuel for the new delivery AND home.
-- This prevents a chain of short remote jobs consuming the mandatory return fuel.
returnBounds :: TransportState -> Pickups -> M.Map EntityId Integer
returnBounds transport pickups=M.fromList
  [(vehicleId vehicle,bound)|vehicle<-M.elems(transportVehicles transport),Just bound<-[witness vehicle]]
  where
    witness vehicle=do
      home<-M.lookup(vehicleHome vehicle)(transportPorts transport)
      case vehiclePosition vehicle of
        AtRoadNode node|node==home->Just 0
        AtRoadNode node->case M.lookup(vehicleId vehicle)pickups of
          Just claim|pickupFuelReady claim&&M.lookup(pickupSourceOwner claim)(transportPorts transport)==Just node->Just(pickupReturnToHomeEdges claim)
          _->let route=vehicleRoute vehicle
                 edges=zip(node:route)route
             in if vehicleRouteRevision vehicle==topologyRevision(transportTopology transport)&&not(null route)&&last route==home&&all(\(a,b)->openEdge(transportTopology transport)a b/=Nothing)edges
                  then Just(toInteger(length route))else Nothing
        _->Nothing
