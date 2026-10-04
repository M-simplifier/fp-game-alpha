{-# LANGUAGE BangPatterns #-}
module M1StateMachineTests(main,m1StateMachineTests) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import qualified Colony.Construction as C
import Colony.M1State
import Colony.RNG(initialRng)
import Colony.S01Fixture
import Colony.Scheduler
import qualified Colony.Space as S
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import M1DriverTests(assert,must,m1)
import Control.Monad(foldM,forM_)
import qualified Data.Map.Strict as M
import Data.Word(Word64)
import Game.Arena(play,singleton,observe)

-- Test-generator arithmetic alone wraps Word64. It never draws game RNG.
nextRandom :: Word64 -> Word64
nextRandom seed=seed*6364136223846793005+1442695040888963407
payload :: World -> World
payload world=world{boundarySeq=BoundarySeq 0,worldRevision=0,worldHighWater=M.empty,worldReceipts=[],worldRecentEvents=[]}
choose :: S01Descriptor -> Word64 -> World -> [Command]
choose d seed world=case seed `mod` 11 of
  0|length plans<16->[PlaceConstructionPlan(s01Colony d)(S.RoadShape(S.Tile(58+toInteger((seed `div`11)`mod`5))(66+toInteger((seed `div`55)`mod`5))))2 Nothing]
  1->case plans of p:_->[CancelConstructionPlan(C.constructionSiteId p)(C.constructionRevision p)];_->[]
  2->case plans of p:_->[CancelConstructionPlan(C.constructionSiteId p)(C.constructionRevision p+1)];_->[]
  3->[AssignWorkers(W.OperateFacility(s01Pump d))0[]]
  4->[AssignWorkers(W.OperateFacility(s01Pump d))0(take 2(drop 6(s01ShiftResidents d M.!0)))]
  5->[AssignWorkers(W.OperateFacility(s01Farm d))0[two,two]]
  6->[RequestDelivery(head(s01Warehouses d))(s01Pantry d)Water 10 2]
  7->[RequestDelivery(head(s01Warehouses d))(s01Pantry d)Stone 0 2]
  8->[OrderProduction(s01Pump d)]
  9->[SetSiteEnabled(s01Pump d)(even(seed `div`11))]
  _->[AssignWorkers(W.DriveVehicle(head(s01Carts d)))0[two]]
  where
    plans=reverse(M.elems(C.constructionJobs(m1Construction(m1 world))))
    two=head(s01ShiftResidents d M.!1)

m1StateMachineTests :: Content -> IO()
m1StateMachineTests content=forM_[1..8::Word64]$ \seed->do
  (descriptor,initial)<-must "S01 model seed"(s01Fixture content)
  (final,_,rejections,snapshots)<-foldM(run descriptor)(initial,seed,0::Integer,0::Integer)[0..399::Integer]
  assert "mixed invalid commands actually exercised"(rejections>40&&snapshots>=10)
  must "final state machine world valid"(validateWorld final)
  putStrLn("M1_STATE_MACHINE seed="++show seed++" boundaries=400 rejected="++show rejections++" CBOR-resumes="++show snapshots++" PASS")
  where
    run descriptor(!world,randomValue,failures,snapshots) index=do
      let randomNext=nextRandom randomValue
          management=if index==0||index `mod`47==0 then[ResumeWorld]else if index `mod`43==0 then[PauseWorld]else[]
          advance=null management&&worldMode world==Active&&index `mod`3==0
          bodies=choose descriptor randomNext world
          epoch=participantEpoch(worldParticipants world M.!1)
          high=M.findWithDefault 0(1,epoch)(worldHighWater world)
          ordered=[OrderedCommand n(CommandId 1 1 epoch(high+n+1))body|(n,body)<-zip[0..]bodies]
          header=BoundaryHeader 1 1(boundarySeq world)advance(worldAuthority world)(worldRuleset world)
          native=Boundary header ordered management
          direct=pureStep native world
      encoded<-must "actual native input codec"(encodeNativeInput native)
      decoded<-must "actual native input decode"(decodeNativeInput encoded)
      throughArena<-must "actual mixed Arena admission"(play Colony(RecordedBoundary header(map commandId ordered)management)(singleton 1(OrderedBatch ordered))world)
      assert "mixed direct/admit/codec parity"(decoded==native&&throughArena==direct)
      let (next,out)=direct
          failed=length[()|receipt<-outputReceipts out,CommandFailed _<-[receiptOutcome receipt]]
      assert("mixed valid-world input never faults: "++show(index,bodies,outputDiagnostics out))(null(outputDiagnostics out))
      if not advance&&null management&&failed>0 then assert "failed command atomically preserves all gameplay payload"(payload next==payload world)else pure()
      assert "public M1 observation excludes private RNG state"(observe Colony 1 next==observe Colony 1 next{worldRng=initialRng 999})
      resumed<-if index `mod`31==0 then do
          bytes<-must "mixed checkpoint"(encodeCheckpoint(CheckpointMeta(fromInteger index)Nothing "m1-state-machine")next)
          (_,restored)<-must "mixed checkpoint reload"(decodeCheckpoint bytes)
          assert "mixed save exact"(restored==next)
          pure restored
        else pure next
      -- Every37th step probes a whole-boundary rejection, without consuming a
      -- sequence or touching the real current World used by the next transition.
      if index `mod`37==0 then do
          let bad=Boundary header{expectedBoundarySeq=BoundarySeq maxBound}ordered management
              (unchanged,rejected)=pureStep bad world
          assert "bad boundary leaves exact original world"(unchanged==world&&null(outputReceipts rejected)&&null(outputEvents rejected)&&not(null(outputDiagnostics rejected)))
        else pure()
      pure(resumed,randomNext,failures+toInteger failed,snapshots+if index `mod`31==0 then 1 else 0)
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1StateMachineTests
