;;;
;;; propagate.scm - propagate slot option
;;;
;;;  Copyright(C) 2002 by Shiro Kawai (shiro@acm.org)
;;;
;;;  Permission to use, copy, modify, distribute this software and
;;;  accompanying documentation for any purpose is hereby granted,
;;;  provided that existing copyright notices are retained in all
;;;  copies and that this notice is included verbatim in all
;;;  distributions.
;;;  This software is provided as is, without express or implied
;;;  warranty.  In no circumstances the author(s) shall be liable
;;;  for any damages arising out of the use of this software.
;;;
;;;  $Id: propagate.scm,v 1.2 2002-12-04 11:12:23 shirok Exp $
;;;

;; EXPERIMENTAL.   THE API MAY CHANGE.

(define-module gauche.mop.propagate
  (use srfi-2)
  (export <propagate-meta> <propagate-mixin>)
  )
(select-module gauche.mop.propagate)

;; 'propagate' slot option sends get/set request to other object.
;; The idea is taken from STk's "composite metaclass".
;;
;; The slot must have ':propagated' allocation, and ':propagate' option.
;; ':Propagate' option may be a symbol or a list of two elements.
;; Suppose the slot foo is a propagated slot.  If a symbol bar is given
;; to the :propagate option, reading of the slot returns
;; (slot-ref (slot-ref obj 'bar) 'foo), and writing to the slot causes
;; (slot-set! (slot-ref obj 'bar) 'foo value).  If a list (bar baz)
;; is given, baz is used as the actual slot name instead of foo.

(define-class <propagate-meta> (<class>)
  ())

(define-method compute-get-n-set ((class <propagate-meta>) slot)
  (let ((name  (slot-definition-name slot))
        (alloc (slot-definition-allocation slot)))
    (cond ((eq? alloc :propagated)
           (let1 prop (or (slot-definition-option slot :propagate #f)
                          (slot-definition-option slot :propagate-to #f))
             (cond ((symbol? prop)
                    (list (lambda (o)
                            (slot-ref (slot-ref o prop) name))
                          (lambda (o v)
                            (slot-set! (slot-ref o prop) name v))))
                   ((and-let* (((list? prop))
                               ((= (length prop) 2))
                               (object-slot (car prop))
                               ((symbol? object-slot))
                               (real-slot (cadr prop))
                               ((symbol? real-slot)))
                      (list (lambda (o)
                              (slot-ref (slot-ref o object-slot) real-slot))
                            (lambda (o v)
                              (slot-set! (slot-ref o object-slot) real-slot v))
                            )))
                   (else
                    (errorf "bad :propagated slot option value ~s for slot ~s of class ~s"
                            prop name class))
                   )))
          (else (next-method)))))

;; convenient to be used as a mixin
(define-class <propagate-mixin> ()
  ()
  :metaclass <propagate-meta>)

(provide "gauche/mop/propagate")
