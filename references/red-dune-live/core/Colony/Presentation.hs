-- | Public operational projection. No RNG, future weather, private pending input,
-- whole-state hash, checkpoint path, or mutable shell state crosses this boundary.
module Colony.Presentation where

import Colony.Arena (Colony (..), ColonyView (..))
import Colony.Construction qualified as C
import Colony.Content
import Colony.Inventory (freeWeight, heldWeight, reservedWeight, runInventory, usable)
import Colony.JSON
import Colony.Jobs
import Colony.M1Commands
import Colony.M1View
import Colony.Maintenance
import Colony.Needs
import Colony.Pickup
import Colony.Space qualified as Space
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Data.Char (ord)
import Data.List (intercalate)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Game.Arena (observe)
import Numeric (showHex)

obj :: [(String, JSON)] -> JSON
obj = JObject . M.fromList

str :: String -> JSON
str = JString

num :: (Show a) => a -> JSON
num = str . show

arr :: [JSON] -> JSON
arr = JArray

ident :: EntityId -> JSON
ident (EntityId n) = num n

tickJSON :: SimTick -> JSON
tickJSON (SimTick n) = num n

boundaryJSON :: BoundarySeq -> JSON
boundaryJSON (BoundarySeq n) = num n

maybeJ :: (a -> JSON) -> Maybe a -> JSON
maybeJ f = maybe JNull f

ownerKey :: Owner -> String
ownerKey (Owner kind (EntityId n)) = show kind ++ ":" ++ show n

ownerJSON :: Owner -> JSON
ownerJSON = str . ownerKey

encodeJSON :: JSON -> String
encodeJSON value = case value of
  JObject m -> "{" ++ intercalate "," [encodeJSON (str k) ++ ":" ++ encodeJSON v | (k, v) <- M.toAscList m] ++ "}"
  JArray xs -> "[" ++ intercalate "," (map encodeJSON xs) ++ "]"
  JString s -> '"' : concatMap escape s ++ "\""
  JInteger n -> show n
  JBool b -> if b then "true" else "false"
  JNull -> "null"
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c
      | ord c < 32 = let h = showHex (ord c) "" in "\\u" ++ replicate (4 - length h) '0' ++ h
      | otherwise = [c]

physical :: World -> Owner -> Resource -> Integer
physical w owner resource = sum [qtyValue (lotQty l) | l <- M.elems (invLots (worldInventory w)), lotOwner l == owner, lotResource l == resource]

reserved :: World -> Owner -> Resource -> Integer
reserved w owner resource = sum [qtyValue (quantityAmount q) | q <- M.elems (invQuantity inv), Just l <- [M.lookup (quantityLot q) (invLots inv)], lotOwner l == owner, lotResource l == resource]
  where
    inv = worldInventory w

available :: World -> Owner -> Resource -> Integer
available w owner resource = sum [qtyValue (lotQty l) | l <- M.elems (invLots (worldInventory w)), lotOwner l == owner, lotResource l == resource, usable (simTick w) l] - reserved w owner resource

incoming :: World -> Owner -> Resource -> Integer
incoming w owner resource = sum [shipmentQuantity s | s <- M.elems (transportShipments (worldTransport w)), shipmentDestination s == Just owner, shipmentResource s == resource, shipmentStatus s == ShipmentCarrying]

resourceJSON :: World -> Resource -> JSON
resourceJSON w r = obj [("id", str (resourceKey r)), ("label", str (maybe (show r) resourceLabel (M.lookup r (contentResources (worldContent w))))), ("unit", str (maybe "unit" resourceUnit (M.lookup r (contentResources (worldContent w)))))]

stockJSON :: World -> Owner -> Resource -> JSON
stockJSON w owner r = obj [("resource", str (resourceKey r)), ("physical", num (physical w owner r)), ("reserved", num (reserved w owner r)), ("available", num (available w owner r)), ("inTransit", num (incoming w owner r))]

ownerLabel :: World -> Owner -> String
ownerLabel w owner@(Owner kind identValue) = case M.lookup identValue (worldSites w) of
  Just site -> siteLabel w site ++ case kind of MachineInput -> " 入力庫"; MachineOutput -> " 出力庫"; _ -> ""
  Nothing -> case kind of Warehouse -> "部品庫 #" ++ idText identValue; Pantry -> "配給所 #" ++ idText identValue; Vehicle -> "荷台 #" ++ idText identValue; _ -> ownerKey owner

idText :: EntityId -> String
idText (EntityId n) = show n

