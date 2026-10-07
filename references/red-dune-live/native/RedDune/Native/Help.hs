module RedDune.Native.Help where

import Control.Monad (guard)
import Data.ByteString.Char8 qualified as B
import Data.List (intercalate, nub, stripPrefix)
import Data.Set qualified as Set

-- UI learning is separate from the strict, authoritative world-save codec.
data TopicId = TimeAndControls | WaterAndFood | DeliveryAndStock | ShiftCrews | RoadsAndBuilding | DiningAndPlaces | SavingAndResume
  deriving (Eq, Ord, Show, Enum, Bounded)

data HintId = WellHint | FarmHint | KitchenHint | FirstFoodHint | DiningPlanHint | DiningUseHint | RoadHint | PlacesHint | DeliveryHint | CrewsHint | ResumeHint
  deriving (Eq, Ord, Show, Enum, Bounded)

data Preferences = Preferences {guidesEnabled :: !Bool, seenHints :: !(Set.Set HintId)} deriving (Eq, Show)

data HelpUi = HelpUi {helpTopic :: !(Maybe TopicId), activeHint :: !(Maybe HintId), helpPreferences :: !Preferences} deriving (Eq, Show)

data HelpAction = OpenHelp TopicId | CloseHelp | DismissHint | SetGuides Bool | RepeatHints deriving (Eq, Show)

defaultPreferences :: Preferences
defaultPreferences = Preferences True Set.empty

newHelpUi :: Preferences -> HelpUi
newHelpUi preferences = HelpUi Nothing Nothing preferences

-- Restoring an existing settlement does not replay the starter prompts.
-- Other contextual hints remain available; RepeatHints explicitly restores all.
resumedHelpUi :: Preferences -> HelpUi
resumedHelpUi preferences = newHelpUi preferences {seenHints = Set.union (seenHints preferences) (Set.fromList [WellHint, FarmHint, KitchenHint, FirstFoodHint])}

helpHoldsClock :: HelpUi -> HelpUi -> Bool
helpHoldsClock before after = helpTopic before /= Nothing || helpTopic after /= Nothing

updateHelp :: HelpAction -> HelpUi -> HelpUi
updateHelp action ui = case action of
  OpenHelp topic -> ui {helpTopic = Just topic}
  CloseHelp -> ui {helpTopic = Nothing}
  DismissHint -> ui {activeHint = Nothing}
  SetGuides enabled -> ui {activeHint = Nothing, helpPreferences = (helpPreferences ui) {guidesEnabled = enabled}}
  RepeatHints -> ui {activeHint = Nothing, helpPreferences = defaultPreferences}

-- A displayed hint stays until dismissed or its real condition changes.
-- Its stable ID is remembered immediately, so a restart does not repeat it.
refreshHint :: Maybe HintId -> HelpUi -> HelpUi
refreshHint desired ui
  | not (guidesEnabled preferences) = ui {activeHint = Nothing}
  | helpTopic ui /= Nothing = ui
  | desired == activeHint ui = ui
  | Just hint <- desired,
    hint `Set.notMember` seenHints preferences =
      ui {activeHint = Just hint, helpPreferences = preferences {seenHints = Set.insert hint (seenHints preferences)}}
  | otherwise = ui {activeHint = Nothing}
  where
    preferences = helpPreferences ui

allTopics :: [TopicId]
allTopics = [minBound .. maxBound]

topicTitle :: TopicId -> String
topicTitle topic = case topic of
  TimeAndControls -> "操作と時間"
  WaterAndFood -> "水と料理"
  DeliveryAndStock -> "配送と備蓄"
  ShiftCrews -> "三交代の班"
  RoadsAndBuilding -> "建設と道路"
  DiningAndPlaces -> "食事の場と飾り"
  SavingAndResume -> "保存と再開"

