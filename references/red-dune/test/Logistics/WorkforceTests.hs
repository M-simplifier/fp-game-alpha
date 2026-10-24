module Logistics.WorkforceTests (workforceTests) where

import Colony.Needs
import Colony.Types
import Colony.Workforce
import Control.DeepSeq (force)
import Control.Monad (unless)
import Data.Map.Strict qualified as M

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

workforceTests :: IO ()
workforceTests = do
  let person = EntityId 2
      colony = EntityId 1
      target = MaintainJob (EntityId 3)
      ns = NeedsState (M.singleton person ((newResident person colony) {residentShift = 0})) M.empty
      context = TickContext (SimTick 1) 0
      catalog = M.singleton target (TargetRequirement colony 1 MaintainerRole (Just MaintainSkill) False)
      base = initialWorkforce (SimTick 0) ns
      experience wf = skillExperience <$> (M.lookup person (workforceWorkers wf) >>= M.lookup MaintainSkill . workerSkills)
  assigned <- must (assignWorkers catalog ns target 0 [person] base)
  (claimed, _) <- must (claimCrew context catalog ns assigned target)
  held <- must (captureHeldDuty context catalog ns claimed target [person])
  credited <- must (captureCreditedDuty context catalog ns claimed target [person] 1)
  (_, ordinary, _) <- must (advanceWorkforce PositiveCreditElapsedTick context catalog ns claimed (M.singleton target held))
  unless (experience ordinary == Just 0 && dutyCredit held == Nothing) $
    fail "held duty fabricated experience without positive credited work"
  merged <- must (recordDuty held M.empty >>= recordDuty credited >>= recordDuty credited)
  (_, finished, _) <- must (advanceWorkforce PositiveCreditElapsedTick context M.empty ns (retireTarget target claimed) merged)
  unless (experience finished == Just 1 && M.null (workforceClaims finished)) $
    fail "same-tick phase observations doubled XP, or terminal release lost real duty"
  unless (case captureCreditedDuty context catalog ns assigned target [person] 130 of Left (WorkforceInvariant _) -> True; _ -> False) $
    fail "credited evidence can be created without a live claim"
  unless (case advanceWorkforce PositiveCreditElapsedTick context catalog ns ordinary M.empty of Left (InvalidWorkforceInput _) -> True; _ -> False) $
    fail "one elapsed tick was accounted twice"
  let expected = "DutyEvidence {dutyTick = SimTick 1, dutyTarget = MaintainJob (EntityId 3), dutyRequirement = TargetRequirement {targetColony = EntityId 1, targetRequiredPeople = 1, targetRole = MaintainerRole, targetSkill = Just MaintainSkill, targetRemovalBusy = False}, dutyCrew = [EntityId 2], dutyCredit = Nothing}"
  unless (show (force held) == expected && showsPrec 11 held "" == "(" ++ expected ++ ")") $
    fail "opaque duty queries/NFData changed the established diagnostic Show text"
  unless ((dutyTick held, dutyTarget held, dutyCrew held) == (SimTick 1, target, [person])) $
    fail "legitimate duty observation API changed"
  putStrLn "Workforce: held evidence earns no XP; exact live claims grant credit; phase merge and terminal release account once"
