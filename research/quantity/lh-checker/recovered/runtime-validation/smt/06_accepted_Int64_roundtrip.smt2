; Model-level fact only; not extracted from or linked to Haskell bodies.
(set-option :timeout 20000)
(set-logic ALL)

(declare-const n Int)
(assert (and (<= 0 n) (<= n 9000000000000)))
(define-fun bits () (_ BitVec 64) ((_ int2bv 64) n))
(define-fun signed () Int (ite (bvslt bits (_ bv0 64)) (- (bv2int bits) 18446744073709551616) (bv2int bits)))
(assert (not (= signed n)))

(check-sat)
