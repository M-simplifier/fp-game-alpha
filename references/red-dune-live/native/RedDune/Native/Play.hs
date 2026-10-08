-- Player decisions compile to the same ordinary kernel commands as the live
-- host. UI automation configures plans; it never creates stock or work credit.
module RedDune.Native.Play where

import Colony.Construction qualified as C
import Colony.Content
import Colony.Inventory (freeWeight)
import Colony.Jobs
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.Presentation (obj, str)
import Colony.S01Fixture
import Colony.Space qualified as Space
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Monad (unless)
import Data.List (find, intercalate, nub)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import RedDune.Campaign
import RedDune.ContentPack (ContentPack)
import RedDune.Game
import RedDune.Policies
import Text.Printf (printf)

startVillageGame :: String -> ContentPack -> Either String GameState
startVillageGame = startGameWith (s01FixtureAt "red-dune-live-1" "red-dune-village-v1" villageLayouts villageRoads)

villageLayouts :: [(String, Space.Tile)]
villageLayouts =
  [ ("depot", Space.Tile 50 49),
    ("warehouse", Space.Tile 50 58),
    ("warehouse", Space.Tile 50 64),
    ("warehouse", Space.Tile 50 70),
    ("housing", Space.Tile 68 60),
    ("housing", Space.Tile 72 60),
    ("housing", Space.Tile 68 64),
    ("housing", Space.Tile 72 64),
    ("pantry", Space.Tile 64 60),
    ("solar", Space.Tile 55 49),
    ("battery", Space.Tile 55 54),
    ("farm", Space.Tile 68 49),
    ("kitchen", Space.Tile 74 54),
    ("hand_pump", Space.Tile 60 60)
  ]

villageRoads :: S.Set Space.Tile
villageRoads = S.fromList (concat [horizontal 53 51 58, vertical 58 53 74, horizontal 57 56 58, horizontal 62 51 60, horizontal 68 51 58, horizontal 74 51 58, horizontal 63 58 77, horizontal 67 67 77, vertical 67 63 67, vertical 77 58 67, horizontal 55 70 72, vertical 72 55 58, horizontal 58 72 77, vertical 75 57 58])
  where
    horizontal y a b = [Space.Tile x y | x <- [a .. b]]
    vertical x a b = [Space.Tile x y | y <- [a .. b]]

data Department = WaterWorks | FoodWorks | ServiceWorks deriving (Eq, Show, Read)

data Decision
  = Commission Department
  | StartSite EntityId
  | PlaceDetail PlaceKind Space.Tile Space.Rotation
  | RemoveDetail Space.Tile
  | RoadPath Space.Tile Space.Tile
  | ToggleTime
  | ReserveWarehouse
  | ToggleDelivery String
  | ChangeBuffer String Integer
  | ToggleProduction EntityId
  | SetFacility EntityId Bool
  | StaffFacility EntityId
  | ReleaseFacility EntityId
  | ConnectFacility EntityId
  | Plan Space.PlacementShape
  | CancelPlan EntityId
  | ToggleRepairs
  | ToggleBuildingCrews
  deriving (Eq, Show)

act :: [(String, String)] -> GameState -> Either String GameState
act fields = fmap fst . applyAction (obj [(key, str value) | (key, value) <- fields])

edit :: (GameState -> GameState) -> GameState -> Either String GameState
edit change game = do
  unless (gameRevision game < maxBound) (Left "Revision counter exhausted")
  let next = (change game) {gameRevision = gameRevision game + 1}
  validateGame next
  pure next

commands :: [Command] -> GameState -> Either String GameState
commands bodies game = do
  (world, output) <- issue 1 bodies (gameWorld game)
  unless (all accepted (outputReceipts output)) (Left (show (map receiptOutcome (outputReceipts output))))
  edit (\g -> g {gameWorld = world}) game
  where
    accepted receipt = case receiptOutcome receipt of Applied _ -> True; _ -> False

