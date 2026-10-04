module M1Tests(m1Tests) where
import Colony.Content(Content)
import ConstructionTests(constructionTests)
import SpaceTests(spaceTests)
import WorkforceTests(workforceTests)
import M1SchemaTests(m1SchemaTests)
import M1DriverTests(m1DriverTests)
import M1PickupTests(m1PickupTests)
import M1CacheTests(m1CacheTests)
import M1IntegrityTests(m1IntegrityTests)
import M1BoundaryTests(m1BoundaryTests)
import M1StateMachineTests(m1StateMachineTests)
import S01PlayerTests(s01PlayerTests)
m1Tests :: Content -> IO()
m1Tests content=do
  spaceTests content
  workforceTests
  constructionTests content
  m1SchemaTests content
  m1IntegrityTests content
  m1DriverTests content
  m1PickupTests content
  m1BoundaryTests content
  m1StateMachineTests content
  m1CacheTests content
  s01PlayerTests content
  putStrLn "M1_0.6_AGGREGATE PASS: bounded construction/workforce/spatial/pickup integration; remaining M1/campaign/browser gates are not implied complete"
