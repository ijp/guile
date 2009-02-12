;;; Guile VM specific syntaxes and utilities

;; Copyright (C) 2001 Free Software Foundation, Inc

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA

;;; Code:

(define-module (system base syntax)
  #:export (%compute-initargs)
  #:export-syntax (define-type define-record define-record/keywords
                   record-case))


;;;
;;; Type
;;;

(define-macro (define-type name . rest)
  (let ((name (if (pair? name) (car name) name))
        (opts (if (pair? name) (cdr name) '())))
    (let ((printer (kw-arg-ref opts #:printer)))
      `(begin ,@(map (lambda (def)
                       `(define-record ,(if printer
                                            `(,(car def) ,printer)
                                            (car def))
                          ,@(cdr def)))
                     rest)))))


;;;
;;; Record
;;;

(define (symbol-trim-both sym pred)
  (string->symbol (string-trim-both (symbol->string sym) pred)))

(define-macro (define-record name-form . slots)
  (let* ((name (if (pair? name-form) (car name-form) name-form))
         (printer (and (pair? name-form) (cadr name-form)))
         (slot-names (map (lambda (slot) (if (pair? slot) (car slot) slot))
                          slots))
         (stem (symbol-trim-both name (list->char-set '(#\< #\>)))))
    `(begin
       (define ,name (make-record-type ,(symbol->string name) ',slot-names
                                       ,@(if printer (list printer) '())))
       ,(let* ((reqs (let lp ((slots slots))
                       (if (or (null? slots) (not (symbol? (car slots))))
                           '()
                           (cons (car slots) (lp (cdr slots))))))
               (opts (list-tail slots (length reqs)))
               (tail (gensym)))
          `(define (,(symbol-append 'make- stem) ,@reqs . ,tail)
             (let ,(map (lambda (o)
                          `(,(car o) (cond ((null? ,tail) ,(cadr o))
                                           (else (let ((_x (car ,tail)))
                                                   (set! ,tail (cdr ,tail))
                                                   _x)))))
                        opts)
               (make-struct ,name 0 ,@slot-names))))
       (define ,(symbol-append stem '?) (record-predicate ,name))
       ,@(map (lambda (sname)
                `(define ,(symbol-append stem '- sname)
                   (make-procedure-with-setter
                    (record-accessor ,name ',sname)
                    (record-modifier ,name ',sname))))
              slot-names))))

;; like the former, but accepting keyword arguments in addition to
;; optional arguments
(define-macro (define-record/keywords name-form . slots)
  (let* ((name (if (pair? name-form) (car name-form) name-form))
         (printer (and (pair? name-form) (cadr name-form)))
         (slot-names (map (lambda (slot) (if (pair? slot) (car slot) slot))
                          slots))
         (stem (symbol-trim-both name (list->char-set '(#\< #\>)))))
    `(begin
       (define ,name (make-record-type ,(symbol->string name) ',slot-names
                                       ,@(if printer (list printer) '())))
       (define ,(symbol-append 'make- stem)
         (let ((slots (list ,@(map (lambda (slot)
                                     (if (pair? slot)
                                         `(cons ',(car slot) ,(cadr slot))
                                         `',slot))
                                   slots)))
               (constructor (record-constructor ,name)))
           (lambda args
             (apply constructor (%compute-initargs args slots)))))
       (define ,(symbol-append stem '?) (record-predicate ,name))
       ,@(map (lambda (sname)
                `(define ,(symbol-append stem '- sname)
                   (make-procedure-with-setter
                    (record-accessor ,name ',sname)
                    (record-modifier ,name ',sname))))
              slot-names))))

(define (%compute-initargs args slots)
  (define (finish out)
    (map (lambda (slot)
           (let ((name (if (pair? slot) (car slot) slot)))
             (cond ((assq name out) => cdr)
                   ((pair? slot) (cdr slot))
                   (else (error "unbound slot" args slots name)))))
         slots))
  (let lp ((in args) (positional slots) (out '()))
    (cond
     ((null? in)
      (finish out))
     ((keyword? (car in))
      (let ((sym (keyword->symbol (car in))))
        (cond
         ((and (not (memq sym slots))
               (not (assq sym (filter pair? slots))))
          (error "unknown slot" sym))
         ((assq sym out) (error "slot already set" sym out))
         (else (lp (cddr in) '() (acons sym (cadr in) out))))))
     ((null? positional)
      (error "too many initargs" args slots))
     (else
      (lp (cdr in) (cdr positional)
          (let ((slot (car positional)))
            (acons (if (pair? slot) (car slot) slot)
                   (car in)
                   out)))))))

;; So, dear reader. It is pleasant indeed around this fire or at this
;; cafe or in this room, is it not? I think so too.
;;
;; This macro used to generate code that looked like this:
;;
;;  `(((record-predicate ,record-type) ,r)
;;    (let ,(map (lambda (slot)
;;                 (if (pair? slot)
;;                     `(,(car slot) ((record-accessor ,record-type ',(cadr slot)) ,r))
;;                     `(,slot ((record-accessor ,record-type ',slot) ,r))))
;;               slots)
;;      ,@body)))))
;;
;; But this was a hot spot, so computing all those predicates and
;; accessors all the time was getting expensive, so we did a terrible
;; thing: we decided that since above we're already defining accessors
;; and predicates with computed names, we might as well just rely on that fact here.
;;
;; It's a bit nasty, I agree. But it is fast.
;;
;;scheme@(guile-user)> (with-statprof #:hz 1000 #:full-stacks? #t (resolve-module '(oop goops)))%     cumulative   self             
;; time   seconds     seconds      name
;;   8.82      0.03      0.01  glil->assembly
;;   8.82      0.01      0.01  record-type-fields
;;   5.88      0.01      0.01  %compute-initargs
;;   5.88      0.01      0.01  list-index


(define-macro (record-case record . clauses)
  (let ((r (gensym))
        (rtd (gensym)))
    (define (process-clause clause)
      (if (eq? (car clause) 'else)
          clause
          (let ((record-type (caar clause))
                (slots (cdar clause))
                (body (cdr clause)))
            (let ((stem (symbol-trim-both record-type (list->char-set '(#\< #\>)))))
              `((eq? ,rtd ,record-type)
                (let ,(map (lambda (slot)
                             (if (pair? slot)
                                 `(,(car slot) (,(symbol-append stem '- (cadr slot)) ,r))
                                 `(,slot (,(symbol-append stem '- slot) ,r))))
                           slots)
                  ,@body))))))
    `(let* ((,r ,record)
            (,rtd (struct-vtable ,r)))
       (cond ,@(let ((clauses (map process-clause clauses)))
                 (if (assq 'else clauses)
                     clauses
                     (append clauses `((else (error "unhandled record" ,r))))))))))