siteLabel :: World -> Site -> String
siteLabel w site = either (const (siteRecipe site)) recipeLabel (lookupRecipe (worldContent w) (siteRecipe site))

-- Running batches keep their immutable accepted recipe, including after migration.
siteRecipeView :: World -> Site -> Either String (Recipe, Owner, String)
siteRecipeView w site = case [j | j <- M.elems (worldJobs w), M.lookup (jobId j) (worldJobSites w) == Just (siteId site), not (terminal j)] of
  j : _ | Just snapshot <- jobRecipeSnapshot j -> Right (snapshot, wipOwner j, "RunningSnapshot")
  _ -> (\r -> (r, siteInput site, "CurrentCatalogNextOrder")) <$> lookupRecipe (worldContent w) (siteRecipe site)

nodeJSON :: RoadNode -> JSON
nodeJSON node@(RoadNode n) = let (x, y) = nodeXY node in obj [("id", num n), ("x", num x), ("y", num y)]

-- Typed cause graph expands only actual endpoint/reservation/shipment/producer
-- references. Inputs are requirements, not a second economic simulation.
causeJSON :: World -> Owner -> Resource -> Integer -> JSON
causeJSON w owner resource required = go 0 S.empty owner resource required
  where
    go :: Integer -> S.Set (Owner, Resource) -> Owner -> Resource -> Integer -> JSON
    go depth seen target r needed
      | S.member (target, r) seen = obj [("type", str "CycleReference"), ("owner", ownerJSON target), ("resource", str (resourceKey r))]
      | depth >= 8 = obj [("type", str "DepthLimit"), ("owner", ownerJSON target)]
      | otherwise =
          obj
            [ ("type", str "Need"),
              ("certainty", str "Confirmed"),
              ("updatedTick", tickJSON (simTick w)),
              ("owner", ownerJSON target),
              ("resource", str (resourceKey r)),
              ("required", num needed),
              ("stock", stockJSON w target r),
              ("nearestCause", str (nearest target r needed)),
              ("reservations", arr [obj [("id", ident (quantityReservationId q)), ("job", ident (quantityJob q)), ("amount", num (qtyValue (quantityAmount q)))] | q <- M.elems (invQuantity inv), Just l <- [M.lookup (quantityLot q) (invLots inv)], lotOwner l == target, lotResource l == r]),
              ("shipments", arr [obj [("id", ident (shipmentId s)), ("vehicle", ident (shipmentVehicle s)), ("status", num (shipmentStatus s)), ("quantity", num (shipmentQuantity s))] | s <- M.elems (transportShipments transport), shipmentDestination s == Just target, shipmentResource s == r, not (shipmentTerminal s)]),
              ("requests", arr [obj [("id", ident (requestId q)), ("status", num (requestStatus q)), ("block", maybeJ num (requestBlock q)), ("source", ownerJSON (requestSource q))] | q <- M.elems (transportRequests transport), requestDestination q == target, requestResource q == r, requestStatus q == RequestOpen]),
              ("producers", arr [obj [("type", str "Producer"), ("site", ident (siteId site)), ("label", str (siteLabel w site)), ("output", stockJSON w (siteOutput site) r), ("dependencies", arr [go (depth + 1) (S.insert (target, r) seen) dependencyOwner ir iq | (ir, iq) <- M.toList (recipeInputs recipe)])] | site <- M.elems (worldSites w), Right (recipe, dependencyOwner, _) <- [siteRecipeView w site], M.member r (recipeOutputs recipe)]),
              ("recoveryOptions", arr (map str (if available w target r >= needed then ["現在の利用可能在庫で要件を満たします"] else ["生産設備の入力・稼働状態を確認", "出力庫から対象庫へ配送を指示", "輸送車・経路・予約を確認"])))
            ]
    nearest target r needed
      | available w target r >= needed = "利用可能在庫あり"
      | incoming w target r > 0 = "現物が輸送中。到着までは利用不可"
      | reserved w target r > 0 = "他の仕事が現物を予約中"
      | any (\q -> requestDestination q == target && requestResource q == r && requestStatus q == RequestOpen) (M.elems (transportRequests transport)) = "配送要求あり。割当・経路・積込を確認"
      | otherwise = "対象庫の現物不足。生産と配送が必要"
    inv = worldInventory w
    transport = worldTransport w

