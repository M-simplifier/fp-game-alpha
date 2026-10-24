module RedDune.Protocol where

import Colony.JSON qualified as J
import Colony.Presentation
import Colony.Space qualified as Space
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Monad (unless)
import Data.Map.Strict qualified as M
import Data.Word (Word64)
import Text.Read (readMaybe)

getString :: String -> M.Map String J.JSON -> Either String String
getString k o = J.field k o >>= J.string

getWord :: String -> M.Map String J.JSON -> Either String Word64
getWord k o = do
  value <- getString k o
  if null value || length value > 20 || any (\c -> c < '0' || c > '9') value || length value > 1 && head value == '0'
    then Left ("Invalid canonical decimal: " ++ k)
    else case (readMaybe value :: Maybe Integer) of
      Just n | n >= 0 && n <= toInteger (maxBound :: Word64) -> Right (fromInteger n)
      _ -> Left ("Word64 range: " ++ k)

getQuantity :: String -> M.Map String J.JSON -> Either String Integer
getQuantity k o = do
  value <- getString k o
  n <- maybe (Left ("Invalid quantity: " ++ k)) Right (readMaybe value)
  if show n /= value || n < 0 || n > quantityMax then Left ("Quantity range: " ++ k) else pure n

getId :: World -> String -> M.Map String J.JSON -> Either String EntityId
getId w k o = do
  n <- getWord k o
  if n == 0 || n >= invNextId (worldInventory w) then Left "Unknown future entity ID" else pure (EntityId n)

getOwner :: World -> String -> M.Map String J.JSON -> Either String Owner
getOwner w k o = do
  value <- getString k o
  case [owner | owner <- M.keys (invStorage (worldInventory w)), ownerKey owner == value] of
    [owner] -> Right owner
    _ -> Left ("Unknown owner: " ++ k)

decodeUICommand :: World -> J.JSON -> Either String Command
decodeUICommand w input = do
  fields <- J.object input
  kind <- getString "kind" fields
  case kind of
    "produce" -> exact ["kind", "site"] fields >> OrderProduction <$> getId w "site" fields
    "cancelProduction" -> exact ["kind", "job"] fields >> CancelProduction <$> getId w "job" fields
    "siteEnabled" -> do exact ["kind", "site", "enabled"] fields; SetSiteEnabled <$> getId w "site" fields <*> (J.field "enabled" fields >>= J.boolean)
    "deliver" -> do
      exact ["kind", "source", "destination", "resource", "quantity", "priority"] fields
      resource <- getString "resource" fields >>= parseResource
      quantity <- getQuantity "quantity" fields
      priority <- getQuantity "priority" fields
      unless (quantity > 0 && priority <= 3) (Left "Delivery quantity must be positive and priority 0..3")
      RequestDelivery <$> getOwner w "source" fields <*> getOwner w "destination" fields <*> pure resource <*> pure quantity <*> pure priority
    "cancelDelivery" -> exact ["kind", "request"] fields >> CancelDelivery <$> getId w "request" fields
    "maintenance" -> exact ["kind", "target", "source", "return"] fields >> RequestMaintenance <$> getId w "target" fields <*> getOwner w "source" fields <*> getOwner w "return" fields
    "cancelMaintenance" -> exact ["kind", "job"] fields >> CancelFacilityMaintenance <$> getId w "job" fields
    "placePlan" -> do
      exact ["kind", "colony", "prototype", "x", "y", "rotation", "priority", "source"] fields
      colony <- getId w "colony" fields
      prototype <- getString "prototype" fields
      x <- getQuantity "x" fields
      y <- getQuantity "y" fields
      priority <- getQuantity "priority" fields
      unless (x < 512 && y < 512 && priority <= 3) (Left "Placement tile/priority outside bounds")
      rotationName <- getString "rotation" fields
      rotation <- case rotationName of "R0" -> Right Space.R0; "R90" -> Right Space.R90; "R180" -> Right Space.R180; "R270" -> Right Space.R270; _ -> Left "Unknown rotation"
      sourceValue <- J.field "source" fields
      source <- case sourceValue of J.JNull -> Right Nothing; _ -> Just <$> getId w "source" fields
      shape <-
        if prototype == "road"
          then do
            unless (rotation == Space.R0 && source == Nothing) (Left "Road requires R0 and no natural source")
            Right (Space.RoadShape (Space.Tile x y))
          else Right (Space.BuildingShape prototype (Space.Tile x y) rotation)
      Right (PlaceConstructionPlan colony shape priority source)
    "cancelPlan" -> do
      exact ["kind", "site", "revision"] fields
      CancelConstructionPlan <$> getId w "site" fields <*> getWord "revision" fields
    "assignWorkers" -> do
      exact ["kind", "target", "shift", "residents"] fields
      targetFields <- J.field "target" fields >>= J.object
      exact ["kind", "id"] targetFields
      identValue <- getId w "id" targetFields
      targetKind <- getString "kind" targetFields
      target <- case targetKind of
        "facility" -> Right (W.OperateFacility identValue)
        "construction" -> Right (W.ConstructSite identValue)
        "maintenance" -> Right (W.MaintainJob identValue)
        "vehicle" -> Right (W.DriveVehicle identValue)
        _ -> Left "Unknown workforce target kind"
      shift <- getQuantity "shift" fields
      unless (shift <= 2) (Left "Shift outside0..2")
      residents <- J.field "residents" fields >>= J.array
      unless (length residents <= 256) (Left "Workforce roster exceeds256 names")
      names <- mapM (\value -> getId w "resident" (M.singleton "resident" value)) residents
      Right (AssignWorkers target shift names)
    _ -> Left "Unknown command kind"
  where
    exact = J.fieldsExactly

commandFromRequest :: World -> M.Map String J.JSON -> Either String OrderedCommand
commandFromRequest w request = do
  controller <- getWord "controller" request
  wid <- getWord "world" request
  seqNo <- getWord "sequence" request
  unless (seqNo > 0) (Left "Command sequence starts at 1")
  ep <- J.field "epoch" request >>= J.object
  J.fieldsExactly ["authority", "generation"] ep
  epoch <- Epoch <$> getString "authority" ep <*> getWord "generation" ep
  command <- J.field "command" request >>= decodeUICommand w
  pure (OrderedCommand 0 (CommandId wid controller epoch seqNo) command)

-- Archived epochs may be exhausted without exhausting the fresh active session.
nextLocalCommandSequence :: World -> Either String Word64
nextLocalCommandSequence w = do
  participant <- maybe (Left "Local controller is absent") Right (M.lookup 1 (worldParticipants w))
  let current = M.findWithDefault 0 (1, participantEpoch participant) (worldHighWater w)
  if current == maxBound then Left "Command sequence exhausted" else Right (current + 1)

previewEnvelope :: World -> J.JSON -> J.JSON
previewEnvelope w command = obj [("op", str "command"), ("world", num (worldId w)), ("controller", num (1 :: Integer)), ("epoch", epochJSON epoch), ("sequence", num (sequenceNo)), ("boundary", boundaryJSON (boundarySeq w)), ("command", command)]
  where
    epoch = maybe (Epoch "invalid" 0) participantEpoch (M.lookup 1 (worldParticipants w)); sequenceNo = either (const 0) id (nextLocalCommandSequence w)
