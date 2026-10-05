module BadVacuousCall where
import VacuousContract (impossibleInput)
{-@ impossibleCall :: {v:Integer | v == 42} @-}
impossibleCall :: Integer
impossibleCall = impossibleInput 0