-- Production cancellation also delegates to the core: its physical-lot
-- rounding and return-capacity checks must not be guessed by the renderer.
productionCancellation :: World -> Job -> [(String, JSON)]
productionCancellation w job = case candidate of
  Left failure -> [("cancelAllowed", JBool False), ("cancelFailure", num failure), ("cancelLoss", arr []), ("cancelReturn", arr [])]
  Right (_, after) ->
    let losses = [(r, M.findWithDefault 0 (r, CancelledProcessLoss) (invLedger after) - M.findWithDefault 0 (r, CancelledProcessLoss) (invLedger before)) | r <- allResources]
        entries values = arr [obj [("resource", str (resourceKey r)), ("quantity", num q)] | (r, q) <- values, q > 0]
     in [("cancelAllowed", JBool True), ("cancelFailure", JNull), ("cancelLoss", entries losses), ("cancelReturn", entries [(r, physical w (wipOwner job) r - loss) | (r, loss) <- losses])]
  where
    before = worldInventory w
    tx = TxId (worldId w) (branchId w) (boundarySeq w) P1 0
    candidate = case worldM1 w of
      Nothing -> runInventory (cancelJob (worldRuleset w) tx job) before
      Just _ -> do (changed, next) <- cancelProductionSpatial tx w job; pure (next, worldInventory changed)

-- Counterfactual cancellation cost is obtained from the exact core transaction
-- on a private immutable copy. Neither rendering nor preview commits it.
maintenanceCancellation :: World -> MaintenanceJob -> [(String, JSON)]
maintenanceCancellation w job
  | maintenanceTerminal job = [("cancelAllowed", JBool False), ("cancelFailure", num AlreadyTerminal), ("cancelLoss", JNull), ("cancelReturn", JNull), ("cancelReservationRelease", num (0 :: Integer))]
  | otherwise = case runInventory (cancelMaintenance tx (maintenanceJobId job) (worldMaintenance w)) before of
      Left failure -> [("cancelAllowed", JBool False), ("cancelFailure", num failure), ("cancelLoss", JNull), ("cancelReturn", JNull), ("cancelReservationRelease", JNull)]
      Right (_, after) ->
        let loss = M.findWithDefault 0 (Parts, CancelledProcessLoss) (invLedger after) - M.findWithDefault 0 (Parts, CancelledProcessLoss) (invLedger before)
            actual = physical w (maintenanceWipOwner job) Parts
            released = sum [qtyValue (quantityAmount q) | q <- M.elems (invQuantity before), quantityJob q == maintenanceJobId job]
         in [("cancelAllowed", JBool True), ("cancelFailure", JNull), ("cancelLoss", num loss), ("cancelReturn", num (actual - loss)), ("cancelReservationRelease", num released)]
  where
    before = worldInventory w; tx = TxId (worldId w) (branchId w) (boundarySeq w) P1 0

