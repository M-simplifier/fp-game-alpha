{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Schema4-only workforce adjuncts. Needs remains the sole owner of residents,
-- health, shifts, beds and the integer fatigue meter. No World dependency.
--
-- Integration: reconcile before phase admission, claim exact named crews, feed
-- one combined duty map to advanceWorkforce at P8, then apply Needs consumption
-- and health WITHOUT legacy shift-based fatigue. Reconcile once more after
-- health changes. Paused boundaries do not call advanceWorkforce. Terminal work
-- releases claims; destroyed/terminal assignment targets use retireTarget.
module Colony.Workforce
  ( WorkTarget (..),
    Skill (..),
    WorkRole (..),
    SkillProgress (..),
    WorkerAdjunct (..),
    WorkforceState (..),
    TargetRequirement (..),
    TargetCatalog,
    TickContext (..),
    CrewView (..),
    DutyEvidence,
    dutyTick,
    dutyTarget,
    dutyCrew,
    dutyCredit,
    ExperiencePolicy (..),
    WorkforceDelta (..),
    WorkforceError (..),
    workforceFailure,
    allSkills,
    initialWorkforce,
    validateWorkforce,
    assignWorkers,
    forcedRestActive,
    eligibleResident,
    observeCrew,
    crewReady,
    claimCrew,
    crewCredit,
    releaseTargetClaims,
    retireTarget,
    reconcileClaims,
    captureHeldDuty,
    captureCreditedDuty,
    recordDuty,
    advanceWorkforce,
    checkedFuture,
  )
where

import Colony.Needs (NeedsState (..), Resident (..), ResidentStatus (..))
import Colony.Types (EntityId, Failure (..), SimTick (..))
import Control.DeepSeq (NFData)
import Control.Monad (foldM, forM_, unless, when)
import Data.List (sort)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)

-- Constructor/field order is part of the new, versioned schema4 vocabulary.
data WorkTarget
  = OperateFacility !EntityId
  | ConstructSite !EntityId
  | MaintainJob !EntityId
  | DriveVehicle !EntityId
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data Skill
  = GatherSkill
  | ProcessSkill
  | BuildSkill
  | MaintainSkill
  | TransportSkill
  | ResearchSkill
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, NFData)

data WorkRole = OperatorRole | BuilderRole | MaintainerRole | DriverRole | ServiceRole
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data SkillProgress = SkillProgress {skillLevel :: !Integer, skillExperience :: !Integer}
  deriving (Eq, Show, Read, Generic, NFData)

data WorkerAdjunct = WorkerAdjunct
  { workerRole :: !(Maybe WorkRole),
    workerSkills :: !(M.Map Skill SkillProgress),
    workerFatigueRemainder :: !Integer,
    workerForcedRestUntil :: !(Maybe SimTick)
  }
  deriving (Eq, Show, Read, Generic, NFData)

data WorkforceState = WorkforceState
  { workforceWorkers :: !(M.Map EntityId WorkerAdjunct),
    workforceRosters :: !(M.Map (WorkTarget, Integer) [EntityId]),
    workforceClaims :: !(M.Map EntityId WorkTarget),
    workforceLastAccountedTick :: !SimTick
  }
  deriving (Eq, Show, Read, Generic, NFData)