decide :: Decision -> GameState -> Either String GameState
decide decision game = case decision of
  ToggleTime -> act [("op", if worldMode world == Active then "pause" else "resume")] game
  ReserveWarehouse -> act [("op", "expand"), ("prototype", "warehouse")] game
  Commission department -> commission department game
  StartSite ident -> startSite ident game
  PlaceDetail kind tile rotation ->
    if M.lookup tile (gamePlaces game) == Just (kind, rotation)
      then Right game
      else do
        validatePlace game (tile, (kind, rotation))
        edit (\g -> g {gamePlaces = M.insert tile (kind, rotation) (gamePlaces g)}) game
  RemoveDetail tile -> if M.member tile (gamePlaces game) then edit (\g -> g {gamePlaces = M.delete tile (gamePlaces g)}) game else Right game
  RoadPath from to -> do
    state <- maybe (Left "Map is absent") Right (worldM1 world)
    let Space.Tile x y = from
        Space.Tile u v = to
        range a b = if a <= b then [a .. b] else reverse [b .. a]
        path = nub ([Space.Tile n y | n <- range x u] ++ [Space.Tile u n | n <- range y v])
        needed = filter (`S.notMember` Space.spatialRoads (m1Space state)) path
    unless (length needed <= 64 && null (gameBuildQueue game)) (Left "Road plan must be at most 64 tiles and wait for the current queue")
    mapM_ (\tile -> validatePlace game (tile, (PlaceSquare, Space.R0)) >> unless (maybe True ((== PlaceSquare) . fst) (M.lookup tile (gamePlaces game))) (Left "Keep placed furniture out of the road")) needed
    -- Check the whole route against the same physical admission used for each
    -- construction stage. A road crossing a deposit must fail before any stage
    -- is queued, instead of building a prefix and dropping the rest later.
    unless (null needed) $ do
      (_, output) <- issue 1 [PlaceConstructionPlan (s01Colony descriptor) (Space.RoadShape tile) 2 Nothing | tile <- needed] world
      unless (all (\receipt -> case receiptOutcome receipt of Applied _ -> True; _ -> False) (outputReceipts output)) (Left (show (map receiptOutcome (outputReceipts output))))
    edit (\g -> g {gameBuildQueue = map Space.RoadShape needed, gamePolicies = (gamePolicies g) {policiesEnabled = True, assistConstruction = True}}) game
  ToggleDelivery key -> policyEdit key (\route -> route {policyEnabled = not (policyEnabled route)}) game
  ChangeBuffer key delta -> policyEdit key (\route -> route {policyTarget = max (policyBatch route) (min 400000 (policyTarget route + delta))}) game
  ToggleProduction ident -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, productionSites = if ident `elem` productionSites policy then filter (/= ident) (productionSites policy) else ident : productionSites policy}}) game
  SetFacility ident enabled -> commands [SetSiteEnabled ident enabled] game
  StaffFacility ident -> staff ident game
  ReleaseFacility ident -> commands [AssignWorkers (W.OperateFacility ident) shift [] | shift <- [0 .. 2]] game
  ConnectFacility ident -> connect ident game
  Plan shape -> commands [PlaceConstructionPlan (s01Colony descriptor) shape 2 Nothing] game
  CancelPlan ident -> do
    state <- maybe (Left "No construction state") Right (worldM1 world)
    job <- maybe (Left "Construction plan is absent") Right (find ((== ident) . C.constructionSiteId) (M.elems (C.constructionJobs (m1Construction state))))
    commands [CancelConstructionPlan ident (C.constructionRevision job)] game
  ToggleRepairs -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, assistMaintenance = not (assistMaintenance policy)}}) game
  ToggleBuildingCrews -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, assistConstruction = not (assistConstruction policy)}}) game
  where
    world = gameWorld game; descriptor = gameDescriptor game; policy = gamePolicies game