presentation :: World -> JSON
presentation w =
  observe Colony 1 w `seq`
    obj $
      [ ("schema", str "red-dune-public-view-0.3"),
        ("world", num (worldId w)),
        ("branch", num (branchId w)),
        ("tick", tickJSON (simTick w)),
        ("boundary", boundaryJSON (boundarySeq w)),
        ("revision", num (worldRevision w)),
        ("mode", num (worldMode w)),
        ("weather", num (worldWeather w)),
        ("controller", num (1 :: Integer)),
        ("epoch", epochJSON epoch),
        ("nextSequence", num (nextSequence)),
        ("scope", arr (map str (scopeMessages w ["4拠点・40住民・31道路nodeの操作検証fixture", ("選択kernel profile: " ++ worldRuleset w), "設備作業員・運転手・保全crewは固定fixture。住民配属UIではありません", "建設・研究・契約・天候予報・co-op・音・gamepad・WASM/端末保存・export画面・危機自動pause・全key remapは未実装", "ローカルHTTP表示 + Haskell権威kernel + Linux native保存。最終art/全platform対応ではありません"]))),
        ("resources", arr (map (resourceJSON w) allResources)),
        ("colonies", arr (map colony colonies)),
        ("sites", arr (map site (M.elems (worldSites w)))),
        ("owners", arr [storage owner st | (owner, st) <- M.toList (invStorage inv), M.member owner (transportPorts transport) || maybe False (const True) (worldM1 w)]),
        ("roads", arr [obj [("a", nodeJSON a), ("b", nodeJSON b), ("cost", num (roadCost e)), ("open", JBool (roadOpen e))] | ((a, b), e) <- M.toList (roadEdges (transportTopology transport))]),
        ("vehicles", arr (map vehicle (M.elems (transportVehicles transport)))),
        ("jobs", arr (map job (take 128 (reverse (M.elems (worldJobs w)))))),
        ("deliveries", arr (map delivery (take 128 (reverse (M.elems (transportRequests transport)))))),
        ("maintenance", arr (map maintenance (M.elems (maintenanceJobs (worldMaintenance w))))),
        ("receipts", arr (map receiptJSON (take 32 (worldReceipts w)))),
        ("events", arr (map num (take 64 (worldRecentEvents w)))),
        ("consumed", arr [obj [("resource", str (resourceKey r)), ("quantity", num (M.findWithDefault 0 (r, LivingConsumed) (invLedger inv)))] | r <- [Water, Ration]])
      ]
        ++ case observe Colony 1 w of
          ColonyViewM1 {viewM1 = public} -> [("m1", m1Projection w public)]
          _ -> []
  where
    inv = worldInventory w
    transport = worldTransport w
    epoch = maybe (Epoch "unavailable" 0) participantEpoch (M.lookup 1 (worldParticipants w))
    highest = M.findWithDefault 0 (1, epoch) (worldHighWater w)
    nextSequence = if highest == maxBound then highest else highest + 1
    colonies = M.keys (needsPantries (worldNeeds w))
    colony cid =
      let people = filter ((== cid) . residentColony) (M.elems (needsResidents (worldNeeds w))); owners = M.findWithDefault [] cid (needsPantries (worldNeeds w)); pop = toInteger (length (filter (\r -> residentStatus r `elem` [Living, Incapacitated]) people))
       in obj
            [ ("id", ident cid),
              ("label", str ("拠点 " ++ show (1 + length (takeWhile (/= cid) colonies)))),
              ("residents", num (length people)),
              ("health", num (if null people then 0 else sum (map residentHealth people) `div` toInteger (length people))),
              ("pantries", arr (map ownerJSON owners)),
              ("node", maybeJ nodeJSON (case owners of o : _ -> M.lookup o (transportPorts transport); _ -> Nothing)),
              ("needs", arr [let due = pop * daily; free = sum [available w o r | o <- owners] in obj [("resource", str (resourceKey r)), ("requiredPerDay", num due), ("requiredLabel", str "現在人口の基準日需要（直近日実績は未集計）"), ("available", num free), ("remainingHours", if due == 0 then JNull else num (free * 24 `div` due)), ("critical", JBool (due > 0 && free * 4 < due)), ("hourDue", num (sum [if r == Water then residentHourWaterDue p else residentHourFoodDue p | p <- people])), ("hourServed", num (sum [if r == Water then residentHourWaterServed p else residentHourFoodServed p | p <- people])), ("causes", arr [causeJSON w o r due | o <- owners])] | (r, daily) <- [(Water, 6000), (Ration, 3000)]])
            ]
    storage o st = obj [("id", ownerJSON o), ("label", str (ownerLabel w o)), ("colony", ident (storageColony st)), ("capacity", num (storageCapacity st)), ("heldWeight", num (heldWeight inv o)), ("reservedWeight", num (reservedWeight inv o)), ("freeWeight", num (freeWeight inv o)), ("node", maybeJ nodeJSON (M.lookup o (transportPorts transport))), ("stocks", arr [stockJSON w o r | r <- allResources])]
    site s =
      let projected = siteRecipeView w s; recipe = (\(r, _, _) -> r) <$> projected; inputOwner = either (const (siteInput s)) (\(_, owner, _) -> owner) projected; facility = M.lookup (siteId s) (maintenanceFacilities (worldMaintenance w))
       in obj
            [("id", ident (siteId s)), ("label", str (siteLabel w s)), ("recipe", str (siteRecipe s)), ("recipeBasis", str (either (const "Unavailable") (\(_, _, basis) -> basis) projected)), ("input", ownerJSON (siteInput s)), ("output", ownerJSON (siteOutput s)), ("node", maybeJ nodeJSON (M.lookup (siteOutput s) (transportPorts transport))), ("enabled", JBool (siteEnabled s)), ("workers", num (siteWorkers s)), ("powered", JBool (S.member (siteId s) (worldPoweredSites w))), ("requirements", arr [either (const JNull) (\_ -> causeJSON w inputOwner resource quantity) recipe | (resource, quantity) <- either (const []) (M.toList . recipeInputs) recipe]), ("outputs", arr [obj [("resource", str (resourceKey r)), ("quantity", num q)] | (r, q) <- either (const []) (M.toList . recipeOutputs) recipe]), ("facility", maybeJ (\f -> obj [("status", num (maintenanceStatus f)), ("age", num (facilityAge f)), ("condition", num (facilityCondition f)), ("period", num (facilityPeriod f))]) facility)]
    job j = obj $ [("id", ident (jobId j)), ("site", maybeJ ident (M.lookup (jobId j) (worldJobSites w))), ("recipe", str (jobRecipe j)), ("phase", num (jobPhase j)), ("blocked", maybeJ num (jobBlocked j)), ("progress", num (jobProgress j)), ("required", num (jobRequired j)), ("terminal", JBool (terminal j))] ++ productionCancellation w j
    delivery q = obj [("id", ident (requestId q)), ("source", ownerJSON (requestSource q)), ("destination", ownerJSON (requestDestination q)), ("resource", str (resourceKey (requestResource q))), ("quantity", num (requestQuantity q)), ("remaining", num (requestRemaining q)), ("status", num (requestStatus q)), ("blocked", maybeJ num (requestBlock q)), ("children", arr [shipment s | i <- requestChildren q, Just s <- [M.lookup i (transportShipments transport)]]), ("returns", arr [shipment s | s <- M.elems (transportShipments transport), ReturnShipment origin <- [shipmentKind s], origin `elem` requestChildren q])]
    shipment s = obj [("id", ident (shipmentId s)), ("vehicle", ident (shipmentVehicle s)), ("status", num (shipmentStatus s)), ("quantity", num (shipmentQuantity s)), ("destination", maybeJ ownerJSON (shipmentDestination s)), ("blocked", maybeJ num (shipmentBlock s))]
    vehicle v =
      obj $
        [("id", ident (vehicleId v)), ("kind", num (vehicleKind v)), ("colony", ident (vehicleColony v)), ("driver", JBool (actualDriver v)), ("job", maybeJ ident (vehicleJob v)), ("shipment", maybeJ shipment (vehicleJob v >>= (\i -> M.lookup i (transportShipments transport)))), ("block", maybeJ num (vehicleBlock v)), ("position", case vehiclePosition v of { AtRoadNode n -> obj [("type", str "node"), ("from", nodeJSON n), ("to", nodeJSON n), ("remaining", num (0 :: Integer)), ("cost", num (1 :: Integer))]; Traversing a b remaining _ -> obj [("type", str "edge"), ("from", nodeJSON a), ("to", nodeJSON b), ("remaining", num remaining), ("cost", num (maybe remaining roadCost (edgeBetween (transportTopology transport) a b)))] }), ("cargo", arr [stockJSON w (vehicleOwner v) r | r <- allResources, physical w (vehicleOwner v) r > 0])] ++ case observe Colony 1 w of
          ColonyViewM1 {viewM1 = public} -> [("pickup", maybeJ (\claim -> obj [("request", ident (pickupRequestId claim)), ("source", ownerJSON (pickupSourceOwner claim)), ("node", maybeJ nodeJSON (M.lookup (pickupSourceOwner claim) (transportPorts transport)))]) (M.lookup (vehicleId v) (publicPickups public)))]
          _ -> []
    actualDriver v = case observe Colony 1 w of
      ColonyViewM1 {viewM1 = public} ->
        let SimTick n = simTick w
         in case workTargetCatalog w >>= either (Left . W.workforceFailure) Right . (\catalog -> W.observeCrew (W.TickContext (simTick w) (toInteger (n `mod` 28800 `div` 9600))) catalog (worldNeeds w) (publicWorkforce public) (W.DriveVehicle (vehicleId v))) of
              Right crew -> W.crewReady crew
              Left _ -> False
      _ -> vehicleHasDriver v
    maintenance j = obj $ [("id", ident (maintenanceJobId j)), ("target", ident (maintenanceTarget j)), ("phase", num (maintenancePhase j)), ("blocked", maybeJ num (maintenanceBlocked j)), ("parts", num (maintenanceParts j)), ("progress", num (maintenanceProgress j)), ("required", num (maintenanceRequired j)), ("terminal", JBool (maintenanceTerminal j))] ++ maintenanceCancellation w j

