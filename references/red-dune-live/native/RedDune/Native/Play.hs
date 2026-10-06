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
import Data.List (find)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import RedDune.Campaign
import RedDune.Game
import RedDune.Policies

data Department = WaterWorks | FoodWorks | ServiceWorks deriving (Eq, Show, Read)
data Decision
  = Commission Department | ToggleTime | ReserveWarehouse
  | ToggleDelivery String | ChangeBuffer String Integer
  | ToggleProduction EntityId | SetFacility EntityId Bool
  | StaffFacility EntityId | ReleaseFacility EntityId
  | Plan Space.PlacementShape | CancelPlan EntityId
  | ToggleRepairs | ToggleBuildingCrews
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
  where accepted receipt = case receiptOutcome receipt of Applied _ -> True; _ -> False

decide :: Decision -> GameState -> Either String GameState
decide decision game = case decision of
  ToggleTime -> act [("op", if worldMode world == Active then "pause" else "resume")] game
  ReserveWarehouse -> act [("op", "expand"), ("prototype", "warehouse")] game
  Commission department -> commission department game
  ToggleDelivery key -> policyEdit key (\route -> route {policyEnabled = not (policyEnabled route)}) game
  ChangeBuffer key delta -> policyEdit key (\route -> route {policyTarget = max (policyBatch route) (min 400000 (policyTarget route + delta))}) game
  ToggleProduction ident -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, productionSites = if ident `elem` productionSites policy then filter (/= ident) (productionSites policy) else ident : productionSites policy}}) game
  SetFacility ident enabled -> commands [SetSiteEnabled ident enabled] game
  StaffFacility ident -> staff ident game
  ReleaseFacility ident -> commands [AssignWorkers (W.OperateFacility ident) shift [] | shift <- [0..2]] game
  Plan shape -> commands [PlaceConstructionPlan (s01Colony descriptor) shape 2 Nothing] game
  CancelPlan ident -> do
    state <- maybe (Left "No construction state") Right (worldM1 world)
    job <- maybe (Left "Construction plan is absent") Right (find ((== ident) . C.constructionSiteId) (M.elems (C.constructionJobs (m1Construction state))))
    commands [CancelConstructionPlan ident (C.constructionRevision job)] game
  ToggleRepairs -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, assistMaintenance = not (assistMaintenance policy)}}) game
  ToggleBuildingCrews -> edit (\g -> g {gamePolicies = policy {policiesEnabled = True, assistConstruction = not (assistConstruction policy)}}) game
  where world = gameWorld game; descriptor = gameDescriptor game; policy = gamePolicies game

policyEdit :: String -> (DeliveryPolicy -> DeliveryPolicy) -> GameState -> Either String GameState
policyEdit key change game = do
  unless (any ((== key) . policyId) (deliveryPolicies (gamePolicies game))) (Left "Supply route has not been commissioned")
  edit (\g -> g {gamePolicies = (gamePolicies g) {deliveryPolicies = map (\route -> if policyId route == key then change route else route) (deliveryPolicies (gamePolicies g))}}) game

commission :: Department -> GameState -> Either String GameState
commission department game = do
  let descriptor = gameDescriptor game; world = gameWorld game; policy = gamePolicies game
      standard = survivalPolicies descriptor
      pump = s01Pump descriptor; farm = s01Farm descriptor; kitchen = s01Kitchen descriptor
      Owner _ pantry = s01Pantry descriptor
      included target = case (department, target) of
        (WaterWorks, W.OperateFacility ident) -> ident `elem` [pump, pantry]
        (WaterWorks, W.DriveVehicle _) -> True
        (FoodWorks, W.OperateFacility ident) -> ident `elem` [farm, kitchen]
        _ -> False
      crews = [body | body@(AssignWorkers target _ _) <- s01RosterCommands descriptor, included target]
      enables = if department == FoodWorks then [SetSiteEnabled farm True, SetSiteEnabled kitchen True] else []
      siteIds = case department of WaterWorks -> [pump]; FoodWorks -> [farm,kitchen]; ServiceWorks -> []
      keys = case department of WaterWorks -> ["pantry-water"]; FoodWorks -> ["pantry-food","farm-water","kitchen-crops","kitchen-water","kitchen-fuel","farm-biomass","kitchen-waste"]; ServiceWorks -> []
      additions = [route | route <- deliveryPolicies standard, policyId route `elem` keys]
      merged = M.elems (M.union (M.fromList [(policyId r,r) | r <- additions]) (M.fromList [(policyId r,r) | r <- deliveryPolicies policy]))
  (staffed, output) <- issue 1 (crews ++ enables) world
  unless (all (\receipt -> case receiptOutcome receipt of Applied _ -> True; _ -> False) (outputReceipts output)) (Left "Some workers are already assigned. Release their old assignment before commissioning.")
  edit (\g -> g {gameWorld = staffed, gamePolicies = policy {policiesEnabled = True, productionSites = S.toAscList (S.fromList (siteIds ++ productionSites policy)), deliveryPolicies = merged, assistMaintenance = assistMaintenance policy || department == ServiceWorks, assistConstruction = assistConstruction policy || department == ServiceWorks}}) game