-- A local work order configures ordinary rosters, recipes and delivery plans.
-- It grants no stock or labour and does not skip the physical trip or batch.
startSite :: EntityId -> GameState -> Either String GameState
startSite ident game
  | ident == s01Pump descriptor = commission WaterWorks game
  | ident `elem` [s01Farm descriptor, s01Kitchen descriptor] = do
      let keys = if ident == s01Farm descriptor then ["farm-water", "farm-biomass"] else ["pantry-food", "kitchen-crops", "kitchen-water", "kitchen-fuel", "kitchen-waste"]
          assignments = [body | body@(AssignWorkers (W.OperateFacility target) _ _) <- s01RosterCommands descriptor, target == ident]
          routes = [route | route <- deliveryPolicies (survivalPolicies descriptor), policyId route `elem` keys]
      staffed <- commands (assignments ++ [SetSiteEnabled ident True]) game
      edit (\g -> g {gamePolicies = mergeRoutes routes (gamePolicies g) {policiesEnabled = True, productionSites = nub (ident : productionSites (gamePolicies g))}}) staffed
  | otherwise = do
      staffed <- staff ident game
      linked <- connect ident staffed
      if M.member ident (worldSites (gameWorld linked))
        then do
          enabled <- commands [SetSiteEnabled ident True] linked
          edit (\g -> g {gamePolicies = (gamePolicies g) {policiesEnabled = True, productionSites = nub (ident : productionSites (gamePolicies g))}}) enabled
        else pure linked
  where
    descriptor = gameDescriptor game

mergeRoutes :: [DeliveryPolicy] -> Policies -> Policies
mergeRoutes additions policy = policy {deliveryPolicies = M.elems (M.union (M.fromList [(policyId route, route) | route <- additions]) (M.fromList [(policyId route, route) | route <- deliveryPolicies policy]))}

-- New factories require a real input/output route as well as workers. Routes
-- use existing producers and warehouses; carts, reservations and road access
-- still determine whether a delivery can physically complete.
connect :: EntityId -> GameState -> Either String GameState
connect ident game
  | Just owner <- find (\(Owner kind target) -> target == ident && kind `elem` [Pantry, Tank]) (M.keys (invStorage (worldInventory world))) =
      let resources = case owner of Owner Pantry _ -> [(Water, 40000, 20000), (Ration, 18000, 9000)]; _ -> [(Water, 60000, 30000)]
          supply resource = nub ([siteOutput site | site <- M.elems (worldSites world), Just recipe <- [M.lookup (siteRecipe site) (contentRecipes (worldContent world))], M.member resource (recipeOutputs recipe)] ++ stores)
          additions = [DeliveryPolicy ("service-" ++ show number ++ "-" ++ resourceKey resource) (supply resource) owner resource target batch 0 True | (resource, target, batch) <- resources]
       in edit (\g -> g {gamePolicies = mergeRoutes additions (gamePolicies g) {policiesEnabled = True}}) game
  | otherwise = do
      site <- maybe (Left "Production facility is absent") Right (M.lookup ident (worldSites world))
      recipe <- lookupRecipe (worldContent world) (siteRecipe site)
      reserve <- case stores of destination : _ -> Right destination; [] -> Left "Reserve warehouse is absent"
      let key direction resource = "facility-" ++ show number ++ "-" ++ direction ++ "-" ++ resourceKey resource
          sources resource =
            nub
              ( [ siteOutput other
                | (otherId, other) <- M.toAscList (worldSites world),
                  otherId /= ident,
                  Just otherRecipe <- [M.lookup (siteRecipe other) (contentRecipes (worldContent world))],
                  M.member resource (recipeOutputs otherRecipe)
                ]
                  ++ stores
              )
          incoming resource = any (\route -> policyDestination route == siteInput site && policyResource route == resource) existing
          outgoing resource = any (\route -> siteOutput site `elem` policySources route && policyResource route == resource) existing
          inputs =
            [ DeliveryPolicy (key "input" resource) (sources resource) (siteInput site) resource (min 400000 (3 * amount)) amount 1 True
            | (resource, amount) <- M.toAscList (recipeInputs recipe),
              not (incoming resource)
            ]
          outputs =
            [ DeliveryPolicy
                (key "output" resource)
                [siteOutput site]
                (if resource == Ration then s01Pantry descriptor else reserve)
                resource
                (min 400000 (3 * amount))
                amount
                (if resource == Ration then 0 else 3)
                True
            | (resource, amount) <- M.toAscList (recipeOutputs recipe),
              not (outgoing resource)
            ]
      edit (\g -> g {gamePolicies = (gamePolicies g) {policiesEnabled = True, deliveryPolicies = existing ++ inputs ++ outputs}}) game
  where
    world = gameWorld game
    descriptor = gameDescriptor game
    stores = s01Warehouses descriptor
    existing = deliveryPolicies (gamePolicies game)
    EntityId number = ident

data SiteMood = MoodQuiet | MoodWaiting | MoodBusy | MoodReady | MoodTrouble deriving (Eq, Show)