epochJSON :: Epoch -> JSON
epochJSON (Epoch authority generation) = obj [("authority", str authority), ("generation", num generation)]

receiptJSON :: CommandReceipt -> JSON
receiptJSON r = let CommandId wid controller epoch sequenceNo = receiptCommand r in obj [("world", num wid), ("controller", num controller), ("epoch", epochJSON epoch), ("sequence", num sequenceNo), ("boundary", boundaryJSON (receiptBoundary r)), ("command", num (receiptBody r)), ("outcome", num (receiptOutcome r)), ("status", str (case receiptOutcome r of Applied _ -> "accepted"; CommandFailed _ -> "failed"; AlreadyProcessed -> "alreadyProcessed")), ("target", case receiptOutcome r of Applied target -> maybeJ ident target; _ -> JNull), ("tx", num (receiptTx r))]

scopeMessages :: World -> [String] -> [String]
scopeMessages world old
  | worldRuleset world == "red-dune-live-1" =
      [ "Red Dune live: forty named residents, three shifts, physical stock and transport",
        "22 buildable facility facets plus roads; production, construction and maintenance policies",
        "Authored 66-hour settlement and 42-hour recovery scenarios; objective evidence belongs to the GameState wrapper",
        "Research, contracts, immigration, generator staffing and storms are outside this campaign",
        "Transport XP is recorded; speed/capacity/fuel bonuses and commute routes remain unmodelled",
        "Scripted acceptance is not a claim about human enjoyment or novice completion rates"
      ]
  | otherwise = case worldM1 world of
      Nothing -> old
      Just _ ->
        [ "S01: 規範40住民・40床・初期資産、実D0地形と道路",
          "選択kernel profile: " ++ worldRuleset world,
          "手押し井戸と道路の新設・施工取消、実住民のshift別配属、現物配送と生活維持",
          "全28設備の新設・解体・研究・契約・移民・嵐政策・自動補充は後続gate",
          "輸送skillは蓄積のみ。速度・容量・燃料へのbonusは未実装",
          "運転交代は同colonyの実住民配属の抽象。通勤経路・乗降位置は未モデル化",
          "browser visual QA、初見利用者80%screening、66h目標と全campaignは未達"
        ]

