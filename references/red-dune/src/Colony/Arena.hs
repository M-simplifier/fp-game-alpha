{-# LANGUAGE TypeFamilies, DeriveGeneric, DeriveAnyClass, NoGeneralizedNewtypeDeriving #-}
module Colony.Arena where
import Colony.Jobs
import Colony.M1View
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq(NFData)
import Control.Monad(unless,foldM)
import qualified Data.Map.Strict as M
import Data.List(sort)
import Data.Word(Word64)
import Game.Transition
import Game.Arena
import GHC.Generics(Generic)

data Colony = Colony deriving(Eq,Show)
newtype OrderedBatch = OrderedBatch [OrderedCommand] deriving(Eq,Show,Read,Generic,NFData)
data RecordedBoundary = RecordedBoundary BoundaryHeader [CommandId] [ManagementEvent] deriving(Eq,Show,Read,Generic,NFData)
data AdmissionError = AdmissionError String deriving(Eq,Show,Read,Generic,NFData)
data StockView = StockView {stockPhysical :: !Integer,stockReserved :: !Integer} deriving(Eq,Show,Read,Generic,NFData)
data JobView = JobView EntityId String JobPhase (Maybe Failure) Integer Integer deriving(Eq,Show,Read,Generic,NFData)
data ColonyView = ColonyView
  {viewTick :: !SimTick,viewBoundary :: !BoundarySeq,viewMode :: !CoreMode
  ,viewStock :: !(M.Map (Owner,Resource) StockView),viewJobs :: ![JobView],viewKnownParticipant :: !Bool}
  | ColonyViewM1
  {viewTick :: !SimTick,viewBoundary :: !BoundarySeq,viewMode :: !CoreMode
  ,viewStock :: !(M.Map (Owner,Resource) StockView),viewJobs :: ![JobView],viewKnownParticipant :: !Bool
  ,viewM1 :: !M1PublicView}
  deriving(Eq,Show,Read,Generic,NFData)

instance Machine Colony where
  type State Colony=World
  type Input Colony=NativeInput
  type Output Colony=ColonyOutput
  machine _=Step pureStep

instance Arena Colony where
  type Agent Colony=Word64
  type Action Colony=OrderedBatch
  type Context Colony=RecordedBoundary
  type View Colony=ColonyView
  type Rejection Colony=AdmissionError
  observe _ participant w=case worldM1 w of
    Nothing->ColonyView(simTick w)(boundarySeq w)(worldMode w)stock jobs known
    Just extra->ColonyViewM1(simTick w)(boundarySeq w)(worldMode w)stock jobs known(observeM1(worldNeeds w)extra)
    where
      known=M.member participant(worldParticipants w)
      inv=worldInventory w
      physical=M.fromListWith(+)[((lotOwner l,lotResource l),qtyValue(lotQty l))|l<-M.elems(invLots inv)]
      reserved=M.fromListWith(+)[((lotOwner l,lotResource l),qtyValue(quantityAmount r))|r<-M.elems(invQuantity inv),Just l<-[M.lookup(quantityLot r)(invLots inv)]]
      stock=M.mapWithKey(\key n->StockView n(M.findWithDefault 0 key reserved))physical
      jobs=[JobView(jobId j)(jobRecipe j)(jobPhase j)(jobBlocked j)(jobProgress j)(jobRequired j)|j<-M.elems(worldJobs w)]
  admit _ (RecordedBoundary header order management) choices w=do
    let check b msg=unless b(Left(AdmissionError msg))
        submitted=submissions choices
        allCommands=concat[cs|(_,OrderedBatch cs)<-submitted]
        ids=map commandId allCommands
    check(headerAuthority header==worldAuthority w && headerWorld header==worldId w && headerBranch header==branchId w) "authority/world mismatch"
    check(headerRuleset header==worldRuleset w) "ruleset mismatch"
    check(expectedBoundarySeq header==boundarySeq w) "boundary sequence mismatch"
    check(all(commandAllowedInRuleset(worldRuleset w).commandBody)allCommands) "command vocabulary/profile mismatch"
    check(length allCommands<=256) "boundary command limit"
    check(M.size(M.fromList(zip ids(repeat())))==length ids) "duplicate command identity"
    check(sort ids==sort order && length ids==length order) "context/order does not correspond one-to-one to batches"
    mapM_ (validateBatch check) submitted
    mapM_ (\(_,OrderedBatch cs)->check(map commandId cs==filter(`elem`map commandId cs)order) "context changed participant batch order") submitted
    let byId=M.fromList[(commandId c,c)|c<-allCommands]
    ordered<-mapM(\ident->maybe(Left(AdmissionError "missing ordered command"))Right(M.lookup ident byId))order
    check(map commandOrdinal ordered==take(length ordered)[0..]) "global ordinals disagree with context"
    _<-foldM(sequenceCheck check)(worldHighWater w)ordered
    pure(Boundary header ordered management)
    where
      validateBatch check (participant,OrderedBatch commands)=do
        p<-maybe(Left(AdmissionError "unknown participant"))Right(M.lookup participant(worldParticipants w))
        check(length commands<=64) "participant command limit"
        check(null commands || participantRole p/=ViewerRole) "viewer mutation"
        let sequences=[n|c<-commands,let CommandId wid controller epoch n=commandId c, wid==worldId w && controller==participant && epoch==participantEpoch p]
        check(length sequences==length commands) "command controller/epoch mismatch"
        check(and(zipWith(\a b->a<maxBound && b==a+1)sequences(drop 1 sequences))) "batch sequence duplicate or gap"
      sequenceCheck check water command=do
        let CommandId _ controller epoch n=commandId command
            highest=M.findWithDefault 0(controller,epoch)water
        check(n<=highest || (highest<maxBound && n==highest+1)) "NeedSequence"
        case [r|r<-worldReceipts w,receiptCommand r==commandId command] of
          r:_->check(receiptBody r==commandBody command) "SequenceCollision"
          []->pure()
        pure(M.insert(controller,epoch)(max n highest)water)
