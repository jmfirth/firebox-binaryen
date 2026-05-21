;; firebox #431 — Phase 2 regression test for per-call-site `call_index`
;; accounting at off-chain (remove-listed) call sites inside on-chain callers.
;;
;; THE BUG (the canonical Ruby `main` pattern):
;;
;;   An instrumented function (`$caller`) is on the asyncify chain because it
;;   calls an on-chain callee (`$onchain_callee`, which reaches an unwinding
;;   import). It ALSO calls a REMOVE-LISTED callee (`$offchain_callee`). Ruby
;;   remove-lists `rb_wasm_rt_start` because that function owns its own
;;   asyncify-Fiber state machine — yet its descendants DO unwind at runtime
;;   through wasix imports. The remove-list severs the ANALYZER's transitive
;;   view, not the RUNTIME's control flow.
;;
;;   Pre-#431 the remove-listed call site was wrapped in `if (state == Normal)`
;;   only (or, post-Shape-B-PROPER, the symmetric `if (state == Normal ||
;;   state == Rewinding)`). Neither allocated a per-call-site `call_index`.
;;   But `$caller`'s function-prelude still emits its unconditional
;;   `callIndexPop` — popping a value `$caller`'s body never pushed. The
;;   rewind buffer desyncs; the trap surfaces deeper on the rewind walk
;;   (empirically: Ruby `main+0x1599a`, `__asyncify_state == 2`).
;;
;; THE FIX (Phase 2 — makeOffChainCallSupport via needsRewindAccounting):
;;
;;   A call to a remove-listed function inside an instrumented caller is a
;;   REAL unwind/rewind boundary. It must receive the SAME `makeCallSupport`
;;   treatment an on-chain call site gets:
;;     * a per-call-site `call_index` (0 for $offchain_callee, 1 for
;;       $onchain_callee here),
;;     * a `check_call_index(N)` discriminator on the entry condition
;;       (`i32.eq (local.get $rewindIndex) (i32.const N)`), and
;;     * a `makePossibleUnwind` epilogue (`if (state == Unwinding) { br
;;       $__asyncify_unwind N }`) that pushes `N` so the prelude's pop is
;;       balanced.
;;
;;   The two call sites are clumped-broken apart, so the trailing `return` /
;;   result expression lands in its OWN `if (state == Normal)` skip — it does
;;   NOT sit inside the off-chain call wrapper, so it cannot bypass the
;;   `makePossibleUnwind` epilogue (the §4e structural problem dissolves once
;;   off-chain calls break the non-state-changing clump).
;;
;; A GENUINELY off-chain call (one that can never unwind) is NOT upgraded —
;; see asyncify_pass-arg=asyncify-addlist@foo.wast, where the call to the
;; empty `$nothing` keeps the cheap `if (state == Normal)` skip. Only
;; remove-listed callees get the `call_index`. This keeps the pass a no-op
;; for programs that do not use `--asyncify-removelist`.

;; RUN: foreach %s %t wasm-opt --asyncify \
;; RUN:   --pass-arg=asyncify-imports@env.unwinding_import \
;; RUN:   --pass-arg=asyncify-removelist@offchain_callee \
;; RUN:   -S -o - | filecheck %s

(module
  (import "env" "unwinding_import" (func $unwinding_import))

  (memory 1 2)

  ;; Off-chain (remove-listed) callee. `info.canChangeState = false` is set by
  ;; fiat via `removeList.match()`. At RUNTIME, in the canonical Ruby case, a
  ;; remove-listed callee's descendants can still unwind — the remove-list
  ;; only blinds the analyzer.
  (func $offchain_callee
    (nop))

  ;; On-chain callee — reaches the unwinding import; the analyzer marks it
  ;; chain-changing.
  (func $onchain_callee
    (call $unwinding_import))

  ;; The Ruby `main` pattern: an instrumented caller with BOTH a remove-listed
  ;; call site and an on-chain call site, ending in a `return` of a value.
  ;; The result type is deliberately non-void — that is what makes
  ;; AsyncifyLocals emit the trailing `unreachable` barrier the original bug
  ;; trapped on.
  (func $caller (export "caller") (result i32)
    (call $offchain_callee)
    (call $onchain_callee)
    (i32.const 0))
)

;; The remove-listed `$offchain_callee` call site MUST get the full
;; `makeCallSupport` treatment — a per-call-site `call_index` (0), a
;; `check_call_index(0)` discriminator, AND a `makePossibleUnwind` epilogue
;; that pushes the index. The checks below are intentionally minimal: they
;; pin the load-bearing instructions in execution order, not the full
;; byte-shape (so unrelated emission churn does not break the test).
;;
;; CHECK-LABEL: (func $caller
;;
;; The entry condition for the off-chain call: `state == Normal` OR the
;; popped rewind index equals this call site's index 0.
;; CHECK:       (i32.or
;; CHECK-NEXT:    (i32.eq
;; CHECK-NEXT:      (global.get $__asyncify_state)
;; CHECK-NEXT:      (i32.const 0)
;; CHECK:         (i32.eq
;; CHECK:           (i32.const 0)
;;
;; The off-chain call itself runs inside that guard.
;; CHECK:       (call $offchain_callee)
;;
;; And — the heart of the #431 fix — a `makePossibleUnwind` epilogue
;; immediately after it: if the off-chain callee unwound (state==1), push
;; THIS call site's index (0) by breaking to the unwind block. Without this
;; the caller's prelude pop is unbalanced.
;; CHECK:       (if
;; CHECK-NEXT:    (i32.eq
;; CHECK-NEXT:      (global.get $__asyncify_state)
;; CHECK-NEXT:      (i32.const 1)
;; CHECK:         (br $__asyncify_unwind
;; CHECK-NEXT:      (i32.const 0)
;;
;; The on-chain call site keeps its own distinct index (1).
;; CHECK:       (call $onchain_callee)
;; CHECK:       (br $__asyncify_unwind
;; CHECK-NEXT:    (i32.const 1)