-- Three short sections per chapter; every chapter is freely accessible.
topicSections :: TopicId -> [(String, String)]
topicSections topic = case topic of
  TimeAndControls ->
    [ ("建物を選んで、できることを見る", "地図の建物をクリックすると、作業や在庫、班の配置を見られます。好きな場所から試せます。"),
      ("時間は自分で進める", "Spaceで停止・再開、1〜4キーで1・2・4・8倍速に切り替えます。この遊び方を開いている間は進みません。ウィンドウを離れた時も止まります。"),
      ("地図を動かす", "WASDで移動、ホイールで拡大・縮小、Q/Eで視点を回転、Fで全体を見られます。定住は66時間、回復は42時間の開拓が区切りです。")
    ]
  WaterAndFood ->
    [ ("井戸で水を汲む", "井戸の「水を汲み始める」で、井戸・配給所・荷車に三交代の班を配置します。押すと時間が進み、汲んだ水を荷車が運びます。"),
      ("農場で作物を育てる", "「作物を育て始める」で、農場の担当と水・作物の配送を準備します。押すと時間が進みます。水が届くと作物が育ちます。"),
      ("厨房で料理を作る", "「料理を作り始める」で、厨房の担当と材料・料理の配送を準備します。押すと時間が進みます。作物・水・燃料がそろうと料理を作り、配給所へ運びます。")
    ]
  DeliveryAndStock ->
    [ ("届け先に置く量を決める", "「現在」は届け先にある量、「目標」は補充する量の目安です。＋/−で目標を変えます。水はL、食料や建材はkgで表示します。"),
      ("運搬中の物資も数える", "荷車に積んだ分も見込んで補充します。あと少し足りない時でも、1回分の荷物が必要になるまでは「補充はまだ不要です」と表示します。"),
      ("在庫と道路を確かめる", "「送り元の在庫待ち」なら、送り元に使える在庫がありません。生産施設や倉庫の在庫を見られます。停止ボタンを押しても、運搬中の荷物は届きます。")
    ]
  ShiftCrews ->
    [ ("三つの班が交代で働く", "施設に班を配置すると、三交代それぞれに担当を置きます。仕事に必要な人数や材料がそろうと作業を始め、交代した住民は休みます。"),
      ("次の生産を止める", "「連続生産を止める」は、次の仕事を始めない設定です。進行中の作業は続きます。班の配置と配送も残ります。"),
      ("担当を外す・保守する", "「この施設の班を外す」で、三交代の担当を解除します。作業中は解除できないことがあります。予備班は保守を先に行い、終わると建設に戻れます。")
    ]
  RoadsAndBuilding ->
    [ ("施設を好きな場所に建てる", "「建てる」で種類を選び、地面をクリックして計画を置きます。Rで向きを変えられます。建物・地形・置いた飾りと重なる場所には建てられません。"),
      ("道路の両端を選ぶ", "道路は始点、終点の順にクリックすると、曲がりを含む道を計画します。1回の計画は64マスまでです。先に計画した道や施設の着工を待つことがあります。"),
      ("材料と班が工事を進める", "建材を運び、予備班が働くと建設が進みます。完成した生産施設では、道路・班・材料の配送も確認できます。通常の工事中の施設は選んで取り消せます。")
    ]
  DiningAndPlaces ->
    [ ("自分の食事の場をつくる", "「食事の場」で地面を選び、道路と合計費用を確認して確定します。つくれるのは1か所です。確定後の移設・取消はできません。"),
      ("ここへ運んだ料理を食べる", "各班2人、計6人の住民が利用します。勤務中や料理がない時は通常の配給を使います。表示人数は、各住民の前回の食事がここだった人の数で、累計ではありません。"),
      ("周りに好きなものを並べる", "飾りを選び、地面をクリックして置きます。Rで回転できます。置き直す時は片づけてからもう一度置きます。飾りは見た目を変え、生産や食事の量は変えません。")
    ]
  SavingAndResume ->
    [ ("いつでも手動で保存する", "上の「保存」かF5で、今の開拓を保存できます。変更した進行は約30秒ごとと終了時にも保存します。「自動保存待ち」は次の保存を待っている状態です。"),
      ("内容を見てから再開する", "「保存一覧」かF9で保存を選び、内容を確認してから再開します。元の履歴を残し、新しい履歴で一時停止から始まります。Spaceを押すと続けられます。"),
      ("遊び方と案内はいつでも読む", "「遊び方」かF1で開き、Escで閉じられます。配置途中でも元の画面に戻れます。短い案内をOFFにしても、全章を読めます。")
    ]

