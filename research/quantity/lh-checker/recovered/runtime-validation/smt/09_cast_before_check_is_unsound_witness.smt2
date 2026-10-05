; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)

; Counterexample for a DIFFERENT, cast-first design. Production checks Integer first.
(define-fun n () Int 18446744073709551616)
(assert (> n 9000000000000))
(assert (= (bv2int ((_ int2bv 64) n)) 0))

(check-sat)
