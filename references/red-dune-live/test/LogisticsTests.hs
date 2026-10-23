module Main where

import Logistics.InventoryTests (inventoryTests)
import Logistics.MaintenanceTests (maintenanceTests)
import Logistics.TransportTests (transportTests)
import Logistics.WorkforceTests (workforceTests)
import RedDune.ContentPack (defaultPack, packEconomy)

main :: IO ()
main = do
  let content = packEconomy defaultPack
  inventoryTests content
  transportTests content
  maintenanceTests content
  workforceTests
  putStrLn "LIVE_LOGISTICS PASS: atomic retries, dispatch accounting, physical cancellation and duty authority"