data SiteStatus = SiteStatus {statusMood :: !SiteMood, statusTitle :: !String, statusDetail :: !String, statusProgress :: !(Maybe Float)} deriving (Eq, Show)

rosterCount :: GameState -> EntityId -> Int
rosterCount game ident = case worldM1 (gameWorld game) of
  Nothing -> 0
  Just state -> minimum [length (M.findWithDefault [] (W.OperateFacility ident, shift) (W.workforceRosters (m1Workforce state))) | shift <- [0 .. 2]]

siteStatus :: GameState -> EntityId -> SiteStatus
siteStatus game ident
  | Just job <- construction = SiteStatus (if C.constructionPhase job == C.ConstructionRunning then MoodBusy else MoodWaiting) (if C.constructionPhase job == C.ConstructionRunning then "建てています" else "建設を待っています") (case C.constructionBlocked job of Just MissingStock -> "建材の到着待ち"; Just _ -> "班・道路・建材を確認"; Nothing -> "建設班が現場を受け持ちます") (Just (fromInteger (C.constructionProgress job) / fromInteger (max 1 (C.constructionRequired (C.constructionSnapshot job)))))
  | facilityStopped (worldMaintenance world) ident = SiteStatus MoodTrouble "修理が必要" (siteReport game ident) Nothing
  | name == "pantry" =
      if rosterCount game ident == 0
        then SiteStatus MoodWaiting "配給する人がいません" "班を配置すると、届いた水と食事を配ります" Nothing
        else
          if physical world (Owner Pantry ident) Water <= 0 || physical world (Owner Pantry ident) Ration <= 0
            then SiteStatus MoodTrouble "届く物資を待っています" "水と食料の配送を確認" Nothing
            else SiteStatus MoodReady "水と食事を配っています" "届いた備蓄が40人の生活を支えています" Nothing
  | Just site <- M.lookup ident (worldSites world) =
      case activeJob of
        Just job | siteEnabled site && jobPhase job == Running -> SiteStatus MoodBusy (if name `elem` ["farm", "greenhouse"] then "作物を育てています" else if name == "kitchen" then "食事を作っています" else "作業中") "班が作業しています" (Just (fromInteger (jobProgress job) / fromInteger (max 1 (jobRequired job))))
        _ ->
          if ident `notElem` productionSites (gamePolicies game) || not (siteEnabled site)
            then
              if rosterCount game ident > 0 && siteEnabled site
                then SiteStatus MoodQuiet "次の生産は停止中" "担当と配送は残ります" Nothing
                else SiteStatus MoodQuiet "作業を始められます" "班と配送を整えて、連続して作ります" Nothing
            else
              if rosterCount game ident == 0
                then SiteStatus MoodWaiting "作業する人がいません" "空いている班を配置してください" Nothing
                else case missingNatural site of
                  (resource, remainingNatural, required) : _ -> SiteStatus MoodTrouble (resourceName resource ++ "の区画が不足") ("残り " ++ resourceAmount resource remainingNatural ++ " / 次の作業に " ++ resourceAmount resource required) Nothing
                  [] -> case missingInputs site of
                    [] | any (\resource -> physical world (siteOutput site) resource > 0) allResources -> SiteStatus MoodReady "できた物資を出荷待ち" "積荷が届いて初めて、次の場所で使えます" Nothing
                    [] -> SiteStatus MoodWaiting "次の作業を待っています" (siteReport game ident) Nothing
                    missing -> SiteStatus MoodWaiting (resourceName (fst (head missing)) ++ "の到着待ち") (intercalate " / " [resourceName resource ++ " " ++ resourceAmount resource amount | (resource, amount) <- missing]) Nothing
  | name == "housing" = SiteStatus MoodReady "休める家" "この家に割り当てられた住人の寝床です" Nothing
  | name == "solar" = SiteStatus MoodReady "太陽光の発電設備" "日が出ている間に電力を生みます" Nothing
  | name == "battery" = SiteStatus MoodReady "蓄電設備" "発電した電力を蓄えて使います" Nothing
  | otherwise = SiteStatus MoodReady "備蓄の場所" "運ばれてきた物資をここに置きます" Nothing
  where
    world = gameWorld game
    placement = worldM1 world >>= M.lookup ident . Space.spatialPlacements . m1Space
    name = case Space.placementShape <$> placement of Just (Space.BuildingShape prototype _ _) -> prototype; _ -> "road"
    construction = worldM1 world >>= find (\job -> C.constructionSiteId job == ident && not (C.constructionTerminal job)) . M.elems . C.constructionJobs . m1Construction
    activeJob = find (\job -> M.lookup (jobId job) (worldJobSites world) == Just ident && not (terminal job)) (M.elems (worldJobs world))
    missingInputs site = case M.lookup (siteRecipe site) (contentRecipes (worldContent world)) of
      Nothing -> []
      Just recipe -> [(resource, amount - physical world (siteInput site) resource) | (resource, amount) <- M.toAscList (recipeInputs recipe), physical world (siteInput site) resource < amount]
    missingNatural site = case M.lookup (siteRecipe site) (contentRecipes (worldContent world)) of
      Nothing -> []
      Just recipe ->
        [ (depositResource deposit, remainingNatural, required)
        | (kind, required) <- M.toAscList (recipeNaturalSources recipe),
          Just source <- [M.lookup kind (siteNatural site)],
          Just deposit <- [M.lookup source (invDeposits (worldInventory world))],
          let reserved = sum [qtyValue (naturalAmount r) | r <- M.elems (invNatural (worldInventory world)), naturalSource r == source],
          let remainingNatural = max 0 (qtyValue (depositQty deposit) - reserved),
          remainingNatural < required
        ]

