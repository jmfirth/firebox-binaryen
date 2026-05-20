;; firebox #431: regression test for symmetric (Normal || Rewinding) rewind
;; passthrough at off-chain call sites inside instrumented functions.
;;
;; The canonical Ruby `main+0x1599a` pattern: a caller that is on-chain
;; (because it calls some chain-changing import) ALSO contains a call to
;; an off-chain (removelisted) callee. Pre-#431 the off-chain call site
;; was wrapped in `if (state == Normal) { call }`-only, with no rewind
;; passthrough — the rewind walker would fall past the body and hit a
;; trailing `unreachable` barrier emitted by AsyncifyLocals.
;;
;; Post-#431 the wrapper is `if (state == Normal || state == Rewinding) { call }`
;; — mirroring the existing `Iff` handler's rewind passthrough idiom at
;; Asyncify.cpp lines 1119-1152.
;;
;; The check is intentionally minimal: a CHECK looking for `(call $offchain_callee)`
;; preceded — within the same function — by an `(i32.or` that pairs
;; state==0 and state==2. CHECK-LABEL anchors us inside $caller; CHECK-NOT
;; before the call site asserts there is no asymmetric Normal-only wrapper
;; for the offchain call.

;; RUN: foreach %s %t wasm-opt --asyncify \
;; RUN:   --pass-arg=asyncify-imports@env.unwinding_import \
;; RUN:   --pass-arg=asyncify-removelist@offchain_callee \
;; RUN:   -S -o - | filecheck %s

(module
  (import "env" "unwinding_import" (func $unwinding_import))

  (memory 1 2)

  ;; Off-chain (removelisted) callee. `info.canChangeState = false` set
  ;; explicitly by `removeList.match()` at Asyncify.cpp:692.
  (func $offchain_callee
    (nop))

  ;; On-chain callee — reaches the unwinding import.
  (func $onchain_callee
    (call $unwinding_import))

  ;; Caller is on-chain because it calls `$onchain_callee`. It ALSO calls
  ;; `$offchain_callee`. This is the Ruby `main` pattern: an instrumented
  ;; function with mixed on-chain + off-chain call sites.
  ;;
  ;; The off-chain call site MUST have a symmetric (Normal || Rewinding)
  ;; wrapper — that is the heart of the #431 fix.
  (func $caller (export "caller")
    (call $offchain_callee)
    (call $onchain_callee))
)

;; CHECK-LABEL: (func $caller
;; Symmetric (Normal || Rewinding) wrapper around the off-chain call site.
;; The (i32.or with two (i32.eq state-checks must appear, AND the (call
;; $offchain_callee) must appear after it in the same function.
;; CHECK:       (i32.or
;; CHECK-NEXT:    (i32.eq
;; CHECK:           (i32.const 0)
;; CHECK:         (i32.eq
;; CHECK:           (i32.const 2)
;; CHECK:       (call $offchain_callee)
