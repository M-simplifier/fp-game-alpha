; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)

(declare-const a (_ BitVec 64))
(declare-const b (_ BitVec 64))
(assert (and (bvule a (_ bv9000000000000 64)) (bvule b (_ bv9000000000000 64))))
(assert (bvult (bvadd a b) a))

(check-sat)
