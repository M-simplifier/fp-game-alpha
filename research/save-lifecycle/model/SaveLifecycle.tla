------------------------- MODULE SaveLifecycle -------------------------
EXTENDS Naturals, FiniteSets, Sequences
CONSTANTS EpochCount, IdCount, CheckEpoch, CheckActive, CheckPersist
Epochs == 0..(EpochCount-1)
Ids == 1..IdCount
Requests == 1..(EpochCount*IdCount)
EpochOf(r) == (r-1) \div IdCount
IdOf(r) == ((r-1) % IdCount)+1
VARIABLES epoch, branch, revision, active, phase, captured, capturedBranch,
          accepted, acceptedEpoch, receipt, saved, event, request
vars == <<epoch, branch, revision, active, phase, captured, capturedBranch,
          accepted, acceptedEpoch, receipt, saved, event, request>>
Init == /\ epoch = 0 /\ branch = 0 /\ revision = 0 /\ active = 0
        /\ phase = [r \in Requests |-> "unused"]
        /\ captured = [r \in Requests |-> 0]
        /\ capturedBranch = [r \in Requests |-> 0]
        /\ accepted = [r \in Requests |-> 0]
        /\ acceptedEpoch = [r \in Requests |-> 0]
        /\ receipt = 0 /\ saved = FALSE /\ event = "Init" /\ request = 0
Start(r) ==
 /\ EpochOf(r) = epoch /\ active = 0 /\ phase[r] = "unused"
 /\ active' = IdOf(r) /\ phase' = [phase EXCEPT ![r] = "writing"]
 /\ captured' = [captured EXCEPT ![r] = revision]
 /\ capturedBranch' = [capturedBranch EXCEPT ![r] = branch]
 /\ event' = "Start" /\ request' = r
 /\ UNCHANGED <<epoch, branch, revision, accepted, acceptedEpoch, receipt, saved>>
Persist(r) ==
 /\ phase[r] = "writing" /\ phase' = [phase EXCEPT ![r] = "persisted"]
 /\ event' = "Persist" /\ request' = r
 /\ UNCHANGED <<epoch, branch, revision, active, captured, capturedBranch, accepted, acceptedEpoch, receipt, saved>>
Fail(r) ==
 /\ phase[r] = "writing" /\ phase' = [phase EXCEPT ![r] = "failed"]
 /\ event' = "Fail" /\ request' = r
 /\ UNCHANGED <<epoch, branch, revision, active, captured, capturedBranch, accepted, acceptedEpoch, receipt, saved>>
Matches(r) == capturedBranch[r] = branch /\ (IF CheckEpoch THEN EpochOf(r) = epoch ELSE TRUE)
              /\ (IF CheckActive THEN active = IdOf(r) ELSE TRUE)
Callback(r) ==
 /\ phase[r] \in (IF CheckPersist THEN {"persisted", "failed"} ELSE {"writing", "persisted", "failed"})
 /\ LET ok == Matches(r)
        success == phase[r] # "failed"
    IN /\ active' = IF ok THEN 0 ELSE active
       /\ accepted' = IF ok /\ success THEN [accepted EXCEPT ![r] = IF @ < 2 THEN @+1 ELSE 2] ELSE accepted
       /\ acceptedEpoch' = IF ok /\ success THEN [acceptedEpoch EXCEPT ![r] = epoch] ELSE acceptedEpoch
       /\ receipt' = IF ok /\ success THEN r ELSE receipt
       /\ saved' = IF ok /\ success THEN captured[r] = revision ELSE saved
 /\ event' = "Callback" /\ request' = r
 /\ UNCHANGED <<epoch, branch, revision, phase, captured, capturedBranch>>
Drop(r) ==
 /\ phase[r] \in {"persisted", "failed"}
 /\ event' = "Drop" /\ request' = r
 /\ UNCHANGED <<epoch, branch, revision, active, phase, captured, capturedBranch, accepted, acceptedEpoch, receipt, saved>>
Edit ==
 /\ revision = 0 /\ revision' = 1 /\ saved' = FALSE
 /\ event' = "Edit" /\ request' = 0
 /\ UNCHANGED <<epoch, branch, active, phase, captured, capturedBranch, accepted, acceptedEpoch, receipt>>
Advance(kind) ==
 /\ epoch+1 \in Epochs /\ epoch' = epoch+1
 /\ branch' = IF kind = "NewBranch" THEN 1 ELSE branch
 /\ revision' = 0 /\ active' = 0 /\ receipt' = 0 /\ saved' = FALSE
 /\ event' = kind /\ request' = 0
 /\ UNCHANGED <<phase, captured, capturedBranch, accepted, acceptedEpoch>>
Next == (\E r \in Requests : Start(r) \/ Persist(r) \/ Fail(r) \/ Callback(r) \/ Drop(r))
        \/ Edit \/ Advance("Load") \/ Advance("NewBranch")
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ (\A r \in Requests : WF_vars(Persist(r) \/ Fail(r)) /\ WF_vars(Callback(r)))
TypeOK == /\ epoch \in Epochs /\ branch \in 0..1 /\ revision \in 0..1
          /\ active \in 0..IdCount /\ receipt \in 0..(EpochCount*IdCount)
          /\ phase \in [Requests -> {"unused", "writing", "persisted", "failed"}]
          /\ captured \in [Requests -> 0..1] /\ capturedBranch \in [Requests -> 0..1]
          /\ acceptedEpoch \in [Requests -> Epochs]
          /\ accepted \in [Requests -> 0..2] /\ saved \in BOOLEAN
NoStaleSaved == saved => receipt # 0 /\ EpochOf(receipt) = epoch /\ capturedBranch[receipt] = branch
NoStaleAcceptance == \A r \in Requests : accepted[r] > 0 => acceptedEpoch[r] = EpochOf(r)
NoFalseSuccess == \A r \in Requests : accepted[r] > 0 => phase[r] = "persisted"
UniqueResponse == \A r \in Requests : accepted[r] <= 1
SavedSnapshotMatches == saved => receipt # 0 /\ captured[receipt] = revision
ActiveCorresponds == active # 0 => \E r \in Requests : EpochOf(r) = epoch /\ IdOf(r) = active /\ phase[r] # "unused"
StorageSettles == \A r \in Requests : (phase[r] = "writing") ~> (phase[r] \in {"persisted", "failed"})
ActiveSettles == (active # 0) ~> (active = 0)
=============================================================================