policyEdit :: String -> (DeliveryPolicy -> DeliveryPolicy) -> GameState -> Either String GameState
policyEdit key change game = do
  unless (any ((== key) . policyId) (deliveryPolicies (gamePolicies game))) (Left "Supply route has not been commissioned")
  edit (\g -> g {gamePolicies = (gamePolicies g) {deliveryPolicies = map (\route -> if policyId route == key then change route else route) (deliveryPolicies (gamePolicies g))}}) game

commission :: Department -> GameState -> Either String GameState
commission department game = do
  let descriptor = gameDescriptor game
      world = gameWorld game
      policy = gamePolicies game
      standard = survivalPolicies descriptor
      pump = s01Pump descriptor
      farm = s01Farm descriptor
      kitchen = s01Kitchen descriptor
      Owner _ pantry = s01Pantry descriptor
      included target = case (department, target) of
        (WaterWorks, W.OperateFacility ident) -> ident `elem` [pump, pantry]
        (WaterWorks, W.DriveVehicle _) -> True
        (FoodWorks, W.OperateFacility ident) -> ident `elem` [farm, kitchen]
        _ -> False
      crews = [body | body@(AssignWorkers target _ _) <- s01RosterCommands descriptor, included target]
      enables = if department == FoodWorks then [SetSiteEnabled farm True, SetSiteEnabled kitchen True] else []
      siteIds = case department of WaterWorks -> [pump]; FoodWorks -> [farm, kitchen]; ServiceWorks -> []
      keys = case department of WaterWorks -> ["pantry-water"]; FoodWorks -> ["pantry-food", "farm-water", "kitchen-crops", "kitchen-water", "kitchen-fuel", "farm-biomass", "kitchen-waste"]; ServiceWorks -> []
      additions = [route | route <- deliveryPolicies standard, policyId route `elem` keys]
      merged = M.elems (M.union (M.fromList [(policyId r, r) | r <- additions]) (M.fromList [(policyId r, r) | r <- deliveryPolicies policy]))
  (staffed, output) <- issue 1 (crews ++ enables) world
  unless (all (\receipt -> case receiptOutcome receipt of Applied _ -> True; _ -> False) (outputReceipts output)) (Left "Some workers are already assigned. Release their old assignment before commissioning.")
  edit (\g -> g {gameWorld = staffed, gamePolicies = policy {policiesEnabled = True, productionSites = S.toAscList (S.fromList (siteIds ++ productionSites policy)), deliveryPolicies = merged, assistMaintenance = assistMaintenance policy || department == ServiceWorks, assistConstruction = assistConstruction policy || department == ServiceWorks}}) game

