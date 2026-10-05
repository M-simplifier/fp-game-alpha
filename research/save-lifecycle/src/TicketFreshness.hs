module Main where
import Colony.Save
import Colony.Types (Epoch(..))
import Control.Monad (unless)
import System.Exit (die)
main :: IO ()
main = do
 let identity = SaveIdentity 1 1 (Epoch "freshness-probe" 0)
     ticket = SaveTicket identity 1 ManualSave
     (firstAdmission,q1) = enqueueSave ticket (emptySaveQueue identity)
     (firstFinish,q2) = finishSave ticket q1
     (secondAdmission,q3) = enqueueSave ticket q2
     (oldDuplicateAccepted,_) = finishSave ticket q3
 unless (firstAdmission == Started && firstFinish && secondAdmission == Started) (die "probe precondition failed")
 print ("same-full-ticket-reused",oldDuplicateAccepted)