targetJSON :: W.WorkTarget -> JSON
targetJSON target =
  let (kind, value) = case target of
        W.OperateFacility i -> ("facility", i)
        W.ConstructSite i -> ("construction", i)
        W.MaintainJob i -> ("maintenance", i)
        W.DriveVehicle i -> ("vehicle", i)
   in obj [("kind", str kind), ("id", ident value)]

tileJSON :: Space.Tile -> JSON
tileJSON (Space.Tile x y) = obj [("x", num x), ("y", num y)]

portGeometryJSON :: Space.PortGeometry -> JSON
portGeometryJSON p = obj [("boundary", tileJSON (Space.boundaryPort p)), ("connector", tileJSON (Space.roadConnector p))]

shapeFields :: World -> Space.PlacementShape -> [(String, JSON)]
shapeFields world shape = case shape of
  Space.RoadShape (Space.Tile x y) -> [("prototype", str "road"), ("x", num x), ("y", num y), ("rotation", str "R0"), ("width", num (1 :: Integer)), ("height", num (1 :: Integer))]
  Space.BuildingShape name (Space.Tile x y) rotation ->
    let (width, height) = case M.lookup name (contentBuildings (worldContent world)) of
          Nothing -> (0, 0)
          Just b -> let (a, c) = buildingFootprint b in if rotation `elem` [Space.R90, Space.R270] then (c, a) else (a, c)
     in [("prototype", str name), ("x", num x), ("y", num y), ("rotation", num rotation), ("width", num width), ("height", num height)]

resourceAmounts :: [(Resource, Integer)] -> JSON
resourceAmounts xs = arr [obj [("resource", str (resourceKey resource)), ("quantity", num quantity)] | (resource, quantity) <- xs, quantity > 0]

constructionCancellation :: World -> C.ConstructionJob -> [(String, JSON)]
constructionCancellation world job = case executeM1Command (simTick world) tx world (CancelConstructionPlan (C.constructionSiteId job) (C.constructionRevision job)) of
  Left reason -> failure reason
  Right (next, _, _) -> case validateWorld next of
    Left reason -> failure reason
    Right () ->
      let losses = [(resource, M.findWithDefault 0 (resource, ConstructionLoss) (invLedger (worldInventory next)) - M.findWithDefault 0 (resource, ConstructionLoss) (invLedger before)) | resource <- allResources]
          returns = [(resource, physical world (C.constructionInput job) resource + physical world (C.constructionEscrow job) resource - loss) | (resource, loss) <- losses]
       in [("cancelAllowed", JBool True), ("cancelFailure", JNull), ("cancelLoss", resourceAmounts losses), ("cancelReturn", resourceAmounts returns)]
  where
    before = worldInventory world
    tx = TxId (worldId world) (branchId world) (boundarySeq world) P1 0
    failure reason = [("cancelAllowed", JBool False), ("cancelFailure", num reason), ("cancelLoss", arr []), ("cancelReturn", arr [])]

