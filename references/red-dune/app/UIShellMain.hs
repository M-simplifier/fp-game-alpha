module Main(main) where
import Colony.Content(loadContent)
import Colony.UIShell(runUIShell)
main :: IO()
main=loadContent "data/content-v1.json" >>= either fail runUIShell
