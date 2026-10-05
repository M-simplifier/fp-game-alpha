; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)
(assert (not (and (<= 0 9000000000000) (<= 9000000000000 9223372036854775807))))
(check-sat)