m1Projection :: World -> M1PublicView -> JSON
m1Projection world public =
  obj
    [ ("version", str "1"),
      ("scenario", str (publicScenario public)),
      ("activeShift", num activeShift),
      ("credit", num (publicCredit public)),
      ( "map",
        obj
          [ ("width", num width),
            ("height", num height),
            ("placements", arr (map placement (M.elems (Space.spatialPlacements space)))),
            ("sources", arr (map source (M.elems (Space.spatialSources space)))),
            ("roads", arr (map tileJSON (S.toAscList (Space.spatialRoads space)))),
            ("caches", arr [cache tile record | (tile, record) <- M.toAscList (Space.spatialCaches space)])
          ]
      ),
      ("plans", arr (map plan (reverse (M.elems (C.constructionJobs (publicConstruction public)))))),
      ("workers", arr [worker i person adjunct | (i, person) <- M.toAscList (publicResidents public), Just adjunct <- [M.lookup i (W.workforceWorkers wf)]]),
      ("targets", arr [assignment target requirement | (target, requirement) <- M.toAscList catalog]),
      ("buildOptions", arr [buildOption name shape | (name, shape) <- [(name, Space.BuildingShape name (Space.Tile 0 0) Space.R0) | name <- if worldRuleset world == "red-dune-live-1" then C.liveBuildablePrototypes else ["hand_pump"]] ++ [("road", Space.RoadShape (Space.Tile 0 0))]])
    ]
  where
    space = publicSpace public
    wf = publicWorkforce public
    Space.Rect _ width height = Space.mapActiveBounds (Space.spatialMap space)
    SimTick tick = simTick world
    activeShift = toInteger (tick `mod` 28800 `div` 9600)
    catalog = either (const M.empty) id (workTargetCatalog world)
    context = W.TickContext (simTick world) activeShift
    placement p =
      obj
        ( shapeFields world (Space.placementShape p)
            ++ [ ("id", ident (Space.placementId p)),
                 ("stage", num (Space.placementStage p)),
                 ("source", maybeJ ident (Space.placementSource p)),
                 ("port", either (const JNull) (maybeJ portGeometryJSON . snd) (Space.placementGeometry (worldContent world) p))
               ]
        )
    source region = let Space.Rect (Space.Tile x y) w h = Space.sourceRegionBounds region in obj [("id", ident (Space.sourceRegionId region)), ("kind", str (Space.sourceRegionKind region)), ("resource", str (resourceKey (Space.sourceRegionResource region))), ("x", num x), ("y", num y), ("width", num w), ("height", num h)]
    cache tile record =
      let owner = Space.cacheOwner record; inventory = worldInventory world; Space.Tile x y = tile
       in obj
            [ ("owner", ownerJSON owner),
              ("colony", ident (Space.cacheOwnerColony record)),
              ("x", num x),
              ("y", num y),
              ("capacity", num Space.cacheCapacity),
              ("heldWeight", num (heldWeight inventory owner)),
              ("freeWeight", num (freeWeight inventory owner)),
              ("reasons", arr (map (num . Space.cacheReason) (S.toAscList (Space.cacheContexts record)))),
              ("port", maybeJ tileJSON (Space.cacheRoadPort space tile)),
              ("stocks", arr [stockJSON world owner resource | resource <- allResources, physical world owner resource > 0])
            ]
    plan job =
      obj
        ( shapeFields world (C.constructionShape job)
            ++ [ ("id", ident (C.constructionSiteId job)),
                 ("job", ident (C.constructionJobId job)),
                 ("phase", num (C.constructionPhase job)),
                 ("blocked", maybeJ num (C.constructionBlocked job)),
                 ("progress", num (C.constructionProgress job)),
                 ("required", num (C.constructionRequired (C.constructionSnapshot job))),
                 ("revision", num (C.constructionRevision job)),
                 ("input", ownerJSON (C.constructionInput job)),
                 ("escrow", ownerJSON (C.constructionEscrow job)),
                 ("source", maybeJ ident (C.constructionSource job)),
                 ("terminal", JBool (C.constructionTerminal job)),
                 ("costs", arr [obj [("resource", str (resourceKey resource)), ("quantity", num quantity), ("physical", num (physical world (C.constructionInput job) resource)), ("unreceived", num (constructionIncoming (worldTransport world) (C.constructionInput job) resource)), ("cause", causeJSON world (C.constructionInput job) resource quantity)] | (resource, quantity) <- M.toAscList (C.constructionCost (C.constructionSnapshot job))])
               ]
            ++ constructionCancellation world job
        )
    worker i person adjunct =
      obj
        [ ("id", ident i),
          ("colony", ident (residentColony person)),
          ("shift", num (residentShift person)),
          ("health", num (residentHealth person)),
          ("fatigue", num (residentFatigue person)),
          ("bed", JBool (residentBed person)),
          ("status", num (residentStatus person)),
          ("role", maybeJ num (W.workerRole adjunct)),
          ("target", maybeJ targetJSON (case [target | ((target, _), people) <- M.toAscList (W.workforceRosters wf), i `elem` people] of target : _ -> Just target; _ -> Nothing)),
          ("forcedRestUntil", maybeJ tickJSON (W.workerForcedRestUntil adjunct)),
          ("skills", arr [obj [("skill", num skill), ("level", num (W.skillLevel progress)), ("xp", num (W.skillExperience progress)), ("effect", str (if skill == W.TransportSkill then "経験蓄積のみ。速度・容量・燃料bonus未実装" else "実work credit係数。配給serviceはXPなし"))] | (skill, progress) <- M.toAscList (W.workerSkills adjunct)])
        ]
    assignment target requirement =
      obj
        [ ("target", targetJSON target),
          ("label", str (show target)),
          ("colony", ident (W.targetColony requirement)),
          ("required", num (W.targetRequiredPeople requirement)),
          ("role", num (W.targetRole requirement)),
          ("busy", JBool (W.targetRemovalBusy requirement)),
          ("rosters", arr [obj [("shift", num shift), ("residents", arr (map ident (M.findWithDefault [] (target, shift) (W.workforceRosters wf))))] | shift <- [0 .. 2 :: Integer]]),
          ( "crew",
            case W.observeCrew context catalog (worldNeeds world) wf target of
              Left reason -> obj [("available", arr []), ("selected", arr []), ("required", num (W.targetRequiredPeople requirement)), ("ready", JBool False), ("reason", num reason)]
              Right crew -> obj [("available", arr (map ident (W.crewAvailable crew))), ("selected", arr (map ident (W.crewSelected crew))), ("required", num (W.crewRequired crew)), ("ready", JBool (W.crewReady crew)), ("reason", if W.crewReady crew then JNull else str ("WaitingWorkers " ++ show (length (W.crewAvailable crew)) ++ "/" ++ show (W.crewRequired crew)))]
          )
        ]
    buildOption name shape = case C.snapshotForRuleset (worldRuleset world) (worldContent world) shape of
      Left reason -> obj [("prototype", str name), ("label", str name), ("costs", arr []), ("required", num (0 :: Integer)), ("crew", num (0 :: Integer)), ("enabled", JBool False), ("reason", num reason)]
      Right snapshot -> obj [("prototype", str name), ("label", str (maybe "道路" buildingLabel (M.lookup name (contentBuildings (worldContent world))))), ("costs", resourceAmounts (M.toAscList (C.constructionCost snapshot))), ("required", num (C.constructionRequired snapshot)), ("crew", num (C.constructionCrewRequired snapshot)), ("enabled", JBool True), ("reason", JNull)]

