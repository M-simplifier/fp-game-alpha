{-# LANGUAGE BangPatterns #-}
module SpaceTests (main,spaceTests) where

import Colony.Content
import qualified Colony.Inventory as I
import Colony.Space
import Colony.Types
import Colony.Units
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_,replicateM,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (sortOn)
import Text.Read (readMaybe)

assert :: String -> Bool -> IO ()
assert label condition = unless condition(ioError(userError("Space assertion: "++label)))
must :: Show e => String -> Either e a -> IO a
must label = either(ioError . userError . ((label++": ")++) . show)pure
left :: Either a b -> Bool
left (Left _)=True
left _=False

data Fixture = Fixture !EntityId !EntityId !Owner !EntityId !EntityId !EntityId ![EntityId] !Inventory !SpatialState
fixture :: Content -> IO Fixture
fixture content = do
  ((colony,foreignColony,owner,waterA,waterB,ore,idents),inventory)<-must "inventory fixture" $ I.runInventory (do
    colony<-I.freshId
    foreignColony<-I.freshId
    warehouse<-I.freshId
    let owner=Owner Warehouse warehouse
    I.addStorage owner(Storage 9000000 Nothing colony)
    _<-I.mintLot (TxId 61 1(BoundarySeq 1)P0 0) InitialGrant Nothing Stone 5000000 owner(SimTick 0)Nothing "space fixture"
    waterA<-I.addDeposit "aquifer" Water 1000000
    waterB<-I.addDeposit "aquifer" Water 1000000
    ore<-I.addDeposit "ore_deposit" Ore 1000000
    idents<-replicateM 20 I.freshId
    pure(colony,foreignColony,owner,waterA,waterB,ore,idents)) (I.emptyInventory content)
  let spec=MapSpec "space-test-d0-explicit-bounds" 1(Rect(Tile 0 0)128 128)(Tile 192 224)M.empty
      state=(emptySpatial spec) {spatialSources=M.fromList
        [(waterA,SourceRegion waterA "aquifer" Water(Rect(Tile 20 20)8 8))
        ,(waterB,SourceRegion waterB "aquifer" Water(Rect(Tile 20 30)8 8))
        ,(ore,SourceRegion ore "ore_deposit" Ore(Rect(Tile 40 20)8 8))]}
  _<-must "fixture spatial validity" (validateSpatial content inventory state)
  pure(Fixture colony foreignColony owner waterA waterB ore idents inventory state)

-- Independent finite oracle: rectangles are enumerated directly after swapping
-- width/height, and ports use four explicit formulas, never production rotation.
oracleGeometry :: Integer -> Integer -> Tile -> Rotation -> (S.Set Tile,PortGeometry)
oracleGeometry w h (Tile x y) rotation =
  let (rw,rh)=case rotation of R0->(w,h);R180->(w,h);_->(h,w)
      p=(w-1) `div` 2
      (boundary,outside)=case rotation of
        R0 -> (Tile(x+p)(y+h-1),Tile(x+p)(y+h))
        R90 -> (Tile x(y+p),Tile(x-1)(y+p))
        R180 -> (Tile(x+w-1-p)y,Tile(x+w-1-p)(y-1))
        R270 -> (Tile(x+h-1)(y+w-1-p),Tile(x+h)(y+w-1-p))
  in(S.fromList[Tile a b|a<-[x..x+rw-1],b<-[y..y+rh-1]],PortGeometry boundary outside)
geometryTests :: Content -> Fixture -> IO ()
geometryTests content(Fixture colony _ _ _ _ _ (ident:other:_) inventory state)=do
  let orderedTiles=[Tile x y|y<-[0..5],x<-[0..5]]
  assert "Tile Ord is canonical row-major"(S.toList(S.fromList(reverse orderedTiles))==orderedTiles)
  forM_ [Tile x y|x<-[-1,0,1,512],y<-[-1,0,1,512]] $ \a->
    forM_ [Tile x y|x<-[-1,0,1,512],y<-[-1,0,1,512]] $ \b->
      assert "Tile Ord remains Eq-consistent outside bounds"((compare a b==EQ)==(a==b))
  let cases=[(w,h,origin,rotation)|w<-[1..8],h<-[1..8],origin<-[Tile 0 0,Tile 1 1,Tile 126 126,Tile 509 509],rotation<-[R0,R90,R180,R270]]
  forM_ cases $ \(w,h,origin,rotation)->do
    actual<-must "finite geometry"(footprintGeometry(w,h)origin rotation)
    let (tiles,port)=actual
    assert "independent geometry/port oracle"(actual==oracleGeometry w h origin rotation)
    assert "outside connector not footprint"(not(S.member(roadConnector port)tiles))
    assert "connector adjacent boundary"(manhattan(boundaryPort port)(roadConnector port)==1)
    assert "rotation preserves tile count"(toInteger(S.size tiles)==w*h)
  forM_ [(0,1),(1,0),(-1,2),(513,1)] $ \size->assert "invalid footprint"(left(footprintGeometry size(Tile 0 0)R0))
  forM_ [(Tile(-1)1,R0),(Tile 128 1,R0),(Tile 512 1,R0),(Tile 126 126,R0),(Tile 0 0,R90),(Tile 0 0,R180)] $ \(origin,rotation)->
    assert "edge/world/scenario/connector rejection"(left(reserveBuildingPlan content inventory ident colony "warehouse" origin rotation Nothing state))
  let plan origin rotation s=reserveBuildingPlan content inventory ident colony "warehouse" origin rotation Nothing s
  (reserved,planned)<-must "reserve plan"(plan(Tile 60 60)R0 state)
  blocked0<-must "plan blocking"(blockingTiles content planned)
  assert "plan reserves without blocking"(S.null blocked0)
  assert "duplicate plan identity"(left(plan(Tile 70 70)R0 planned))
  assert "overlapping second plan"(left(reserveBuildingPlan content inventory other colony "warehouse"(Tile 62 62)R90 Nothing planned))
  assert "road rejects reserved footprint"(left(reserveRoadPlan content inventory other colony(Tile 60 60)planned))
  assert "building cannot reserve road"(left(plan(Tile 60 60)R0 state {spatialRoads=S.singleton(Tile 60 60)}))
  started<-must "start placement"(startPlacement content inventory ident planned)
  blocked1<-must "site blocking"(blockingTiles content started)
  assert "site blocks 16 exact tiles"(S.size blocked1==16 && spatialBlockingRevision started>spatialBlockingRevision planned)
  assert "second start fails"(left(startPlacement content inventory ident started))
  complete<-must "complete placement"(completePlacement content inventory ident started)
  _<-must "built state valid"(validateSpatial content inventory complete)
  assert "built cancel unsupported"(left(removePlacement ident complete))
  cancelled<-must "cancel site"(removePlacement ident started)
  assert "cancel releases reservation and block"(M.null(spatialPlacements cancelled))
  assert "placement source absent for warehouse"(placementSource reserved==Nothing)
  assert "cannot attach source to ordinary building"(left(plan(Tile 10 10)R0 state {spatialMap=(spatialMap state) {mapTerrain=M.singleton(Tile 10 10)Cliff}}))
  assert "bad crop fails"(left(validateMap((spatialMap state) {mapCropOrigin=Tile 450 450})))
  assert "negative crop fails"(left(validateMap((spatialMap state) {mapCropOrigin=Tile(-1)0})))
  assert "out-of-scenario terrain fails"(left(validateMap((spatialMap state) {mapTerrain=M.singleton(Tile 128 0)Rock})))
  putStrLn("SPACE geometry oracle cases="++show(length cases)++" rotations=4 connector=outside reservations=separate PASS")
geometryTests _ _=error "fixture identifiers"

sourceTests :: Content -> Fixture -> IO ()
sourceTests content(Fixture colony _ _ sourceA sourceB ore (ident:_) inventory state)=do
  (placement,planned)<-must "two-source pump placement"(reserveBuildingPlan content inventory ident colony "hand_pump"(Tile 20 28)R90 Nothing state)
  assert "stable minimum source ID"(placementSource placement==Just(min sourceA sourceB))
  (explicit,_)<-must "explicit second source"(reserveBuildingPlan content inventory ident colony "hand_pump"(Tile 20 28)R90(Just sourceB)state)
  assert "explicit source preserved"(placementSource explicit==Just sourceB)
  assert "source footprint overlap rejected"(left(reserveBuildingPlan content inventory ident colony "hand_pump"(Tile 20 20)R0(Just sourceA)state))
  assert "source needs adjacency, not radius"(left(reserveBuildingPlan content inventory ident colony "hand_pump"(Tile 10 10)R0(Just sourceA)state))
  assert "wrong source kind rejected"(left(reserveBuildingPlan content inventory ident colony "hand_pump"(Tile 38 22)R0(Just ore)state))
  let wrongResource=state {spatialSources=M.adjust(\r->r {sourceRegionResource=Brine})sourceA(spatialSources state)}
  assert "wrong kind/resource pairing rejected"(left(validateSpatial content inventory wrongResource))
  zero<-must "zero quantity"(mkQty 0)
  let depleted=inventory {invDeposits=M.adjust(\d->d {depositQty=zero})sourceA(invDeposits inventory)}
  _<-must "bound source remains valid after depletion"(validateSpatial content depleted planned)
  started<-must "same source remains bound on start"(startPlacement content depleted ident planned)
  assert "depletion never silently retargets"(placementSource((spatialPlacements started)M.!ident)==Just sourceA)
  assert "explicit depleted source refused for new plan"(left(reserveBuildingPlan content depleted ident colony "hand_pump"(Tile 20 28)R90(Just sourceA)state))
  (newPlan,_)<-must "new plan can select available source"(reserveBuildingPlan content depleted ident colony "hand_pump"(Tile 20 28)R90 Nothing state)
  assert "new unbound plan selects next eligible"(placementSource newPlan==Just sourceB)
  let overlap=state {spatialSources=M.adjust(\s->s {sourceRegionBounds=Rect(Tile 24 24)8 8})sourceB(spatialSources state)}
  assert "overlapping source region rejected"(left(validateSpatial content inventory overlap))
  let malformed=state {spatialSources=M.adjust(\s->s {sourceRegionBounds=Rect(Tile 20 20)7 8})sourceA(spatialSources state)}
  assert "non-8x8 region rejected"(left(validateSpatial content inventory malformed))
  putStrLn "SPACE sources kind+resource+8x8+adjacency stable-ID depletion-no-retarget PASS"
sourceTests _ _=error "fixture identifiers"

-- Independent candidate oracle on a 12x12 crop: exhaustive world tiles, direct
-- integer radius, explicit exclusion sets. It never calls eligibility/geometry.
cacheOracleTests :: Content -> Fixture -> IO ()
cacheOracleTests content(Fixture colony foreignColony owner _ _ _ (ident:_) inventory state)=do
  let tiny=(emptySpatial(MapSpec "finite-cache-oracle" 1(Rect(Tile 0 0)12 12)(Tile 0 0)
        (M.fromList[(Tile 3 3,Cliff),(Tile 4 3,Aquifer),(Tile 5 3,Salt),(Tile 6 3,Rock),(Tile 7 3,Pass)])))
        {spatialRoads=S.fromList[Tile 2 2,Tile 3 2],spatialPipes=S.singleton(Tile 5 5),spatialWires=S.singleton(Tile 5 5)
        ,spatialOwnerLocations=M.singleton owner(OwnerLocation(Tile 2 1)(Just(Tile 2 2)))}
      origin=Tile 5 5
      context=CacheContext origin colony(ConstructionReturn ident)
      excluded=S.fromList[Tile 3 3,Tile 4 3,Tile 5 3,Tile 2 2,Tile 3 2]
      distance(Tile x y)=abs(x-5)+abs(y-5)
      expected=sortOn(\t@(Tile x y)->(distance t,y*512+x))
        [t|x<-[0..11],y<-[0..11],let t=Tile x y,distance t<=16,not(S.member t excluded)]
      actual=cacheCandidates content tiny context
  assert "finite independent cache eligibility/order"(actual==expected)
  assert "pipe/wire coexist with cache"(head actual==origin)
  assert "rock/pass permitted"(all(`elem`actual)[Tile 6 3,Tile 7 3])
  assert "cache radius inclusive"(Tile 11 11 `elem` actual)
  assert "off-scenario negative tile rejected"(left(cacheEligible content tiny context(Tile(-1)0)))
  let sourceContext=context {cacheOrigin=Tile 20 20}
  assert "source tiles excluded"(left(cacheEligible content state sourceContext(Tile 20 20)))
  (_,planned)<-must "plan for cache exclusion"(reserveBuildingPlan content inventory ident colony "warehouse"(Tile 60 60)R0 Nothing state)
  let near=CacheContext(Tile 60 60)colony(RecipeReturn ident)
  forM_ [Tile 60 60,Tile 61 63,Tile 61 64] $ \tile->assert "plan footprint and both port tiles excluded"(left(cacheEligible content planned near tile))
  let transport=CacheContext(Tile 2 2)colony(TransportReturn(Tile 2 2))
  assert "transport arrival-road exception"(cacheCandidates content tiny transport==[Tile 2 2])
  assert "transport not arbitrary road"(left(cacheEligible content tiny transport(Tile 3 2)))
  assert "transport origin must be arrival"(left(cacheEligible content tiny transport {cacheOrigin=Tile 3 2}(Tile 2 2)))
  let aid=CacheContext(Tile 3 3)colony(EmergencyAid(Tile 3 3))
      registeredRuin=tiny {spatialDepotRuins=M.singleton(Tile 3 3)colony}
  assert "aid tag cannot authorize arbitrary tile"(null(cacheCandidates content tiny aid))
  assert "aid registry must match colony"(null(cacheCandidates content registeredRuin aid {cacheColony=foreignColony}))
  assert "aid depot-ruin cliff exception separate"(cacheCandidates content registeredRuin aid==[Tile 3 3])
  assert "ordinary reason does not gain aid exception"(left(cacheEligible content tiny context {cacheOrigin=Tile 3 3}(Tile 3 3)))
  ((cache,created),withCache)<-must "make cache"$runSpatialTransaction content tiny (\s->ensureGroundCache content context origin s)inventory
  let foreignContext=context {cacheColony=foreignColony}
  assert "foreign colony cache rejected"(case cacheEligible content created foreignContext origin of Left(ForeignCache _ who)->who==colony;_->False)
  assert "foreign colony cannot gain owner"(left(I.runInventory(ensureGroundCache content foreignContext origin created)withCache))
  assert "cache excludes no traffic edges"(spatialRoads created==spatialRoads tiny)
  assert "cache fresh owner correct kind"(case cache of Owner GroundCache _->True;_->False)
  putStrLn("SPACE cache-oracle cases="++show(12*12::Integer)++" candidates="++show(length actual)++" explicit-exceptions ownership PASS")
cacheOracleTests _ _=error "fixture identifiers"

cacheTransactionTests :: Content -> Fixture -> IO ()
cacheTransactionTests content(Fixture colony _ source _ _ _ (ident:roadId:_) inventory state)=do
  let tile=Tile 60 60
      construction=CacheContext tile colony(ConstructionReturn ident)
      recipe=construction {cacheReason=RecipeReturn ident}
      initialNext=invNextId inventory
      move quantity context spatial=do
        (owner,next)<-ensureGroundCache content context tile spatial
        I.moveFree(SimTick 0)source owner Stone quantity
        pure(owner,next)
  ((owner,first),inventory1)<-must "transfer into new cache"$runSpatialTransaction content state(move 1500000 construction)inventory
  ((same,second),inventory2)<-must "reuse across reason"$runSpatialTransaction content first(move 500000 recipe)inventory1
  assert "same tile same physical owner"(owner==same && M.size(spatialCaches second)==1)
  assert "exact two-million shared limit"(I.heldWeight inventory2 owner==cacheCapacity && I.freeWeight inventory2 owner==0)
  assert "two reason contexts share storage"(S.size(cacheContexts(spatialCaches second M.! tile))==2)
  assert "only one storage owner allocated"(invNextId inventory1==initialNext+2 && invNextId inventory2==initialNext+3)
  let before=(second,inventory2)
      failure=runSpatialTransaction content second(move 1 construction)inventory2
  assert "over-limit capacity rejection"(failure==Left NoCapacity)
  assert "failed transaction original references unchanged"(before==(second,inventory2))
  let freshTile=Tile 61 60
      failing spatial=do
        (_,mid)<-ensureGroundCache content construction freshTile spatial
        _<-I.freshId
        _<-I.throwTx NoCapacity
        pure((),mid)
  assert "fresh cache and allocator roll back"(runSpatialTransaction content second failing inventory2==Left NoCapacity && invNextId inventory2==initialNext+3 && not(M.member freshTile(spatialCaches second)))
  assert "capacity not multiplied by reason"(length[()|Owner GroundCache _<-M.keys(invStorage inventory2)]==1)
  _<-evaluate(force(second,inventory2))
  assert "strict state show/read representable"((readMaybe(show second)::Maybe SpatialState)==Just second)
  let forged=second {spatialCaches=M.adjust(\cache->cache {cacheOwner=source})tile(spatialCaches second)}
  assert "wrong cache storage kind rejected"(left(validateSpatial content inventory2 forged))
  let duplicate=second {spatialCaches=M.insert(Tile 61 60)(spatialCaches second M.! tile)(spatialCaches second)}
  assert "same owner two tiles rejected"(left(validateSpatial content inventory2 duplicate))
  assert "unmapped physical cache rejected"(left(validateSpatial content inventory2 state))
  assert "road mutation cannot invalidate cache tile"(left(reserveRoadPlan content inventory2 roadId colony tile second))
  assert "building port mutation cannot invalidate cache tile"(left(reserveBuildingPlan content inventory2 roadId colony "warehouse"(Tile 59 56)R0 Nothing second))
  assert "port registration cannot invalidate cache tile"(left(registerOwnerLocation inventory2 source(OwnerLocation(Tile 60 59)(Just tile))second))
  assert "terrain mutation cannot invalidate cache tile"(left(setTerrainTile content inventory2 tile Cliff second))
  safeTerrain<-must "safe terrain mutation"(setTerrainTile content inventory2 tile Rock second)
  assert "cache survives compatible terrain mutation"(spatialCaches safeTerrain==spatialCaches second)
  -- A completed adjacent road gives a cache a real redispatch connector without
  -- moving its lots, making another cache, or claiming any road edge occupancy.
  (_,roadPlan)<-must "adjacent road plan"(reserveRoadPlan content inventory2 roadId colony(Tile 60 61)second)
  roadSite<-must "adjacent road start"(startPlacement content inventory2 roadId roadPlan)
  connected<-must "adjacent road complete"(completePlacement content inventory2 roadId roadSite)
  _<-must "connected cache state valid"(validateSpatial content inventory2 connected)
  assert "cache gains redispatch road endpoint"(M.lookup owner(spatialOwnerLocations connected)==Just(OwnerLocation tile(Just(Tile 60 61))))
  ((transportOwner,arrivalState),arrivalInventory)<-must "arrival cache on completed road"$runSpatialTransaction content connected
    (\s->ensureGroundCache content(CacheContext(Tile 60 61)colony(TransportReturn(Tile 60 61)))(Tile 60 61)s)inventory2
  _<-must "arrival cache and built road coexist"(validateSpatial content arrivalInventory arrivalState)
  assert "arrival cache creates redispatch endpoint"(M.lookup transportOwner(spatialOwnerLocations arrivalState)==Just(OwnerLocation(Tile 60 61)(Just(Tile 60 61))))
  assert "transport cache does not steal road traffic"(spatialRoads arrivalState==spatialRoads connected && spatialBlockingRevision arrivalState==spatialBlockingRevision connected)
  assert "arrival road removal requires relocation rather than invalid cache"(left(validateSpatial content arrivalInventory arrivalState {spatialRoads=S.empty}))
  -- Actual Inventory capacity reservations share the same tile budget.
  ((reservationId,_),reservedInventory)<-must "cache capacity reservation"$I.runInventory(do
    claim<-I.freshId
    I.reserveCapacity claim transportOwner Stone 2000000
    pure(claim,()))arrivalInventory
  assert "reserved capacity prevents return overflow"(left(I.runInventory(I.moveFree(SimTick 0)source transportOwner Stone 1)reservedInventory))
  (_,released)<-must "release cache reservation"(I.runInventory(I.releaseJob reservationId)reservedInventory)
  assert "capacity becomes available after release"(I.freeWeight released transportOwner==2000000)
  putStrLn("SPACE transactions cache-count="++show(M.size(spatialCaches arrivalState))++" physical-weight="++show(I.heldWeight arrivalInventory owner)++" allocator-delta="++show(invNextId arrivalInventory-initialNext)++" rollback+redispatch+closed-changes PASS")
cacheTransactionTests _ _=error "fixture identifiers"

spaceTests :: Content -> IO ()
spaceTests content=do
  fixed<-fixture content
  geometryTests content fixed
  sourceTests content fixed
  cacheOracleTests content fixed
  cacheTransactionTests content fixed
  putStrLn "SPACE PASS: component/oracle acceptance only; actual World/Arena/save schema integration is a separate gate"
main :: IO ()
main=loadContent "data/content-v1.json" >>= must "content" >>= spaceTests
