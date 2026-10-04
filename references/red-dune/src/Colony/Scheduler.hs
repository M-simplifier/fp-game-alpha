module Colony.Scheduler(pureStep,runPhases) where
import qualified Colony.SchedulerCore as Base
import Colony.M1Scheduler(runM1Phases)
import Colony.World
pureStep :: NativeInput -> World -> (World,ColonyOutput)
pureStep=Base.pureStepWith runPhases
runPhases :: NativeInput -> World -> Base.Checked Base.Staged
runPhases native world=case worldM1 world of
  Nothing->Base.runPhases native world
  Just _->runM1Phases native world