-- Successful private plan simulation supplies actual geometry and chosen source;
-- no renderer needs to duplicate source-distance, dimensions or cost formulas.
previewPlanJSON :: World -> Command -> ColonyOutput -> JSON
previewPlanJSON world command output = case command of
  PlaceConstructionPlan {} -> case [i | receipt <- outputReceipts output, Applied (Just i) <- [receiptOutcome receipt]] of
    [i] -> case observe Colony 1 world of
      ColonyViewM1 {viewM1 = public} -> case M.lookup i (C.constructionJobs (publicConstruction public)) of
        Just job ->
          let snapshot = C.constructionSnapshot job
              location = M.lookup i (Space.spatialPlacements (publicSpace public))
           in obj
                ( shapeFields world (C.constructionShape job)
                    ++ [ ("source", maybeJ ident (C.constructionSource job)),
                         ("port", maybe JNull (\p -> either (const JNull) (maybeJ portGeometryJSON . snd) (Space.placementGeometry (worldContent world) p)) location),
                         ("costs", resourceAmounts (M.toAscList (C.constructionCost snapshot))),
                         ("required", num (C.constructionRequired snapshot)),
                         ("crew", num (C.constructionCrewRequired snapshot))
                       ]
                )
        Nothing -> JNull
      _ -> JNull
    _ -> JNull
  _ -> JNull
