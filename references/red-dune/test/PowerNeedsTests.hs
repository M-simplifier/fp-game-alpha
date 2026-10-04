module PowerNeedsTests(powerNeedsTests) where
import Colony.Content
import qualified Colony.JSON as J
import Colony.Inventory
import Colony.Needs
import Colony.Power
import Colony.Types
import Colony.Units
import Control.Monad(forM_,unless,foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

assert :: String -> Bool -> IO()
assert label condition=unless condition(ioError(userError label))
right :: Show e => String -> Either e a -> IO a
right label=either(\e->ioError(userError(label++": "++show e)))pure
transaction :: Content -> IO Inventory
transaction content=snd <$> right "power stock fixture"(runInventory action(emptyInventory content))
  where action=do
          addStorage(Owner Warehouse(EntityId 1))(Storage 2000000 Nothing(EntityId 10))
          _<-mintLot tx InitialGrant Nothing Fuel 1000000(Owner Warehouse(EntityId 1))(SimTick 0)Nothing "fixture"
          pure()
        tx=TxId 1 1(BoundarySeq 0)P0 0

powerNeedsTests :: Content -> IO()
powerNeedsTests content=do
  inv<-transaction content
  let emptyGrid=PowerGrid(EntityId 20)[][][]M.empty
      solar=Solar(EntityId 21)100
      battery=Battery(EntityId 22)0 0 100
      grid=emptyGrid {gridSolar=[solar],gridBatteries=[battery]}
      tx=TxId 1 1(BoundarySeq 1)P6 0
      step tick demands g=runInventory(stepPower tx(SimTick tick)Clear demands g)inv
  ((charged,result),_)<-right "solar charge"(step 12000[PowerDemand(EntityId 30)1 20000]grid)
  assert "solar demand +90% charge +10% heat"(generatedJ result==120000&&servedJ result==60000&&chargedInputJ result==60000&&heatLossJ result==6000&&curtailedJ result==0&&map batteryStoredJ(gridBatteries charged)==[54000])
  ((discharged,r2),_)<-right "skip oversized demand"(step 24000[PowerDemand(EntityId 30)0 100000,PowerDemand(EntityId 31)1 10000]charged)
  assert "smaller lower-priority consumer is served"(poweredConsumers r2==S.singleton(EntityId 31)&&dischargedJ r2==30000&&chargedInputJ r2==0&&map batteryStoredJ(gridBatteries discharged)==[24000])
  let generator=Generator(EntityId 23)(Owner Warehouse(EntityId 1))True 100
  ((_,r3),afterFuel)<-right "generator minimum load"(step 0[PowerDemand(EntityId 30)0 1](emptyGrid {gridGenerators=[generator]}))
  assert "fuel generator uses indivisible20g batch"(generatedJ r3==120000&&servedJ r3==3&&curtailedJ r3==119997&&M.lookup(Fuel,FuelBurned)(invLedger afterFuel)==Just 20)
  ((_,idle),idleInv)<-right "idle generator"(step 0[](emptyGrid {gridGenerators=[generator]}))
  assert "idle auto generator burns no fuel"(generatedJ idle==0&&idleInv==inv)
  let full=grid {gridBatteries=[battery {batteryStoredJ=batteryCapacityJ}],gridEnergyLedger=M.singleton InitialEnergy batteryCapacityJ}
  ((_,rf),_)<-right "full battery"(step 12000[]full)
  assert "full battery cannot dissipate gratuitous charge"(chargedInputJ rf==0&&curtailedJ rf==120000)
  forM_[Clear,Haze,Sandstorm]$ \weather->forM_[0,7199,7200,10800,17999,18000,21599,21600,28799]$ \tick->do
    let hour=tick `div` 1200;light=if hour>=9&&hour<15 then 100 else if hour>=6&&hour<18 then 50 else 0
        weatherPct=case weather of Clear->100;Haze->60;Sandstorm->10
    assert "independent solar integer oracle"(solarEnergy(SimTick tick)weather solar==120000*light*weatherPct `div` 10000)
  _<-foldM(\(g,state)tick->do
       let watts=(toInteger tick*7919) `mod` 150000
       ((next,r),nextInv)<-right "long energy trace"(runInventory(stepPower tx(SimTick tick)(if tick `mod` 9==0 then Sandstorm else Clear)[PowerDemand(EntityId 30)2 watts]g)state)
       assert "no simultaneous charge/discharge"(chargedInputJ r==0||dischargedJ r==0)
       pure(next,nextInv))(grid {gridGenerators=[generator]},inv)[1..10000]
  needsDaily content
  fairnessOracle
  needsGolden content
  putStrLn "PowerNeedsTests PASS: 10,000 actual energy transitions, solar/fuel/battery edge fixtures, pantry-only daily needs 2,000 fair-allocation oracle cases and 5 normative v1.0.1 needs golden cases"

needsDaily :: Content -> IO()
needsDaily content=do
  let pantry=Owner Pantry(EntityId 1);colony=EntityId 10;resident=EntityId 2
      tx=TxId 1 1(BoundarySeq 1)P8 0
      ns=NeedsState(M.singleton resident(newResident resident colony))(M.singleton colony[pantry])
      action=do
        addStorage pantry(Storage 400000 Nothing colony)
        _<-mintLot tx InitialGrant Nothing Water 6000 pantry(SimTick 0)Nothing "fixture"
        _<-mintLot tx InitialGrant Nothing Ration 3000 pantry(SimTick 0)(Just(SimTick 576000))"fixture"
        pure()
  (_,inv)<-right "needs stock"(runInventory action(emptyInventory content))
  (final,inventory,water,food)<-foldM(\(n,s,wd,fd)tick->do
    ((next,r),after)<-right "daily needs step"(runInventory(stepNeeds tx(SimTick tick)n)s)
    pure(next,after,wd+needWaterDue r,fd+needFoodDue r))(ns,inv,0,0)[20,40..28800]
  assert "exact daily quantities and saved remainders"(water==6000&&food==3000&&all(\r->residentWaterRemainder r==0&&residentFoodRemainder r==0&&residentHealth r==1000)(M.elems(needsResidents final)))
  assert "all daily supply consumed once"(M.lookup(Water,LivingConsumed)(invLedger inventory)==Just 6000&&M.lookup(Ration,LivingConsumed)(invLedger inventory)==Just 3000&&M.null(invLots inventory))
  let noPantry=ns {needsPantries=M.empty}
  ((_,short),unchanged)<-right "warehouse cannot feed remotely"(runInventory(stepNeeds tx(SimTick 20)noPantry)inv)
  assert "no instantaneous warehouse/pantry service"(needWaterServed short==0&&needFoodServed short==0&&unchanged==inv)
  let people=[newResident(EntityId n)colony|n<-[2..5]]
      fairNs=NeedsState(M.fromList[(residentId r,r)|r<-people])(M.singleton colony[pantry])
  (_,empty)<-right "fair pantry"(runInventory(addStorage pantry(Storage 400000 Nothing colony))(emptyInventory content))
  (fairFinal,_)<-foldM(\(n,s)tick->do
    (_,withUnit)<-right "single scarce unit"(runInventory(mintLot tx InitialGrant Nothing Water 1 pantry(SimTick tick)Nothing "fairness")s)
    ((next,_),after)<-right "fair needs"(runInventory(stepNeeds tx(SimTick tick)n)withUnit)
    pure(next,after))(fairNs,empty)[20,40,60,80]
  assert "rotating four-person starvation fairness"(all((==1).residentHourWaterServed)(M.elems(needsResidents fairFinal)))

fairnessOracle :: IO()
fairnessOracle=forM_[1..2000::Integer]$ \seed->do
  let requests=[(EntityId(fromInteger n),(seed*(n+13)) `mod` 17)|n<-[1..1+seed `mod` 19]]
      available=(seed*71) `mod` 500
      expected=slow available requests(M.fromList[(i,0)|(i,_)<-requests])
  assert("max-min allocation oracle seed "++show seed)(allocateFair available requests==expected)
  where
    slow amount requests assigned
      | amount<=0=assigned
      | otherwise=case[(i,M.findWithDefault 0 i assigned)|(i,due)<-requests,M.findWithDefault 0 i assigned<due]of
          []->assigned
          candidates->let minimumAssigned=minimum(map snd candidates)
                          chosen=fst(head(filter((==minimumAssigned).snd)candidates))
                      in slow(amount-1)requests(M.adjust(+1)chosen assigned)

needsGolden :: Content -> IO()
needsGolden content=do
  source<-readFile "data/needs-golden.json"
  cases<-right "read needs golden"(J.parseJSON source >>= J.object >>= J.field "cases" >>= J.array)
  forM_ cases $ \value->do
    object<-right "golden case"(J.object value)
    label<-right "golden id"(J.field "id" object >>= J.string)
    tick<-right label(J.field "evaluation_tick" object >>= J.integer)
    resource<-right label(J.field "resource" object >>= J.string >>= parseResource)
    targetName<-right label(J.field "colony" object >>= J.string)
    supply<-right label(J.field "supply" object >>= J.integer)
    rows<-right label(J.field "residents" object >>= J.array)
    people<-mapM (makeResident resource)rows
    expectedObject<-right label(J.field "expected_allocations" object >>= J.object)
    expected<-right label(traverse J.integer expectedObject)
    let target=colonyId targetName
        pantry=Owner Pantry(EntityId 100)
        ns=NeedsState(M.fromList[(residentId r,r)|r<-people])(M.singleton target[pantry])
        tx=TxId 1 1(BoundarySeq 1)P8 0
        initialize=do
          addStorage pantry(Storage 400000 Nothing target)
          if supply>0 then mintLot tx InitialGrant Nothing resource supply pantry(SimTick 0)Nothing "needs-golden" >> pure() else pure()
    (_,inv)<-right label(runInventory initialize(emptyInventory content))
    ((next,_),_)<-right label(runInventory(stepNeeds tx(SimTick(fromInteger tick))ns)inv)
    let actual=M.fromList[(show n,if resource==Water then residentHourWaterServed r else residentHourFoodServed r)|r<-M.elems(needsResidents next),residentColony r==target,residentStatus r `elem` [Living,Incapacitated],let EntityId n=residentId r]
    assert("normative needs golden "++label)(actual==expected)
  where
    colonyId name=EntityId(case name of "A"->201;"B"->202;_->203)
    makeResident resource value=do
      row<-right "golden resident"(J.object value)
      ident<-right "resident id"(J.field "id" row >>= J.integer)
      colony<-right "resident colony"(J.field "colony" row >>= J.string)
      status<-right "resident status"(J.field "state" row >>= J.string)
      due<-right "resident due"(J.field "due" row >>= J.integer)
      let r=newResident(EntityId(fromInteger ident))(colonyId colony)
          state=case status of "Incapacitated"->Incapacitated;"InTransit"->InTransit;"Evacuated"->Evacuated;_->Living
          remainder=max 0(due*28800-(if resource==Water then 6000 else 3000)*20)
      pure(if resource==Water then r {residentStatus=state,residentWaterRemainder=remainder} else r {residentStatus=state,residentFoodRemainder=remainder})