hintTopic :: HintId -> TopicId
hintTopic hint = case hint of
  WellHint -> WaterAndFood
  FarmHint -> WaterAndFood
  KitchenHint -> WaterAndFood
  FirstFoodHint -> WaterAndFood
  DiningPlanHint -> DiningAndPlaces
  DiningUseHint -> DiningAndPlaces
  RoadHint -> RoadsAndBuilding
  PlacesHint -> DiningAndPlaces
  DeliveryHint -> DeliveryAndStock
  CrewsHint -> ShiftCrews
  ResumeHint -> SavingAndResume

hintCopy :: HintId -> (String, String)
hintCopy hint = case hint of
  WellHint -> ("井戸から水を運べます", "井戸を選ぶと、班と荷車をまとめて準備できます。好きな時に始められます。")
  FarmHint -> ("農場で作物を育てられます", "農場の担当と配送を準備すると、届いた水で作物が育ちます。")
  KitchenHint -> ("作物を料理にできます", "厨房の担当と配送を準備すると、材料がそろってから料理を作ります。")
  FirstFoodHint -> ("料理が届くまで、街を見てみよう", "作物が育ち、厨房で料理を作り、荷車が配給所へ運びます。施設を選ぶと途中の様子が分かります。")
  DiningPlanHint -> ("好きな場所で食事をできます", "食事の場を置けます。道路と建材の費用を見てから、建てるか選べます。")
  DiningUseHint -> ("食事の場の周りを飾れます", "席や鉢、灯りを並べられます。置いた飾りは、街と一緒に保存されます。")
  RoadHint -> ("道路の始点と終点を選びます", "1回で64マスまで計画できます。Escで配置をやめられます。")
  PlacesHint -> ("地面をクリックして飾ります", "Rで回転できます。置き直す時は「片づける」で外してから、もう一度置きます。")
  DeliveryHint -> ("届け先の備蓄を調整できます", "＋/−で目標量を変えます。運搬中の物資も見込んで補充します。")
  CrewsHint -> ("三つの班が交代で働きます", "施設を選ぶと担当を配置・解除できます。連続生産を止めても、今の仕事は続きます。")
  ResumeHint -> ("保存の内容を見てから再開します", "元の履歴を残し、一時停止で開きます。読み込みの確認中も、遊び方を開けます。")

hintStableId :: HintId -> String
hintStableId hint = case hint of
  WellHint -> "well"
  FarmHint -> "farm"
  KitchenHint -> "kitchen"
  FirstFoodHint -> "first-food"
  DiningPlanHint -> "dining-plan"
  DiningUseHint -> "dining-use"
  RoadHint -> "road"
  PlacesHint -> "places"
  DeliveryHint -> "delivery"
  CrewsHint -> "crews"
  ResumeHint -> "resume"

encodePreferences :: Preferences -> B.ByteString
encodePreferences preferences = B.pack (unlines ["RED-DUNE-NATIVE-UI-PREFERENCES-1", "guides=" ++ if guidesEnabled preferences then "on" else "off", "seen=" ++ intercalate "," (map hintStableId (Set.toAscList (seenHints preferences)))])

decodePreferences :: B.ByteString -> Maybe Preferences
decodePreferences bytes = do
  guard (B.length bytes <= 1024)
  case lines (B.unpack bytes) of
    ["RED-DUNE-NATIVE-UI-PREFERENCES-1", flag, seen] -> do
      enabled <- case flag of "guides=on" -> Just True; "guides=off" -> Just False; _ -> Nothing
      ids <- stripPrefix "seen=" seen
      let names = if null ids then [] else splitIds ids
      guard (length names == length (nub names))
      hints <- mapM (\name -> lookup name [(hintStableId hint, hint) | hint <- [minBound .. maxBound]]) names
      pure (Preferences enabled (Set.fromList hints))
    _ -> Nothing
  where
    splitIds input = let (name, rest) = break (== ',') input in name : case rest of [] -> []; _ : tailValue -> splitIds tailValue