staff :: EntityId -> GameState -> Either String GameState
staff ident game = do
  state <- maybe (Left "Workforce state is absent") Right (worldM1 world)
  placement <- maybe (Left "Building is absent") Right (M.lookup ident (Space.spatialPlacements (m1Space state)))
  name <- case Space.placementShape placement of Space.BuildingShape prototype _ _ -> Right prototype; _ -> Left "Roads have no operating crew"
  building <- lookupBuilding (worldContent world) name
  let target = W.OperateFacility ident; required = fromInteger (buildingWorkers building)
      roster shift = M.findWithDefault [] (target,shift) (W.workforceRosters (m1Workforce state))
      free shift = [person | (person,resident) <- M.toAscList (needsResidents (worldNeeds world)), residentShift resident == shift, residentStatus resident == Living,
                    person `notElem` concat [names | ((other,s),names) <- M.toList (W.workforceRosters (m1Workforce state)), s == shift, other /= target]]
      choice shift = take required (roster shift ++ filter (`notElem` roster shift) (free shift))
  unless (all (\shift -> length (choice shift) == required) [0..2]) (Left "Not enough free people across all three shifts. Release another facility first.")
  commands [AssignWorkers target shift (choice shift) | shift <- [0..2]] game
  where world = gameWorld game

siteName :: String -> String
siteName prototype = maybe prototype id (lookup prototype
  [("depot","開拓拠点"),("warehouse","倉庫"),("housing","住居"),("pantry","配給所"),("hand_pump","手動井戸"),("pump","揚水機"),("brine_pump","塩水ポンプ"),
   ("farm","農場"),("greenhouse","温室"),("kitchen","厨房"),("solar","太陽光発電"),("battery","蓄電池"),("tank","貯水槽"),("mine","鉱山"),("quarry","採石場"),("smelter","製錬所"),
   ("kiln","窯"),("workshop","工房"),("electronics","電子部品工房"),("refinery","精製所"),("recycler","再生工房"),("clinic","診療所"),("research","研究所"),("road","道路")])

routeName :: String -> String
routeName key = maybe key id (lookup key [("pantry-water","井戸 → 配給所 / 水"),("pantry-food","厨房 → 配給所 / 食料"),("farm-water","井戸 → 農場 / 水"),("kitchen-crops","農場 → 厨房 / 作物"),("kitchen-water","井戸 → 厨房 / 水"),("kitchen-fuel","倉庫 → 厨房 / 燃料"),("farm-biomass","農場 → 倉庫 / 残渣"),("kitchen-waste","厨房 → 倉庫 / 廃棄物")])

resourceName :: Resource -> String
resourceName resource = maybe (show resource) id (lookup resource [(Water,"水"),(Ration,"食料"),(Crops,"作物"),(Fuel,"燃料"),(Parts,"部品"),(Stone,"石材"),(Metal,"金属"),(Glass,"ガラス"),(Biomass,"残渣"),(Waste,"廃棄物")])

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
    world = gameWorld game; d = gameDescriptor game; campaign = gameCampaign game; policy = gamePolicies game
    broken = maybe False ((== FacilityBroken) . maintenanceStatus) (M.lookup (s01Kitchen d) (maintenanceFacilities (worldMaintenance world)))
    water = physical world (s01Pantry d) Water; food = physical world (s01Pantry d) Ration

siteReport :: GameState -> EntityId -> String
siteReport game ident = case M.lookup ident (worldSites world) of
  Nothing -> "生活・備蓄を支える施設"
  Just site
    | facilityStopped (worldMaintenance world) ident -> "停止中 / 部品を届けて修復"
    | not (siteEnabled site) -> "生産を停止しています"
    | Just job <- find (\j -> M.lookup (jobId j) (worldJobSites world) == Just ident && not (terminal j)) (M.elems (worldJobs world)) ->
        if jobPhase job == Running then "生産中 " ++ show (100 * jobProgress job `div` max 1 (jobRequired job)) ++ "%" else "作業待ち / " ++ show (jobBlocked job)
    | freeWeight (worldInventory world) (siteOutput site) <= 0 -> "出荷待ち / 出力先が満杯"
    | otherwise -> "待機 / 材料・人員・配送を確認"
  where world = gameWorld game
