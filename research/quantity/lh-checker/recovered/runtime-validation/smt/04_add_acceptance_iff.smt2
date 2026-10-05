; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)

(declare-const a Int)
(declare-const b Int)
(assert (and (<= 0 a) (<= a 9000000000000) (<= 0 b) (<= b 9000000000000)))
(assert (not (= (and (<= 0 (+ a b)) (<= (+ a b) 9000000000000)) (<= (+ a b) 9000000000000))))
(check-sat)