data TargetRequirement = TargetRequirement
  { targetColony :: !EntityId,
    targetRequiredPeople :: !Integer,
    targetRole :: !WorkRole,
    targetSkill :: !(Maybe Skill),
    targetRemovalBusy :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

type TargetCatalog = M.Map WorkTarget TargetRequirement

data TickContext = TickContext {workforceTick :: !SimTick, workforceShift :: !Integer}
  deriving (Eq, Show, Read, Generic, NFData)

data CrewView = CrewView
  { crewTarget :: !WorkTarget,
    crewAvailable :: ![EntityId],
    crewSelected :: ![EntityId],
    crewRequired :: !Integer
  }
  deriving (Eq, Show, Read, Generic, NFData)

-- Constructor hidden: only phase capture with live claims creates evidence.
-- The strict snapshot survives a same-tick terminal release; it is a transient
-- phase product, not stored separately as a second assignment authority.
data DutyEvidence = DutyEvidence
  { dutyTick :: !SimTick,
    dutyTarget :: !WorkTarget,
    dutyRequirement :: !TargetRequirement,
    dutyCrew :: ![EntityId],
    dutyCredit :: !(Maybe Integer)
  }
  deriving (Eq, Show, Generic, NFData)

-- A required explicit profile policy, not an assertion that 1.0.1 resolved XP.
data ExperiencePolicy = PositiveCreditElapsedTick
  deriving (Eq, Show, Read, Generic, NFData)

data WorkforceDelta = WorkforceDelta
  { newlyForcedRest :: ![EntityId],
    expiredForcedRest :: ![EntityId],
    skillLevelChanges :: ![(EntityId, Skill)]
  }
  deriving (Eq, Show, Read, Generic, NFData)

data WorkforceError
  = UnknownWorker !EntityId
  | UnknownTarget !WorkTarget
  | DuplicateWorkers
  | WrongWorkerShift !EntityId
  | WrongWorkerColony !EntityId
  | WorkerAlreadyAssigned !EntityId !WorkTarget
  | Busy !WorkTarget
  | WorkforceCounterOverflow
  | InvalidWorkforceInput !String
  | WorkforceInvariant !String
  deriving (Eq, Show, Read, Generic, NFData)

workforceFailure :: WorkforceError -> Failure
workforceFailure WorkforceCounterOverflow = CounterOverflow
workforceFailure (WorkforceInvariant detail) = InvariantViolation detail
workforceFailure (UnknownTarget _) = TargetGone
workforceFailure problem = InvalidReference (show problem)

allSkills :: [Skill]
allSkills = [minBound .. maxBound]

-- No allocator use: every adjunct references a resident already in Needs.
initialWorkforce :: SimTick -> NeedsState -> WorkforceState
initialWorkforce tick ns =
  WorkforceState
    (M.map (const (WorkerAdjunct Nothing (M.fromList [(s, SkillProgress 0 0) | s <- allSkills]) 0 Nothing)) (needsResidents ns))
    M.empty
    M.empty
    tick

count :: [a] -> Integer
count = foldr (const (+ 1)) 0

checkInput :: Bool -> String -> Either WorkforceError ()
checkInput condition detail = unless condition (Left (InvalidWorkforceInput detail))

checkInvariant :: Bool -> String -> Either WorkforceError ()
checkInvariant condition detail = unless condition (Left (WorkforceInvariant detail))

lookupRequirement :: TargetCatalog -> WorkTarget -> Either WorkforceError TargetRequirement
lookupRequirement catalog target = maybe (Left (UnknownTarget target)) Right (M.lookup target catalog)

lookupWorker :: NeedsState -> WorkforceState -> EntityId -> Either WorkforceError (Resident, WorkerAdjunct)
lookupWorker ns wf ident = do
  resident <- maybe (Left (UnknownWorker ident)) Right (M.lookup ident (needsResidents ns))
  worker <- maybe (Left (UnknownWorker ident)) Right (M.lookup ident (workforceWorkers wf))
  pure (resident, worker)

validateContext :: TickContext -> Either WorkforceError ()
validateContext context = checkInput (workforceShift context >= 0 && workforceShift context <= 2) "active shift outside 0..2"

-- Structural validation deliberately allows stale claims before reconciliation
-- at a new shift, forced-rest expiry or health update. Eligibility is contextual.
validateWorkforce :: TargetCatalog -> NeedsState -> WorkforceState -> Either WorkforceError ()
validateWorkforce catalog ns wf = do
  checkInvariant (M.keysSet (workforceWorkers wf) == M.keysSet (needsResidents ns)) "workforce/resident ID set differs"
  forM_ (M.toList catalog) $ \(target, requirement) -> do
    checkInvariant (targetRequiredPeople requirement > 0) "nonpositive staffing requirement"
    let validRole = case target of
          OperateFacility _ -> targetRole requirement `elem` [OperatorRole, ServiceRole]
          ConstructSite _ -> targetRole requirement == BuilderRole
          MaintainJob _ -> targetRole requirement == MaintainerRole
          DriveVehicle _ -> targetRole requirement == DriverRole
    checkInvariant validRole "target kind/role mismatch"
    checkInvariant (not (targetRemovalBusy requirement) || case target of DriveVehicle _ -> True; _ -> False) "Busy removal on a non-driving target"
  let memberships = [(ident, (target, shift)) | ((target, shift), ids) <- M.toList (workforceRosters wf), ident <- ids]
  checkInvariant (count memberships == count (S.toList (S.fromList (map fst memberships)))) "resident assigned to multiple rosters"
  forM_ (M.toList (workforceRosters wf)) $ \((target, shift), ids) -> do
    requirement <- lookupRequirement catalog target
    checkInvariant (shift >= 0 && shift <= 2) "roster shift outside 0..2"
    checkInvariant (not (null ids) && ids == S.toAscList (S.fromList ids)) "empty, unsorted or duplicate roster"
    forM_ ids $ \ident -> do
      (resident, worker) <- lookupWorker ns wf ident
      checkInvariant (residentShift resident == shift && residentColony resident == targetColony requirement) "roster resident location/shift mismatch"
      checkInvariant (workerRole worker == Just (targetRole requirement)) "resident role/assignment mismatch"
  forM_ (M.toList (workforceWorkers wf)) $ \(ident, worker) -> do
    (resident, _) <- lookupWorker ns wf ident
    checkInvariant (residentId resident == ident) "resident map key mismatch"
    checkInvariant (residentFatigue resident >= 0 && residentFatigue resident <= 1000 && residentHealth resident >= 0 && residentHealth resident <= 1000) "resident meter outside bounds"
    checkInvariant (residentShift resident >= 0 && residentShift resident <= 2) "resident shift outside bounds"
    checkInvariant (workerFatigueRemainder worker >= 0 && workerFatigueRemainder worker < 1200) "fatigue remainder outside bounds"
    checkInvariant (residentFatigue resident < 1000 || workerFatigueRemainder worker == 0) "fatigue remainder above meter maximum"
    case workerForcedRestUntil worker of
      Nothing -> pure ()
      Just (SimTick untilTick) -> do
        let SimTick accounted = workforceLastAccountedTick wf
        checkInvariant (untilTick > accounted && toInteger untilTick <= toInteger accounted + 9600) "forced-rest timer outside remaining8h window"
    checkInvariant (M.keys (workerSkills worker) == allSkills) "missing/extra skill adjunct"
    forM_ (M.elems (workerSkills worker)) $ \progress ->
      checkInvariant (skillLevel progress >= 0 && skillLevel progress <= 3 && skillExperience progress >= 0 && skillExperience progress < 28800 && (skillLevel progress < 3 || skillExperience progress == 0)) "skill level/XP bounds"
    checkInvariant ((workerRole worker /= Nothing) == any ((== ident) . fst) memberships) "unassigned resident role mismatch"
  forM_ (M.toList (workforceClaims wf)) $ \(ident, target) -> do
    (resident, _) <- lookupWorker ns wf ident
    _ <- lookupRequirement catalog target
    checkInvariant (ident `elem` M.findWithDefault [] (target, residentShift resident) (workforceRosters wf)) "claim lacks matching persistent assignment"
  forM_ (M.toList catalog) $ \(target, requirement) ->
    checkInvariant (count (M.keys (M.filter (== target) (workforceClaims wf))) <= targetRequiredPeople requirement) "target has excess active worker claims"

-- Assignment validation concerns identity/colony/shift, not temporary fitness:
-- one may roster an off-shift/resting resident without making them available.
assignWorkers ::
  TargetCatalog ->
  NeedsState ->
  WorkTarget ->
  Integer ->
  [EntityId] ->
  WorkforceState ->
  Either WorkforceError WorkforceState
assignWorkers catalog ns target shift requested wf = do
  validateWorkforce catalog ns wf
  requirement <- lookupRequirement catalog target
  checkInput (shift >= 0 && shift <= 2) "assignment shift outside 0..2"
  when (count requested /= count (S.toList (S.fromList requested))) (Left DuplicateWorkers)
  let key = (target, shift)
      old = M.findWithDefault [] key (workforceRosters wf)
      requestedSet = S.fromList requested
      removed = filter (`S.notMember` requestedSet) old
      other = M.delete key (workforceRosters wf)
      otherAssignments = M.fromList [(ident, otherTarget) | ((otherTarget, _), ids) <- M.toList other, ident <- ids]
  when (targetRemovalBusy requirement && not (null removed)) (Left (Busy target))
  forM_ requested $ \ident -> do
    (resident, _) <- lookupWorker ns wf ident
    unless (residentShift resident == shift) (Left (WrongWorkerShift ident))
    unless (residentColony resident == targetColony requirement) (Left (WrongWorkerColony ident))
    case M.lookup ident otherAssignments of
      Just owner -> Left (WorkerAlreadyAssigned ident owner)
      Nothing -> pure ()
  let ids = sort requested
      rosters = if null ids then other else M.insert key ids other
      roles =
        M.mapWithKey
          ( \ident worker ->
              if ident `elem` ids
                then worker {workerRole = Just (targetRole requirement)}
                else if ident `elem` removed then worker {workerRole = Nothing} else worker
          )
          (workforceWorkers wf)
      -- Removing a held person invalidates this exact crew. Editing another
      -- shift or adding reserve names must not release a moving driver or
      -- preempt a valid, already-bound production crew.
      removesClaim = any (\ident -> M.lookup ident (workforceClaims wf) == Just target) removed
      claims = if removesClaim then M.filter (/= target) (workforceClaims wf) else workforceClaims wf
      next = wf {workforceWorkers = roles, workforceRosters = rosters, workforceClaims = claims}
  validateWorkforce catalog ns next
  pure next

forcedRestActive :: TickContext -> WorkerAdjunct -> Bool
forcedRestActive context worker = maybe False (workforceTick context <) (workerForcedRestUntil worker)

eligibleResident :: TickContext -> TargetRequirement -> Resident -> WorkerAdjunct -> Bool
eligibleResident context requirement resident worker =
  residentStatus resident == Living
    && residentHealth resident > 0
    && residentFatigue resident < 900
    && residentColony resident == targetColony requirement
    && residentShift resident == workforceShift context
    && not (forcedRestActive context worker)

observeCrew ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  Either WorkforceError CrewView
observeCrew context catalog ns wf target = do
  validateContext context
  requirement <- lookupRequirement catalog target
  eligible <-
    fmap concat $
      mapM
        ( \ident -> do
            (resident, worker) <- lookupWorker ns wf ident
            let claimFree = maybe True (== target) (M.lookup ident (workforceClaims wf))
            pure [ident | eligibleResident context requirement resident worker && claimFree]
        )
        (M.findWithDefault [] (target, workforceShift context) (workforceRosters wf))
  let required = targetRequiredPeople requirement
      held = filter (\ident -> M.lookup ident (workforceClaims wf) == Just target) eligible
      free = filter (\ident -> M.lookup ident (workforceClaims wf) /= Just target) eligible
      selected = if count eligible >= required then sort (takeInteger required (held ++ free)) else []
  checkInvariant (required > 0) "nonpositive staffing requirement"
  pure (CrewView target eligible selected required)

-- Bound iteration by the resident list, never by a platform-dependent count.
takeInteger :: Integer -> [a] -> [a]
takeInteger n _ | n <= 0 = []
takeInteger _ [] = []
takeInteger n (x : xs) = x : takeInteger (n - 1) xs

crewReady :: CrewView -> Bool
crewReady view = count (crewSelected view) == crewRequired view && crewRequired view > 0

releaseTargetClaims :: WorkTarget -> WorkforceState -> WorkforceState
releaseTargetClaims target wf = wf {workforceClaims = M.filter (/= target) (workforceClaims wf)}

retireTarget :: WorkTarget -> WorkforceState -> WorkforceState
retireTarget target wf =
  (releaseTargetClaims target wf)
    { workforceRosters = M.filterWithKey (\(owner, _) _ -> owner /= target) (workforceRosters wf),
      workforceWorkers = M.mapWithKey (\ident worker -> if ident `S.member` ids then worker {workerRole = Nothing} else worker) (workforceWorkers wf)
    }
  where
    ids = S.fromList [ident | ((owner, _), members) <- M.toList (workforceRosters wf), owner == target, ident <- members]

-- Reconcile never fabricates replacements and releases only ineligible people.
-- A remaining partial claim is genuine held duty if the caller keeps the job
-- bound; it is NEVER enough for progress. claimCrew explicitly releases the
-- whole group on shortage when the caller chooses to reacquire an exact crew.
reconcileClaims ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  Either WorkforceError WorkforceState
reconcileClaims context catalog ns wf = do
  validateContext context
  retained <- foldM keep M.empty (M.toAscList (workforceClaims wf))
  pure wf {workforceClaims = retained}
  where
    keep accumulated (ident, target) = case M.lookup target catalog of
      Nothing -> pure accumulated
      Just requirement -> do
        (resident, worker) <- lookupWorker ns wf ident
        let assigned = ident `elem` M.findWithDefault [] (target, residentShift resident) (workforceRosters wf)
        pure
          ( if assigned && eligibleResident context requirement resident worker
              then M.insert ident target accumulated
              else accumulated
          )

claimCrew ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  Either WorkforceError (WorkforceState, CrewView)
claimCrew context catalog ns wf target = do
  validateWorkforce catalog ns wf
  view <- observeCrew context catalog ns wf target
  let released = releaseTargetClaims target wf
      next = released {workforceClaims = M.union (M.fromList [(ident, target) | ident <- crewSelected view]) (workforceClaims released)}
  pure (next, view)

-- Each coefficient is an arithmetic mean of per-person integer coefficients,
-- floored independently. There is then ONE floor after the full product.
crewCredit ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  Integer ->
  Integer ->
  Either WorkforceError (CrewView, Integer)
crewCredit context catalog ns wf target weather maintenance = do
  checkInput (weather >= 0 && weather <= 100 && maintenance >= 0 && maintenance <= 100) "external coefficient outside 0..100"
  view <- observeCrew context catalog ns wf target
  requirement <- lookupRequirement catalog target
  if not (crewReady view)
    then pure (view, 0)
    else do
      people <- mapM (lookupWorker ns wf) (crewSelected view)
      coefficients <-
        mapM
          ( \(resident, worker) -> do
              skill <- case targetSkill requirement of
                Nothing -> pure 100
                Just family -> case M.lookup family (workerSkills worker) of
                  Just progress -> do
                    checkInvariant (skillLevel progress >= 0 && skillLevel progress <= 3) "skill outside 0..3"
                    pure (100 + 10 * skillLevel progress)
                  Nothing -> Left (WorkforceInvariant "missing work skill")
              pure (skill, if residentFatigue resident >= 600 then 80 else 100, if residentHealth resident < 500 then 80 else 100)
          )
          people
      let total = crewRequired view
          skillPct = sum [s | (s, _, _) <- coefficients] `div` total
          fatiguePct = sum [f | (_, f, _) <- coefficients] `div` total
          healthPct = sum [h | (_, _, h) <- coefficients] `div` total
          credit = 100 * skillPct * fatiguePct * healthPct * weather * maintenance `div` (100 ^ (5 :: Integer))
      checkInvariant (credit >= 0 && credit <= 130) "work credit outside 0..130"
      pure (view, credit)

-- Capture before terminal release/retirement. Held duty may be a partial
-- claimed crew; only positive credited duty can earn XP and requires the exact
-- full crew used by crewCredit. Evidence is never created by UI or observation.
captureHeldDuty ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  [EntityId] ->
  Either WorkforceError DutyEvidence
captureHeldDuty context catalog ns wf target ids = captureDuty context catalog ns wf target ids Nothing

captureCreditedDuty ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  [EntityId] ->
  Integer ->
  Either WorkforceError DutyEvidence
captureCreditedDuty context catalog ns wf target ids credit = captureDuty context catalog ns wf target ids (Just credit)

captureDuty ::
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  WorkTarget ->
  [EntityId] ->
  Maybe Integer ->
  Either WorkforceError DutyEvidence
captureDuty context catalog ns wf target ids credit = do
  validateContext context
  requirement <- lookupRequirement catalog target
  view <- observeCrew context catalog ns wf target
  checkInput (not (null ids) && ids == S.toAscList (S.fromList ids)) "captured duty crew must be nonempty, unique and sorted"
  case credit of
    Just amount -> do
      checkInput (amount >= 0 && amount <= 130) "duty credit outside 0..130"
      checkInvariant (crewReady view && ids == crewSelected view) "credited duty requires exact complete eligible crew"
    Nothing -> checkInvariant (all (`elem` crewAvailable view) ids) "held duty contains ineligible resident"
  forM_ ids $ \ident -> checkInvariant (M.lookup ident (workforceClaims wf) == Just target) "captured duty resident lacks active claim"
  -- Busy guards the current boundary's roster removal. Arrival can change it
  -- between P4 and P7 without changing the actual duty/XP staffing contract.
  -- Keep every stable requirement field, but exclude this transient guard from
  -- the opaque intraphase snapshot; assignWorkers still reads the real catalog.
  pure (DutyEvidence (workforceTick context) target requirement {targetRemovalBusy = False} ids credit)

-- P4/P7 may both observe the same driver. Merge immutable same-tick evidence;
-- experience is still at most one elapsed tick, never the sum of phase credits.
recordDuty ::
  DutyEvidence ->
  M.Map WorkTarget DutyEvidence ->
  Either WorkforceError (M.Map WorkTarget DutyEvidence)
recordDuty evidence recorded = case M.lookup (dutyTarget evidence) recorded of
  Nothing -> pure (M.insert (dutyTarget evidence) evidence recorded)
  Just previous -> do
    checkInvariant (dutyTick previous == dutyTick evidence && dutyRequirement previous == dutyRequirement evidence) "incompatible phase duty snapshots"
    let ids = S.toAscList (S.fromList (dutyCrew previous ++ dutyCrew evidence))
        credit = case (dutyCredit previous, dutyCredit evidence) of
          (Nothing, value) -> value
          (value, Nothing) -> value
          (Just a, Just b) -> Just (max a b)
    case credit of
      Just _ -> checkInvariant (count ids == targetRequiredPeople (dutyRequirement evidence)) "merged credited duty exceeds required crew"
      Nothing -> pure ()
    pure (M.insert (dutyTarget evidence) (evidence {dutyCrew = ids, dutyCredit = credit}) recorded)

-- One elapsed tick per call, consuming captured real phase evidence even if
-- P7 completed the target and released its claims. Held duty has no XP. A
-- service without a skill family cannot mint XP. Transport timing remains
-- the transport authority; no hidden speed multiplier is supplied here.
advanceWorkforce ::
  ExperiencePolicy ->
  TickContext ->
  TargetCatalog ->
  NeedsState ->
  WorkforceState ->
  M.Map WorkTarget DutyEvidence ->
  Either WorkforceError (NeedsState, WorkforceState, WorkforceDelta)
advanceWorkforce policy context catalog ns wf duties = do
  validateContext context
  validateWorkforce catalog ns wf
  let SimTick lastTick = workforceLastAccountedTick wf
      SimTick tick = workforceTick context
  when (lastTick == maxBound) (Left WorkforceCounterOverflow)
  checkInput (tick == lastTick + 1) "fatigue/XP must advance exactly once per elapsed tick"
  entries <- fmap concat $ mapM validateDuty (M.toList duties)
  checkInvariant (count entries == count (S.toList (S.fromList [ident | (ident, _) <- entries]))) "one resident has multiple duty owners"
  let active = M.fromList entries
  (residents, workers, forced, expired, levels) <-
    foldM
      (advancePerson active)
      (M.empty, M.empty, [], [], [])
      (M.toAscList (needsResidents ns))
  let nextNeeds = ns {needsResidents = residents}
      next = wf {workforceWorkers = workers, workforceLastAccountedTick = workforceTick context}
  reconciled <- reconcileClaims context catalog nextNeeds next
  validateWorkforce catalog nextNeeds reconciled
  pure (nextNeeds, reconciled, WorkforceDelta (reverse forced) (reverse expired) (reverse levels))
  where
    validateDuty (target, evidence) = do
      checkInvariant (target == dutyTarget evidence && dutyTick evidence == workforceTick context) "duty evidence target/tick mismatch"
      let ids = dutyCrew evidence
          credited = maybe False (> 0) (dutyCredit evidence)
          requirement = dutyRequirement evidence
      forM_ ids $ \ident -> do
        _ <- lookupWorker ns wf ident
        pure ()
      pure [(ident, if credited then targetSkill requirement else Nothing) | ident <- ids]
    advancePerson active (residents, workers, forced, expired, levels) (ident, resident) = do
      (_, worker) <- lookupWorker ns wf ident
      let timerExpired = maybe False (<= workforceTick context) (workerForcedRestUntil worker)
          cleared = if timerExpired then worker {workerForcedRestUntil = Nothing} else worker
          excluded = residentStatus resident `elem` [InTransit, Evacuated]
          onDuty = M.member ident active
          rate = if onDuty then 60 else if residentBed resident then -60 else -30
          exact = residentFatigue resident * 1200 + workerFatigueRemainder worker
          nextExact = if excluded then exact else max 0 (min 1200000 (exact + rate))
          (fatigue, remainder) = nextExact `divMod` 1200
          needsRest = not excluded && (residentFatigue resident >= 900 || fatigue >= 900) && not (forcedRestActive context worker)
      restUntil <- if needsRest then Just <$> checkedFuture (workforceTick context) 9600 else pure (workerForcedRestUntil cleared)
      let nextResident = resident {residentFatigue = fatigue}
          advanced = cleared {workerFatigueRemainder = remainder, workerForcedRestUntil = restUntil}
      (nextWorker, changed) <- case (policy, M.lookup ident active) of
        (PositiveCreditElapsedTick, Just (Just family)) -> do
          progress <- maybe (Left (WorkforceInvariant "missing XP skill")) Right (M.lookup family (workerSkills advanced))
          let nextProgress =
                if skillLevel progress == 3
                  then progress
                  else
                    if skillExperience progress == 28799
                      then SkillProgress (skillLevel progress + 1) 0
                      else progress {skillExperience = skillExperience progress + 1}
          pure
            ( advanced {workerSkills = M.insert family nextProgress (workerSkills advanced)},
              [(ident, family) | skillLevel nextProgress /= skillLevel progress]
            )
        _ -> pure (advanced, [])
      pure
        ( M.insert ident nextResident residents,
          M.insert ident nextWorker workers,
          if needsRest then ident : forced else forced,
          if timerExpired then ident : expired else expired,
          reverse changed ++ levels
        )

checkedFuture :: SimTick -> Integer -> Either WorkforceError SimTick
checkedFuture (SimTick tick) offset = do
  checkInput (offset >= 0) "negative future tick offset"
  let future = toInteger tick + offset
  when (future > toInteger (maxBound :: Word64)) (Left WorkforceCounterOverflow)
  pure (SimTick (fromInteger future))
