; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)

(declare-const bits (_ BitVec 64))
(assert (bvule bits (_ bv9000000000000 64)))
(assert (bvslt bits (_ bv0 64)))

(check-sat)
