;;; Tree-IL partial evaluator

;; Copyright (C) 2011 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

(define-module (language tree-il peval)
  #:use-module (language tree-il)
  #:use-module (language tree-il primitives)
  #:use-module (ice-9 vlist)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:export (peval))

;;;
;;; Partial evaluation is Guile's most important source-to-source
;;; optimization pass.  It performs copy propagation, dead code
;;; elimination, inlining, and constant folding, all while preserving
;;; the order of effects in the residual program.
;;;
;;; For more on partial evaluation, see William Cook’s excellent
;;; tutorial on partial evaluation at DSL 2011, called “Build your own
;;; partial evaluator in 90 minutes”[0].
;;;
;;; Our implementation of this algorithm was heavily influenced by
;;; Waddell and Dybvig's paper, "Fast and Effective Procedure Inlining",
;;; IU CS Dept. TR 484.
;;;
;;; [0] http://www.cs.utexas.edu/~wcook/tutorial/.  
;;;

;; First, some helpers.
;;
(define-syntax *logging* (identifier-syntax #f))

;; For efficiency we define *logging* to inline to #f, so that the call
;; to log* gets optimized out.  If you want to log, uncomment these
;; lines:
;;
;; (define %logging #f)
;; (define-syntax *logging* (identifier-syntax %logging))
;;
;; Then you can change %logging at runtime.

(define-syntax log
  (syntax-rules (quote)
    ((log 'event arg ...)
     (if (and *logging*
              (or (eq? *logging* #t)
                  (memq 'event *logging*)))
         (log* 'event arg ...)))))

(define (log* event . args)
  (let ((pp (module-ref (resolve-interface '(ice-9 pretty-print))
                        'pretty-print)))
    (pp `(log ,event . ,args))
    (newline)
    (values)))

(define-syntax-rule (let/ec k e e* ...)
  (let ((tag (make-prompt-tag)))
    (call-with-prompt
     tag
     (lambda ()
       (let ((k (lambda args (apply abort-to-prompt tag args))))
         e e* ...))
     (lambda (_ res) res))))

(define (tree-il-any proc exp)
  (let/ec k
    (tree-il-fold (lambda (exp res)
                    (let ((res (proc exp)))
                      (if res (k res) #f)))
                  (lambda (exp res)
                    (let ((res (proc exp)))
                      (if res (k res) #f)))
                  (lambda (exp res) #f)
                  #f exp)))

(define (vlist-any proc vlist)
  (let ((len (vlist-length vlist)))
    (let lp ((i 0))
      (and (< i len)
           (or (proc (vlist-ref vlist i))
               (lp (1+ i)))))))

;; Peval will do a one-pass analysis on the source program to determine
;; the set of assigned lexicals, and to identify unreferenced and
;; singly-referenced lexicals.
;;
(define-record-type <var>
  (make-var name gensym refcount set?)
  var?
  (name var-name)
  (gensym var-gensym)
  (refcount var-refcount set-var-refcount!)
  (set? var-set? set-var-set?!))

(define* (build-var-table exp #:optional (table vlist-null))
  (tree-il-fold
   (lambda (exp res)
     (match exp
       (($ <lexical-ref> src name gensym)
        (let ((var (cdr (vhash-assq gensym res))))
          (set-var-refcount! var (1+ (var-refcount var)))
          res))
       (_ res)))
   (lambda (exp res)
     (match exp
       (($ <lambda-case> src req opt rest kw init gensyms body alt)
        (fold (lambda (name sym res)
                (vhash-consq sym (make-var name sym 0 #f) res))
              res
              (append req (or opt '()) (if rest (list rest) '())
                      (match kw
                        ((aok? (kw name sym) ...) name)
                        (_ '())))
              gensyms))
       (($ <let> src names gensyms vals body)
        (fold (lambda (name sym res)
                (vhash-consq sym (make-var name sym 0 #f) res))
              res names gensyms))
       (($ <letrec> src in-order? names gensyms vals body)
        (fold (lambda (name sym res)
                (vhash-consq sym (make-var name sym 0 #f) res))
              res names gensyms))
       (($ <fix> src names gensyms vals body)
        (fold (lambda (name sym res)
                (vhash-consq sym (make-var name sym 0 #f) res))
              res names gensyms))
       (($ <lexical-set> src name gensym exp)
        (set-var-set?! (cdr (vhash-assq gensym res)) #t)
        res)
       (_ res)))
   (lambda (exp res) res)
   table exp))

;; Counters are data structures used to limit the effort that peval
;; spends on particular inlining attempts.  Each call site in the source
;; program is allocated some amount of effort.  If peval exceeds the
;; effort counter while attempting to inline a call site, it aborts the
;; inlining attempt and residualizes a call instead.
;;
;; As there is a fixed number of call sites, that makes `peval' O(N) in
;; the number of call sites in the source program.
;;
;; Counters should limit the size of the residual program as well, but
;; currently this is not implemented.
;;
;; At the top level, before seeing any peval call, there is no counter,
;; because inlining will terminate as there is no recursion.  When peval
;; sees a call at the top level, it will make a new counter, allocating
;; it some amount of effort and size.
;;
;; This top-level effort counter effectively "prints money".  Within a
;; toplevel counter, no more effort is printed ex nihilo; for a nested
;; inlining attempt to proceed, effort must be transferred from the
;; toplevel counter to the nested counter.
;;
;; Via `data' and `prev', counters form a linked list, terminating in a
;; toplevel counter.  In practice `data' will be the a pointer to the
;; source expression of the procedure being inlined.
;;
;; In this way peval can detect a recursive inlining attempt, by walking
;; back on the `prev' links looking for matching `data'.  Recursive
;; counters receive a more limited effort allocation, as we don't want
;; to spend all of the effort for a toplevel inlining site on loops.
;; Also, recursive counters don't need a prompt at each inlining site:
;; either the call chain folds entirely, or it will be residualized at
;; its original call.
;;
(define-record-type <counter>
  (%make-counter effort size continuation recursive? data prev)
  counter?
  (effort effort-counter)
  (size size-counter)
  (continuation counter-continuation)
  (recursive? counter-recursive? set-counter-recursive?!)
  (data counter-data)
  (prev counter-prev))

(define (abort-counter c)
  ((counter-continuation c)))

(define (record-effort! c)
  (let ((e (effort-counter c)))
    (if (zero? (variable-ref e))
        (abort-counter c)
        (variable-set! e (1- (variable-ref e))))))

(define (record-size! c)
  (let ((s (size-counter c)))
    (if (zero? (variable-ref s))
        (abort-counter c)
        (variable-set! s (1- (variable-ref s))))))

(define (find-counter data counter)
  (and counter
       (if (eq? data (counter-data counter))
           counter
           (find-counter data (counter-prev counter)))))

(define* (transfer! from to #:optional
                    (effort (variable-ref (effort-counter from)))
                    (size (variable-ref (size-counter from))))
  (define (transfer-counter! from-v to-v amount)
    (let* ((from-balance (variable-ref from-v))
           (to-balance (variable-ref to-v))
           (amount (min amount from-balance)))
      (variable-set! from-v (- from-balance amount))
      (variable-set! to-v (+ to-balance amount))))

  (transfer-counter! (effort-counter from) (effort-counter to) effort)
  (transfer-counter! (size-counter from) (size-counter to) size))

(define (make-top-counter effort-limit size-limit continuation data)
  (%make-counter (make-variable effort-limit)
                 (make-variable size-limit)
                 continuation
                 #t
                 data
                 #f))

(define (make-nested-counter continuation data current)
  (let ((c (%make-counter (make-variable 0)
                          (make-variable 0)
                          continuation
                          #f
                          data
                          current)))
    (transfer! current c)
    c))

(define (make-recursive-counter effort-limit size-limit orig current)
  (let ((c (%make-counter (make-variable 0)
                          (make-variable 0)
                          (counter-continuation orig)
                          #t
                          (counter-data orig)
                          current)))
    (transfer! current c effort-limit size-limit)
    c))

;; Operand structures allow bindings to be processed lazily instead of
;; eagerly.  By doing so, hopefully we can get process them in a way
;; appropriate to their use contexts.  Operands also prevent values from
;; being visited multiple times, wasting effort.
;;
;; TODO: Record value size in operand structure?
;; 
(define-record-type <operand>
  (%make-operand var sym visit source visit-count residualize?
                 copyable? residual-value constant-value)
  operand?
  (var operand-var)
  (sym operand-sym)
  (visit %operand-visit)
  (source operand-source)
  (visit-count operand-visit-count set-operand-visit-count!)
  (residualize? operand-residualize? set-operand-residualize?!)
  (copyable? operand-copyable? set-operand-copyable?!)
  (residual-value operand-residual-value set-operand-residual-value!)
  (constant-value operand-constant-value set-operand-constant-value!))

(define* (make-operand var sym #:optional source visit)
  ;; Bound operands are considered copyable until we prove otherwise.
  (%make-operand var sym visit source 0 #f (and source #t) #f #f))

(define (make-bound-operands vars syms sources visit)
  (map (lambda (x y z) (make-operand x y z visit)) vars syms sources))

(define (make-unbound-operands vars syms)
  (map make-operand vars syms))

(define* (visit-operand op counter ctx #:optional effort-limit size-limit)
  ;; Peval is O(N) in call sites of the source program.  However,
  ;; visiting an operand can introduce new call sites.  If we visit an
  ;; operand outside a counter -- i.e., outside an inlining attempt --
  ;; this can lead to divergence.  So, if we are visiting an operand to
  ;; try to copy it, and there is no counter, make a new one.
  ;;
  ;; This will only happen at most as many times as there are lexical
  ;; references in the source program.
  (and (zero? (operand-visit-count op))
       (dynamic-wind
         (lambda ()
           (set-operand-visit-count! op (1+ (operand-visit-count op))))
         (lambda ()
           (and (operand-source op)
                (if (or counter (and (not effort-limit) (not size-limit)))
                    ((%operand-visit op) (operand-source op) counter ctx)
                    (let/ec k
                      (define (abort) (k #f))
                      ((%operand-visit op)
                       (operand-source op) 
                       (make-top-counter effort-limit size-limit abort op)
                       ctx)))))
         (lambda ()
           (set-operand-visit-count! op (1- (operand-visit-count op)))))))

;; A helper for constant folding.
;;
(define (types-check? primitive-name args)
  (case primitive-name
    ((values) #t)
    ((not pair? null? list? symbol? vector? struct?)
     (= (length args) 1))
    ((eq? eqv? equal?)
     (= (length args) 2))
    ;; FIXME: add more cases?
    (else #f)))

(define* (peval exp #:optional (cenv (current-module)) (env vlist-null)
                #:key
                (operator-size-limit 40)
                (operand-size-limit 20)
                (value-size-limit 10)
                (effort-limit 500)
                (recursive-effort-limit 100))
  "Partially evaluate EXP in compilation environment CENV, with
top-level bindings from ENV and return the resulting expression."

  ;; This is a simple partial evaluator.  It effectively performs
  ;; constant folding, copy propagation, dead code elimination, and
  ;; inlining.

  ;; TODO:
  ;;
  ;; Propagate copies across toplevel bindings, if we can prove the
  ;; bindings to be immutable.
  ;;
  ;; Specialize lambda expressions with invariant arguments.

  (define local-toplevel-env
    ;; The top-level environment of the module being compiled.
    (match exp
      (($ <toplevel-define> _ name)
       (vhash-consq name #t env))
      (($ <sequence> _ exps)
       (fold (lambda (x r)
               (match x
                 (($ <toplevel-define> _ name)
                  (vhash-consq name #t r))
                 (_ r)))
             env
             exps))
      (_ env)))

  (define (local-toplevel? name)
    (vhash-assq name local-toplevel-env))

  ;; gensym -> <var>
  ;; renamed-term -> original-term
  ;;
  (define store (build-var-table exp))

  (define (record-new-temporary! name sym refcount)
    (set! store (vhash-consq sym (make-var name sym refcount #f) store)))

  (define (lookup-var sym)
    (let ((v (vhash-assq sym store)))
      (if v (cdr v) (error "unbound var" sym (vlist->list store)))))

  (define (fresh-gensyms vars)
    (map (lambda (var)
           (let ((new (gensym (string-append (symbol->string (var-name var))
                                             " "))))
             (set! store (vhash-consq new var store))
             new))
         vars))

  (define (assigned-lexical? sym)
    (var-set? (lookup-var sym)))

  (define (lexical-refcount sym)
    (var-refcount (lookup-var sym)))

  ;; ORIG has been alpha-renamed to NEW.  Analyze NEW and record a link
  ;; from it to ORIG.
  ;;
  (define (record-source-expression! orig new)
    (set! store (vhash-consq new (source-expression orig) store))
    new)

  ;; Find the source expression corresponding to NEW.  Used to detect
  ;; recursive inlining attempts.
  ;;
  (define (source-expression new)
    (let ((x (vhash-assq new store)))
      (if x (cdr x) new)))

  (define* (residualize-lexical op #:optional ctx val)
    (log 'residualize op)
    (set-operand-residualize?! op #t)
    (if (eq? ctx 'value)
        (set-operand-residual-value! op val))
    (make-lexical-ref #f (var-name (operand-var op)) (operand-sym op)))

  (define (apply-primitive name args)
    ;; todo: further optimize commutative primitives
    (catch #t
      (lambda ()
        (call-with-values
            (lambda ()
              (apply (module-ref the-scm-module name) args))
          (lambda results
            (values #t results))))
      (lambda _
        (values #f '()))))

  (define (make-values src values)
    (match values
      ((single) single)                 ; 1 value
      ((_ ...)                          ; 0, or 2 or more values
       (make-application src (make-primitive-ref src 'values)
                         values))))

  (define (fold-constants src name args ctx)
    (define (residualize-call)
      (make-application src (make-primitive-ref #f name) args))
    (cond
     ((every const? args)
      (let-values (((success? values)
                    (apply-primitive name (map const-exp args))))
        (log 'fold success? values name args)
        (if success?
            (case ctx
              ((effect) (make-void src))
              ((test)
               ;; Values truncation: only take the first
               ;; value.
               (if (pair? values)
                   (make-const src (car values))
                   (make-values src '())))
              (else
               (make-values src (map (cut make-const src <>) values))))
            (residualize-call))))
     ((and (eq? ctx 'effect) (types-check? name args))
      (make-void #f))
     (else
      (residualize-call))))

  (define (inline-values exp src names gensyms body)
    (let loop ((exp exp))
      (match exp
        ;; Some expression types are always singly-valued.
        ((or ($ <const>)
             ($ <void>)
             ($ <lambda>)
             ($ <lexical-ref>)
             ($ <toplevel-ref>)
             ($ <module-ref>)
             ($ <primitive-ref>)
             ($ <dynref>)
             ($ <lexical-set>)          ; FIXME: these set! expressions
             ($ <toplevel-set>)         ; could return zero values in
             ($ <toplevel-define>)      ; the future
             ($ <module-set>)           ;
             ($ <dynset>))              ; 
         (and (= (length names) 1)
              (make-let src names gensyms (list exp) body)))
        (($ <application> src
            ($ <primitive-ref> _ (? singly-valued-primitive? name)))
         (and (= (length names) 1)
              (make-let src names gensyms (list exp) body)))

        ;; Statically-known number of values.
        (($ <application> src ($ <primitive-ref> _ 'values) vals)
         (and (= (length names) (length vals))
              (make-let src names gensyms vals body)))

        ;; Not going to copy code into both branches.
        (($ <conditional>) #f)

        ;; Bail on other applications.
        (($ <application>) #f)

        ;; Bail on prompt and abort.
        (($ <prompt>) #f)
        (($ <abort>) #f)
        
        ;; Propagate to tail positions.
        (($ <let> src names gensyms vals body)
         (let ((body (loop body)))
           (and body
                (make-let src names gensyms vals body))))
        (($ <letrec> src in-order? names gensyms vals body)
         (let ((body (loop body)))
           (and body
                (make-letrec src in-order? names gensyms vals body))))
        (($ <fix> src names gensyms vals body)
         (let ((body (loop body)))
           (and body
                (make-fix src names gensyms vals body))))
        (($ <let-values> src exp
            ($ <lambda-case> src2 req opt rest kw inits gensyms body #f))
         (let ((body (loop body)))
           (and body
                (make-let-values src exp
                                 (make-lambda-case src2 req opt rest kw
                                                   inits gensyms body #f)))))
        (($ <dynwind> src winder body unwinder)
         (let ((body (loop body)))
           (and body
                (make-dynwind src winder body unwinder))))
        (($ <dynlet> src fluids vals body)
         (let ((body (loop body)))
           (and body
                (make-dynlet src fluids vals body))))
        (($ <sequence> src exps)
         (match exps
           ((head ... tail)
            (let ((tail (loop tail)))
              (and tail
                   (make-sequence src (append head (list tail)))))))))))

  (define (constant-expression? x)
    ;; Return true if X is constant---i.e., if it is known to have no
    ;; effects, does not allocate storage for a mutable object, and does
    ;; not access mutable data (like `car' or toplevel references).
    (let loop ((x x))
      (match x
        (($ <void>) #t)
        (($ <const>) #t)
        (($ <lambda>) #t)
        (($ <lambda-case> _ req opt rest kw inits _ body alternate)
         (and (every loop inits) (loop body)
              (or (not alternate) (loop alternate))))
        (($ <lexical-ref> _ _ gensym)
         (not (assigned-lexical? gensym)))
        (($ <primitive-ref>) #t)
        (($ <conditional> _ condition subsequent alternate)
         (and (loop condition) (loop subsequent) (loop alternate)))
        (($ <application> _ ($ <primitive-ref> _ name) args)
         (and (effect-free-primitive? name)
              (not (constructor-primitive? name))
              (not (accessor-primitive? name))
              (types-check? name args)
              (every loop args)))
        (($ <application> _ ($ <lambda> _ _ body) args)
         (and (loop body) (every loop args)))
        (($ <sequence> _ exps)
         (every loop exps))
        (($ <let> _ _ _ vals body)
         (and (every loop vals) (loop body)))
        (($ <letrec> _ _ _ _ vals body)
         (and (every loop vals) (loop body)))
        (($ <fix> _ _ _ vals body)
         (and (every loop vals) (loop body)))
        (($ <let-values> _ exp body)
         (and (loop exp) (loop body)))
        (($ <prompt> _ tag body handler)
         (and (loop tag) (loop body) (loop handler)))
        (_ #f))))

  (define (prune-bindings ops in-order? body counter ctx build-result)
    ;; This helper handles both `let' and `letrec'/`fix'.  In the latter
    ;; cases we need to make sure that if referenced binding A needs
    ;; as-yet-unreferenced binding B, that B is processed for value.
    ;; Likewise if C, when processed for effect, needs otherwise
    ;; unreferenced D, then D needs to be processed for value too.
    ;;
    (define (referenced? op)
      ;; When we visit lambdas in operator context, we just copy them,
      ;; as we will process their body later.  However this does have
      ;; the problem that any free var referenced by the lambda is not
      ;; marked as needing residualization.  Here we hack around this
      ;; and treat all bindings as referenced if we are in operator
      ;; context.
      (or (eq? ctx 'operator) (operand-residualize? op)))
    
    ;; values := (op ...)
    ;; effects := (op ...)
    (define (residualize values effects)
      ;; Note, values and effects are reversed.
      (cond
       (in-order?
        (let ((values (filter operand-residual-value ops)))
          (if (null? values)
              body
              (build-result (map (compose var-name operand-var) values)
                            (map operand-sym values)
                            (map operand-residual-value values)
                            body))))
       (else
        (let ((body
               (if (null? effects)
                   body
                   (let ((effect-vals (map operand-residual-value effects)))
                     (make-sequence #f (reverse (cons body effect-vals)))))))
          (if (null? values)
              body
              (let ((values (reverse values)))
                (build-result (map (compose var-name operand-var) values)
                              (map operand-sym values)
                              (map operand-residual-value values)
                              body)))))))

    ;; old := (bool ...)
    ;; values := (op ...)
    ;; effects := ((op . value) ...)
    (let prune ((old (map referenced? ops)) (values '()) (effects '()))
      (let lp ((ops* ops) (values values) (effects effects))
        (cond
         ((null? ops*)
          (let ((new (map referenced? ops)))
            (if (not (equal? new old))
                (prune new values '())
                (residualize values
                             (map (lambda (op val)
                                    (set-operand-residual-value! op val)
                                    op)
                                  (map car effects) (map cdr effects))))))
         (else
          (let ((op (car ops*)))
            (cond
             ((memq op values)
              (lp (cdr ops*) values effects))
             ((operand-residual-value op)
              (lp (cdr ops*) (cons op values) effects))
             ((referenced? op)
              (set-operand-residual-value! op (visit-operand op counter 'value))
              (lp (cdr ops*) (cons op values) effects))
             (else
              (lp (cdr ops*)
                  values
                  (let ((effect (visit-operand op counter 'effect)))
                    (if (void? effect)
                        effects
                        (acons op effect effects))))))))))))
  
  (define (small-expression? x limit)
    (let/ec k
      (tree-il-fold
       (lambda (x res)                  ; leaf
         (1+ res))
       (lambda (x res)                  ; down
         (1+ res))
       (lambda (x res)                  ; up
         (if (< res limit)
             res
             (k #f)))
       0 x)
      #t))
  
  (define (extend-env sym op env)
    (vhash-consq (operand-sym op) op (vhash-consq sym op env)))
      
  (let loop ((exp   exp)
             (env   vlist-null)         ; vhash of gensym -> <operand>
             (counter #f)               ; inlined call stack
             (ctx 'value))   ; effect, value, test, operator, or call
    (define (lookup var)
      (cond 
       ((vhash-assq var env) => cdr)
       (else (error "unbound var" var))))

    (define (visit exp ctx)
      (loop exp env counter ctx))

    (define (for-value exp)    (visit exp 'value))
    (define (for-test exp)     (visit exp 'test))
    (define (for-effect exp)   (visit exp 'effect))
    (define (for-call exp)     (visit exp 'call))
    (define (for-tail exp)     (visit exp ctx))

    (if counter
        (record-effort! counter))

    (log 'visit ctx (and=> counter effort-counter)
         (unparse-tree-il exp))

    (match exp
      (($ <const>)
       (case ctx
         ((effect) (make-void #f))
         (else exp)))
      (($ <void>)
       (case ctx
         ((test) (make-const #f #t))
         (else exp)))
      (($ <lexical-ref> _ _ gensym)
       (log 'begin-copy gensym)
       (let ((op (lookup gensym)))
         (cond
          ((eq? ctx 'effect)
           (log 'lexical-for-effect gensym)
           (make-void #f))
          ((eq? ctx 'call)
           ;; Don't propagate copies if we are residualizing a call.
           (log 'residualize-lexical-call gensym op)
           (residualize-lexical op))
          ((var-set? (operand-var op))
           ;; Assigned lexicals don't copy-propagate.
           (log 'assigned-var gensym op)
           (residualize-lexical op))
          ((not (operand-copyable? op))
           ;; We already know that this operand is not copyable.
           (log 'not-copyable gensym op)
           (residualize-lexical op))
          ((and=> (operand-constant-value op)
                  (lambda (x) (or (const? x) (void? x) (primitive-ref? x))))
           ;; A cache hit.
           (let ((val (operand-constant-value op)))
             (log 'memoized-constant gensym val)
             (for-tail val)))
          ((visit-operand op counter ctx recursive-effort-limit operand-size-limit)
           =>
           ;; If we end up deciding to residualize this value instead of
           ;; copying it, save that residualized value.
           (lambda (val)
             (cond
              ((not (constant-expression? val))
               (log 'not-constant gensym op)
               ;; At this point, ctx is operator, test, or value.  A
               ;; value that is non-constant in one context will be
               ;; non-constant in the others, so it's safe to record
               ;; that here, and avoid future visits.
               (set-operand-copyable?! op #f)
               (residualize-lexical op ctx val))
              ((or (const? val)
                   (void? val)
                   (primitive-ref? val))
               ;; Always propagate simple values that cannot lead to
               ;; code bloat.
               (log 'copy-simple gensym val)
               ;; It could be this constant is the result of folding.
               ;; If that is the case, cache it.  This helps loop
               ;; unrolling get farther.
               (if (eq? ctx 'value)
                   (begin
                     (log 'memoize-constant gensym val)
                     (set-operand-constant-value! op val)))
               val)
              ((= 1 (var-refcount (operand-var op)))
               ;; Always propagate values referenced only once.
               (log 'copy-single gensym val)
               val)
              ;; FIXME: do demand-driven size accounting rather than
              ;; these heuristics.
              ((eq? ctx 'operator)
               ;; A pure expression in the operator position.  Inline
               ;; if it's a lambda that's small enough.
               (if (and (lambda? val)
                        (small-expression? val operator-size-limit))
                   (begin
                     (log 'copy-operator gensym val)
                     val)
                   (begin
                     (log 'too-big-for-operator gensym val)
                     (residualize-lexical op ctx val))))
              (else
               ;; A pure expression, processed for call or for value.
               ;; Don't inline lambdas, because they will probably won't
               ;; fold because we don't know the operator.
               (if (and (small-expression? val value-size-limit)
                        (not (tree-il-any lambda? val)))
                   (begin
                     (log 'copy-value gensym val)
                     val)
                   (begin
                     (log 'too-big-or-has-lambda gensym val)
                     (residualize-lexical op ctx val)))))))
          (else
           ;; Visit failed.  Either the operand isn't bound, as in
           ;; lambda formal parameters, or the copy was aborted.
           (log 'unbound-or-aborted gensym op)
           (residualize-lexical op)))))
      (($ <lexical-set> src name gensym exp)
       (let ((op (lookup gensym)))
         (if (zero? (var-refcount (operand-var op)))
             (let ((exp (for-effect exp)))
               (if (void? exp)
                   exp
                   (make-sequence src (list exp (make-void #f)))))
             (begin
               (set-operand-residualize?! op #t)
               (make-lexical-set src name (operand-sym op) (for-value exp))))))
      (($ <let> src names gensyms vals body)
       (let* ((vars (map lookup-var gensyms))
              (new (fresh-gensyms vars))
              (ops (make-bound-operands vars new vals
                                        (lambda (exp counter ctx)
                                          (loop exp env counter ctx))))
              (env (fold extend-env env gensyms ops))
              (body (loop body env counter ctx)))
         (cond
          ((const? body)
           (for-tail (make-sequence src (append vals (list body)))))
          ((and (lexical-ref? body)
                (memq (lexical-ref-gensym body) new))
           (let ((sym (lexical-ref-gensym body))
                 (pairs (map cons new vals)))
             ;; (let ((x foo) (y bar) ...) x) => (begin bar ... foo)
             (for-tail
              (make-sequence
               src
               (append (map cdr (alist-delete sym pairs eq?))
                       (list (assq-ref pairs sym)))))))
          (else
           ;; Only include bindings for which lexical references
           ;; have been residualized.
           (prune-bindings ops #f body counter ctx
                           (lambda (names gensyms vals body)
                             (if (null? names) (error "what!" names))
                             (make-let src names gensyms vals body)))))))
      (($ <letrec> src in-order? names gensyms vals body)
       ;; Note the difference from the `let' case: here we use letrec*
       ;; so that the `visit' procedure for the new operands closes over
       ;; an environment that includes the operands.
       (letrec* ((visit (lambda (exp counter ctx)
                          (loop exp env* counter ctx)))
                 (vars (map lookup-var gensyms))
                 (new (fresh-gensyms vars))
                 (ops (make-bound-operands vars new vals visit))
                 (env* (fold extend-env env gensyms ops))
                 (body* (visit body counter ctx)))
         (if (and (const? body*)
                  (every constant-expression? vals))
             body*
             (prune-bindings ops in-order? body* counter ctx
                             (lambda (names gensyms vals body)
                               (make-letrec src in-order?
                                            names gensyms vals body))))))
      (($ <fix> src names gensyms vals body)
       (letrec* ((visit (lambda (exp counter ctx)
                          (loop exp env* counter ctx)))
                 (vars (map lookup-var gensyms))
                 (new (fresh-gensyms vars))
                 (ops (make-bound-operands vars new vals visit))
                 (env* (fold extend-env env gensyms ops))
                 (body* (visit body counter ctx)))
         (if (const? body*)
             body*
             (prune-bindings ops #f body* counter ctx
                             (lambda (names gensyms vals body)
                               (make-fix src names gensyms vals body))))))
      (($ <let-values> lv-src producer consumer)
       ;; Peval the producer, then try to inline the consumer into
       ;; the producer.  If that succeeds, peval again.  Otherwise
       ;; reconstruct the let-values, pevaling the consumer.
       (let ((producer (for-value producer)))
         (or (match consumer
               (($ <lambda-case> src req #f #f #f () gensyms body #f)
                (cond
                 ((inline-values producer src req gensyms body)
                  => for-tail)
                 (else #f)))
               (_ #f))
             (make-let-values lv-src producer (for-tail consumer)))))
      (($ <dynwind> src winder body unwinder)
       (make-dynwind src (for-value winder) (for-tail body)
                     (for-value unwinder)))
      (($ <dynlet> src fluids vals body)
       (make-dynlet src (map for-value fluids) (map for-value vals)
                    (for-tail body)))
      (($ <dynref> src fluid)
       (make-dynref src (for-value fluid)))
      (($ <dynset> src fluid exp)
       (make-dynset src (for-value fluid) (for-value exp)))
      (($ <toplevel-ref> src (? effect-free-primitive? name))
       (if (local-toplevel? name)
           exp
           (let ((exp (resolve-primitives! exp cenv)))
             (if (primitive-ref? exp)
                 (for-tail exp)
                 exp))))
      (($ <toplevel-ref>)
       ;; todo: open private local bindings.
       exp)
      (($ <module-ref> src module (? effect-free-primitive? name) #f)
       (let ((module (false-if-exception
                      (resolve-module module #:ensure #f))))
         (if (module? module)
             (let ((var (module-variable module name)))
               (if (eq? var (module-variable the-scm-module name))
                   (make-primitive-ref src name)
                   exp))
             exp)))
      (($ <module-ref>)
       exp)
      (($ <module-set> src mod name public? exp)
       (make-module-set src mod name public? (for-value exp)))
      (($ <toplevel-define> src name exp)
       (make-toplevel-define src name (for-value exp)))
      (($ <toplevel-set> src name exp)
       (make-toplevel-set src name (for-value exp)))
      (($ <primitive-ref>)
       (case ctx
         ((effect) (make-void #f))
         ((test) (make-const #f #t))
         (else exp)))
      (($ <conditional> src condition subsequent alternate)
       (let ((condition (for-test condition)))
         (if (const? condition)
             (if (const-exp condition)
                 (for-tail subsequent)
                 (for-tail alternate))
             (make-conditional src condition
                               (for-tail subsequent)
                               (for-tail alternate)))))
      (($ <application> src
          ($ <primitive-ref> _ '@call-with-values)
          (producer
           ($ <lambda> _ _
              (and consumer
                   ;; No optional or kwargs.
                   ($ <lambda-case>
                      _ req #f rest #f () gensyms body #f)))))
       (for-tail (make-let-values src (make-application src producer '())
                                  consumer)))

      (($ <application> src orig-proc orig-args)
       ;; todo: augment the global env with specialized functions
       (let ((proc (visit orig-proc 'operator)))
         (match proc
           (($ <primitive-ref> _ (? constructor-primitive? name))
            (cond
             ((and (memq ctx '(effect test))
                   (match (cons name orig-args)
                     ((or ('cons _ _)
                          ('list . _)
                          ('vector . _)
                          ('make-prompt-tag)
                          ('make-prompt-tag ($ <const> _ (? string?))))
                      #t)
                     (_ #f)))
              ;; Some expressions can be folded without visiting the
              ;; arguments for value.
              (let ((res (if (eq? ctx 'effect)
                             (make-void #f)
                             (make-const #f #t))))
                (for-tail (make-sequence src (append orig-args (list res))))))
             (else
              (match (cons name (map for-value orig-args))
                (('cons head tail)
                 (match tail
                   (($ <const> src ())
                    (make-application src (make-primitive-ref #f 'list)
                                      (list head)))
                   (($ <application> src ($ <primitive-ref> _ 'list) elts)
                    (make-application src (make-primitive-ref #f 'list)
                                      (cons head elts)))
                   (_ (make-application src proc (list head tail)))))
                ((_ . args)
                 (make-application src proc args))))))
           (($ <primitive-ref> _ (? accessor-primitive? name))
            (match (cons name (map for-value orig-args))
              ;; FIXME: these for-tail recursions could take place outside
              ;; an effort counter.
              (('car ($ <application> src ($ <primitive-ref> _ 'cons) (head tail)))
               (for-tail (make-sequence src (list tail head))))
              (('cdr ($ <application> src ($ <primitive-ref> _ 'cons) (head tail)))
               (for-tail (make-sequence src (list head tail))))
              (('car ($ <application> src ($ <primitive-ref> _ 'list) (head . tail)))
               (for-tail (make-sequence src (append tail (list head)))))
              (('cdr ($ <application> src ($ <primitive-ref> _ 'list) (head . tail)))
               (for-tail (make-sequence
                          src
                          (list head
                                (make-application
                                 src (make-primitive-ref #f 'list) tail)))))
                  
              (('car ($ <const> src (head . tail)))
               (for-tail (make-const src head)))
              (('cdr ($ <const> src (head . tail)))
               (for-tail (make-const src tail)))
              (((or 'memq 'memv) k ($ <const> _ (elts ...)))
               ;; FIXME: factor 
               (case ctx
                 ((effect)
                  (for-tail
                   (make-sequence src (list k (make-void #f)))))
                 ((test)
                  (cond
                   ((const? k)
                    ;; A shortcut.  The `else' case would handle it, but
                    ;; this way is faster.
                    (let ((member (case name ((memq) memq) ((memv) memv))))
                      (make-const #f (and (member (const-exp k) elts) #t))))
                   ((null? elts)
                    (for-tail
                     (make-sequence src (list k (make-const #f #f)))))
                   (else
                    (let ((t (gensym "t "))
                          (eq (if (eq? name 'memq) 'eq? 'eqv?)))
                      (record-new-temporary! 't t (length elts))
                      (for-tail
                       (make-let
                        src (list 't) (list t) (list k)
                        (let lp ((elts elts))
                          (define test
                            (make-application
                             #f (make-primitive-ref #f eq)
                             (list (make-lexical-ref #f 't t)
                                   (make-const #f (car elts)))))
                          (if (null? (cdr elts))
                              test
                              (make-conditional src test
                                                (make-const #f #t)
                                                (lp (cdr elts)))))))))))
                 (else
                  (cond
                   ((const? k)
                    (let ((member (case name ((memq) memq) ((memv) memv))))
                      (make-const #f (member (const-exp k) elts))))
                   ((null? elts)
                    (for-tail (make-sequence src (list k (make-const #f #f)))))
                   (else
                    (make-application src proc (list k (make-const #f elts))))))))
              ((_ . args)
               (or (fold-constants src name args ctx)
                   (make-application src proc args)))))
           (($ <primitive-ref> _ (? effect-free-primitive? name))
            (let ((args (map for-value orig-args)))
              (or (fold-constants src name args ctx)
                  (make-application src proc args))))
           (($ <lambda> _ _
               ($ <lambda-case> _ req opt #f #f inits gensyms body #f))
            ;; Simple case: no rest, no keyword arguments.
            ;; todo: handle the more complex cases
            (let* ((nargs (length orig-args))
                   (nreq (length req))
                   (nopt (if opt (length opt) 0))
                   (key (source-expression proc)))
              (cond
               ((or (< nargs nreq) (> nargs (+ nreq nopt)))
                ;; An error, or effecting arguments.
                (make-application src (for-call orig-proc)
                                  (map for-value orig-args)))
               ((or (and=> (find-counter key counter) counter-recursive?)
                    (lambda? orig-proc))
                ;; A recursive call, or a lambda in the operator
                ;; position of the source expression.  Process again in
                ;; tail context.
                ;;
                ;; In the recursive case, mark intervening counters as
                ;; recursive, so we can handle a toplevel counter that
                ;; recurses mutually with some other procedure.
                ;; Otherwise, the next time we see the other procedure,
                ;; the effort limit would be clamped to 100.
                ;;
                (let ((found (find-counter key counter)))
                  (if (and found (counter-recursive? found))
                      (let lp ((counter counter))
                        (if (not (eq? counter found))
                            (begin
                              (set-counter-recursive?! counter #t)
                              (lp (counter-prev counter)))))))

                (log 'inline-recurse key)
                (loop (make-let src (append req (or opt '()))
                                gensyms
                                (append orig-args
                                        (drop inits (- nargs nreq)))
                                body)
                  env counter ctx))
               (else
                ;; An integration at the top-level, the first
                ;; recursion of a recursive procedure, or a nested
                ;; integration of a procedure that hasn't been seen
                ;; yet.
                (log 'inline-begin exp)
                (let/ec k
                  (define (abort)
                    (log 'inline-abort exp)
                    (k (make-application src (for-call orig-proc)
                                         (map for-value orig-args))))
                  (define new-counter
                    (cond
                     ;; These first two cases will transfer effort
                     ;; from the current counter into the new
                     ;; counter.
                     ((find-counter key counter)
                      => (lambda (prev)
                           (make-recursive-counter recursive-effort-limit
                                                   operand-size-limit
                                                   prev counter)))
                     (counter
                      (make-nested-counter abort key counter))
                     ;; This case opens a new account, effectively
                     ;; printing money.  It should only do so once
                     ;; for each call site in the source program.
                     (else
                      (make-top-counter effort-limit operand-size-limit
                                        abort key))))
                  (define result
                    (loop (make-let src (append req (or opt '()))
                                    gensyms
                                    (append orig-args
                                            (drop inits (- nargs nreq)))
                                    body)
                      env new-counter ctx))
                      
                  (if counter
                      ;; The nested inlining attempt succeeded.
                      ;; Deposit the unspent effort and size back
                      ;; into the current counter.
                      (transfer! new-counter counter))

                  (log 'inline-end result exp)
                  result)))))
           (_
            (make-application src (for-call orig-proc)
                              (map for-value orig-args))))))
      (($ <lambda> src meta body)
       (case ctx
         ((effect) (make-void #f))
         ((test) (make-const #f #t))
         ((operator) exp)
         (else (record-source-expression!
                exp
                (make-lambda src meta (for-tail body))))))
      (($ <lambda-case> src req opt rest kw inits gensyms body alt)
       (let* ((vars (map lookup-var gensyms))
              (new (fresh-gensyms vars))
              (env (fold extend-env env gensyms
                         (make-unbound-operands vars new)))
              (new-sym (lambda (old)
                         (operand-sym (cdr (vhash-assq old env))))))
         (make-lambda-case src req opt rest
                           (match kw
                             ((aok? (kw name old) ...)
                              (cons aok? (map list kw name (map new-sym old))))
                             (_ #f))
                           (map (cut loop <> env counter 'value) inits)
                           new
                           (loop body env counter ctx)
                           (and alt (for-tail alt)))))
      (($ <sequence> src exps)
       (let lp ((exps exps) (effects '()))
         (match exps
           ((last)
            (if (null? effects)
                (for-tail last)
                (make-sequence
                 src
                 (reverse (cons (for-tail last) effects)))))
           ((head . rest)
            (let ((head (for-effect head)))
              (cond
               ((sequence? head)
                (lp (append (sequence-exps head) rest) effects))
               ((void? head)
                (lp rest effects))
               (else
                (lp rest (cons head effects)))))))))
      (($ <prompt> src tag body handler)
       (define (singly-used-definition x)
         (cond
          ((and (lexical-ref? x)
                ;; Only fetch definitions with single uses.
                (= (lexical-refcount (lexical-ref-gensym x)) 1)
                (lookup (lexical-ref-gensym x)))
           => (lambda (x)
                (singly-used-definition (visit-operand x counter 'value 10 10))))
          (else x)))
       (match (singly-used-definition tag)
         (($ <application> _ ($ <primitive-ref> _ 'make-prompt-tag)
             (or () ((? constant-expression?))))
          ;; There is no way that an <abort> could know the tag
          ;; for this <prompt>, so we can elide the <prompt>
          ;; entirely.
          (for-tail body))
         (_
          (make-prompt src (for-value tag) (for-tail body)
                       (for-value handler)))))
      (($ <abort> src tag args tail)
       (make-abort src (for-value tag) (map for-value args)
                   (for-value tail))))))