staff :: EntityId -> GameState -> Either String GameState
staff ident game = do
  state <- maybe (Left "Workforce state is absent") Right (worldM1 world)
  placement <- maybe (Left "Building is absent") Right (M.lookup ident (Space.spatialPlacements (m1Space state)))
  name <- case Space.placementShape placement of Space.BuildingShape prototype _ _ -> Right prototype; _ -> Left "Roads have no operating crew"
  building <- lookupBuilding (worldContent world) name
  let target = W.OperateFacility ident
      required = fromInteger (buildingWorkers building)
      roster shift = M.findWithDefault [] (target, shift) (W.workforceRosters (m1Workforce state))
      free shift =
        [ person
        | (person, resident) <- M.toAscList (needsResidents (worldNeeds world)),
          residentShift resident == shift,
          residentStatus resident == Living,
          person `notElem` concat [names | ((other, s), names) <- M.toList (W.workforceRosters (m1Workforce state)), s == shift, other /= target]
        ]
      choice shift = take required (roster shift ++ filter (`notElem` roster shift) (free shift))
  unless (all (\shift -> length (choice shift) == required) [0 .. 2]) (Left "Not enough free people across all three shifts. Release another facility first.")
  commands [AssignWorkers target shift (choice shift) | shift <- [0 .. 2]] game
  where
    world = gameWorld game

siteName :: String -> String
siteName prototype =
  maybe
    prototype
    id
    ( lookup
        prototype
        [ ("depot", "開拓拠点"),
          ("warehouse", "倉庫"),
          ("housing", "住居"),
          ("pantry", "配給所"),
          ("hand_pump", "手動井戸"),
          ("pump", "揚水機"),
          ("brine_pump", "塩水ポンプ"),
          ("farm", "農場"),
          ("greenhouse", "温室"),
          ("kitchen", "厨房"),
          ("solar", "太陽光発電"),
          ("battery", "蓄電池"),
          ("tank", "貯水槽"),
          ("mine", "鉱山"),
          ("quarry", "採石場"),
          ("smelter", "製錬所"),
          ("kiln", "窯"),
          ("workshop", "工房"),
          ("electronics", "電子部品工房"),
          ("refinery", "精製所"),
          ("recycler", "再生工房"),
          ("clinic", "診療所"),
          ("desalinator", "淡水化施設"),
          ("research", "研究所"),
          ("road", "道路")
        ]
    )

routeName :: String -> String
routeName key = maybe key id (lookup key [("pantry-water", "井戸 → 配給所 / 水"), ("pantry-food", "厨房 → 配給所 / 食料"), ("farm-water", "井戸 → 農場 / 水"), ("kitchen-crops", "農場 → 厨房 / 作物"), ("kitchen-water", "井戸 → 厨房 / 水"), ("kitchen-fuel", "倉庫 → 厨房 / 燃料"), ("farm-biomass", "農場 → 倉庫 / 残渣"), ("kitchen-waste", "厨房 → 倉庫 / 廃棄物")])

deliveryName :: World -> DeliveryPolicy -> String
deliveryName world route
  | routeName (policyId route) /= policyId route = routeName (policyId route)
  | otherwise = ownerName (policyDestination route) ++ "へ / " ++ resourceName (policyResource route)
  where
    ownerName (Owner _ ident) = case worldM1 world >>= M.lookup ident . Space.spatialPlacements . m1Space of
      Just placement -> case Space.placementShape placement of Space.BuildingShape name _ _ -> siteName name; _ -> "施設"
      Nothing -> "施設"

resourceAmount :: Resource -> Integer -> String
resourceAmount resource amount
  | resource `elem` [Parts, Circuit, Tools] = show amount ++ " 個"
  | resource == Medicine = show amount ++ " 回分"
  | otherwise = printf "%.1f" (fromInteger amount / 1000 :: Double) ++ if resource `elem` [Water, Brine] then " L" else " kg"

resourceName :: Resource -> String
resourceName resource = maybe (show resource) id (lookup resource [(Water, "水"), (Brine, "塩水"), (Ore, "鉱石"), (Sand, "砂"), (Circuit, "回路"), (Medicine, "医薬品"), (Tools, "道具"), (Ration, "食料"), (Crops, "作物"), (Fuel, "燃料"), (Parts, "部品"), (Stone, "石材"), (Metal, "金属"), (Glass, "ガラス"), (Biomass, "残渣"), (Waste, "廃棄物")])

