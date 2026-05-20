;; firebox #431: regression test for rewind passthrough at off-chain call
;; sites inside instrumented functions.
;;
;; The canonical Ruby `main+0x1599a` pattern: a caller that is on-chain
;; (because it calls some chain-changing import) ALSO contains a call to
;; an off-chain (removelisted) callee. Pre-#431 the off-chain call site
;; was wrapped in `if (state == Normal) { call }`-only, with no rewind
;; passthrough — the rewind walker would fall past the body and hit a
;; trailing `unreachable` barrier emitted by AsyncifyLocals.
;;
;; The first Shape B-PROPER attempt (predecessor) emitted
;; `if (state == Normal || state == Rewinding) { call }` — symmetric in
;; structure but semantically WRONG: it re-executes the call body on
;; rewind, which accesses uninitialized prologue locals.
;;
;; Shape B-PROPER-3 (this fix) emits a hybrid `if/else`:
;; `if (state == Normal) { call } else { /* empty */ }`. The empty else
;; gives the walker an unconditional path past the call site without
;; re-executing it, while preserving prologue-state isolation.
;;
;; The check asserts the new shape: an `if` over `state==Normal` whose
;; `then` contains the call and whose `else` is an empty block.

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
  ;; The off-chain call site MUST have a Normal-only `then` with an empty
  ;; `else` so the rewind walker advances past without re-executing.
  (func $caller (export "caller")
    (call $offchain_callee)
    (call $onchain_callee))
)

;; CHECK-LABEL: (func $caller
;; The off-chain call site uses the hybrid `if(state==Normal) (then call)
;; (else empty)` shape. The (call $offchain_callee) MUST be immediately
;; followed by an (else) clause. CHECK-NEXT enforces adjacency.
;; CHECK:        (call $offchain_callee)
;; CHECK-NEXT:   )
;; CHECK-NEXT:   (else
;; CHECK-NEXT:   )