-- Player-facing diagnosis reads current public physical state, not future RNG.
advice :: GameState -> (String, String)
advice game
  | campaignEnding campaign == SettlementSecured = ("この土地に、暮らしが根づいた。", "40人を支える生産・輸送・備蓄が、交代を越えて続きました。")
  | ColonyLost _ <- campaignEnding campaign = ("配給が途絶え、開拓は中断しました。", "保存を読み込むか、備蓄を守る方針で新しく始められます。")
  | not (s01Pump d `elem` productionSites policy) = ("最初に、水を通そう。", "井戸・配給所・運搬班を三交代で配置すると、物資が動き始めます。")
  | not (s01Farm d `elem` productionSites policy) = ("備蓄があるうちに、食料を作ろう。", "農場と厨房を動かし、水・作物・燃料の供給をつなぎます。")
  | broken = ("厨房が停止。備蓄があるうちに修復を。", "保守班を有効にすると、部品を運び、作業員が実際に修理します。")
  | water < 20000 || food < 10000 = ("配給所の残量が少なくなっています。", "供給タブで止まった配送と不足する材料を確認してください。")
  | not (assistMaintenance policy) = ("暮らしを守る、予備の班を。", "保守を準備してください。厨房は24時間後に故障します。")
  | not (campaignExpanded campaign) = ("余力を、予備の備蓄へ。", "予備倉庫と道路を計画。建設班と物資がそろうと、現場が進みます。")
  | not (campaignRecovered campaign) = ("故障に備えながら、暮らしを続けよう。", "厨房の停止は開拓開始から24時間後。部品と配給の余裕を確保します。")
  | otherwise = ("一日を越えて、暮らしを続けよう。", "物資の滞りと疲労を見守り、安定した配給を維持してください。")
  where
    world = gameWorld game
    d = gameDescriptor game
    campaign = gameCampaign game
    policy = gamePolicies game
    broken = maybe False ((== FacilityBroken) . maintenanceStatus) (M.lookup (s01Kitchen d) (maintenanceFacilities (worldMaintenance world)))
    water = physical world (s01Pantry d) Water
    food = physical world (s01Pantry d) Ration

siteReport :: GameState -> EntityId -> String
siteReport game ident = case M.lookup ident (worldSites world) of
  Nothing -> "生活・備蓄を支える施設"
  Just site
    | facilityStopped (worldMaintenance world) ident -> case find (\job -> maintenanceTarget job == ident && not (maintenanceTerminal job)) (M.elems (maintenanceJobs (worldMaintenance world))) of
        Just job | maintenancePhase job == MaintenanceRunning -> "修理中 " ++ show (100 * maintenanceProgress job `div` max 1 (maintenanceRequired job)) ++ "% / 保守班が作業中"
        Just job | maintenanceBlocked job == Just MissingStock -> "修理部品を待っています / 必要 " ++ resourceAmount Parts (maintenanceParts job)
        _ -> "故障中 / 保守班と部品の配送を確認"
    | not (siteEnabled site) -> "生産を停止しています"
    | Just job <- find (\j -> M.lookup (jobId j) (worldJobSites world) == Just ident && not (terminal j)) (M.elems (worldJobs world)) ->
        if jobPhase job == Running
          then "生産中 " ++ show (100 * jobProgress job `div` max 1 (jobRequired job)) ++ "%"
          else case jobBlocked job of
            Just MissingStock -> inputReport site
            Just NoCapacity -> "出荷待ち / 出力先が満杯"
            _ -> "作業待ち / 班・電力・道路を確認"
    | freeWeight (worldInventory world) (siteOutput site) <= 0 -> "出荷待ち / 出力先が満杯"
    | otherwise -> inputReport site
  where
    world = gameWorld game
    inputReport site =
      let missing = case M.lookup (siteRecipe site) (contentRecipes (worldContent world)) of
            Nothing -> []
            Just recipe -> [(resource, required - physical world (siteInput site) resource) | (resource, required) <- M.toAscList (recipeInputs recipe), physical world (siteInput site) resource < required]
       in if null missing then "待機 / 班・出荷・生産の有効を確認" else "不足: " ++ intercalate "、" [resourceName resource ++ " " ++ resourceAmount resource amount | (resource, amount) <- missing]
