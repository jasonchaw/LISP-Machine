;;; -*- Mode:LISP; Package:COLD; Base:8; Readtable:T -*-
;;; (c) Copyright 1985, Lisp Machine Incorporated.

;;; Cold load utilities for examining the load and initializing the
;;; VIRTUAL-PAGE-DATA.  KHS 850324.

;;; Simulated subprimitives for the target world.

(defun  p-ldb (byte address)
  (ldb byte (vread address)))

(defun  p-cdr-code (address)
  (ldb sym:%%q-cdr-code (vread address)))

(defun  p-data-type (address)
  (ldb sym:%%q-data-type (vread address)))

(defun  p-pointer (address)
  (logand q-pointer-mask (vread address)))

(defun  p-contents-offset (address offset)
  (logand q-pointer-mask (vread (+ address offset))))

;;;

(defun print-object (address)
  (flet ((print (address indentation)
           (terpri)
           (dotimes (i indentation) (tyo #/space))
           (format t "~8O ~A ~A ~20,5T~O"
                   address
                   (nth ( p-cdr-code address) sym:q-cdr-codes)
                   (nth ( p-data-type address) sym:q-data-types)
                   ( p-pointer address))))
    (loop initially (print address 0)
          for i from 1 below (object-boxed-size address)
          do (print (+ address i) 2))))

(defun scan-area (area)
  (loop with origin = (get-area-origin area)
        with bound = (get-area-free-pointer area)
        for address = origin then (+ address (object-total-size address))
        until ( address bound)
        do (print-object address)))

;;; Simulated STRUCTURE-INFO for the target world.

(defvar *object-size-table* (make-array 40))    ;Data-type dispatch for OBJECT-SIZE.

(defun object-boxed-size (address)
  (nth-value 0 (object-size address)))

(defun object-total-size (address)
  (nth-value 1 (object-size address)))

(defun object-size (address)
  (declare (values boxed-size total-size))
  (let ((entry (aref *object-size-table* ( p-data-type address))))
    (if (integerp entry)
        (values entry entry)
      (funcall entry address))))

(defmacro define-object-size (data-type &body body)
  (if (integerp (car body))
      `(setf (aref *object-size-table* ,(symeval data-type)) ,@body)
    `(setf (aref *object-size-table* ,(symeval data-type))
           (compile-lambda '(lambda (address) ,@body)))))

(defun list-object-size (address)
  (loop for i from 0 to 100000
        for a = (+ address i)
        for s = 1 then (1+ s)
        when (memq ( p-data-type a)
                   (list sym:dtp-symbol-header
                         sym:dtp-header
                         sym:dtp-array-header
                         sym:dtp-instance-header))
          do (return (1- s) (1- s))
        when (or (= ( p-cdr-code a) sym:cdr-error)
                 (= ( p-cdr-code a) sym:cdr-nil))
          do (return s s)))

(define-object-size sym:dtp-trap 1)
(define-object-size sym:dtp-null (list-object-size address))
(define-object-size sym:dtp-free (list-object-size address))
(define-object-size sym:dtp-symbol (list-object-size address))
(define-object-size sym:dtp-symbol-header 5)
(define-object-size sym:dtp-fix (list-object-size address))
(define-object-size sym:dtp-extended-number (list-object-size address))

(define-object-size sym:dtp-header
  (select ( p-ldb sym:%%header-type-field address)
    ((sym:%header-type-fef
      sym:%header-type-fast-fef-fixed-args-no-locals
      sym:%header-type-fast-fef-var-args-no-locals
      sym:%header-type-fast-fef-fixed-args-with-locals
      sym:%header-type-fast-fef-var-args-with-locals)
     (let ((boxed ( p-ldb sym:%%fefh-pc-in-words address)))
       (values boxed ( p-contents-offset address sym:%fefhi-storage-length))))
    (sym:%header-type-array-leader
      (let ((length ( p-ldb sym:%%array-leader-length address)))
        (values length length)))
    (sym:%header-type-flonum
      (values 1 3))
    (sym:%header-type-complex
      (values 3 3))
    (sym:%header-type-bignum
      (values 1 (1+ ( p-ldb #o0022 address))))
    (sym:%header-type-rational
      (values 3 3))
    (sym:%header-type-error
      (ferror nil "%HEADER-TYPE-ERROR at ~O" address))
    (sym:%header-type-list
      (values 1 1))
    (otherwise
      (ferror nil "Unknown header type at ~O" address))))

(define-object-size sym:dtp-gc-forward (list-object-size address))
(define-object-size sym:dtp-external-value-cell-pointer (list-object-size address))
(define-object-size sym:dtp-one-q-forward (list-object-size address))

(define-object-size sym:dtp-header-forward
  (break)
  (do ((scan (1+ address) (1+ scan)))
      ((neq ( p-data-type scan) sym:dtp-body-forward)
       (values 1 (- scan address)))))

(define-object-size sym:dtp-body-forward 1)
(define-object-size sym:dtp-locative (list-object-size address))
(define-object-size sym:dtp-list (list-object-size address))
(define-object-size sym:dtp-u-entry (list-object-size address))
(define-object-size sym:dtp-fef-pointer (list-object-size address))
(define-object-size sym:dtp-array-pointer (list-object-size address))

(define-object-size sym:dtp-array-header
  ;; This is very dependent on the current world values.  This will be fixed as
  ;; soon as ARRAY-BOXED-WORDS-PER-ELEMENT is defined for the cold load.
  (flet ((boxed-array-size (address words-per-element)
           (let ((length) (offset))
             (cond ((zerop ( p-ldb sym:%%array-long-length-flag address))
                    (setq length ( p-ldb sym:%%array-index-length-if-short address))
                    (setq offset ( p-ldb sym:%%array-number-dimensions address)))
                   (t
                    (setq length ( p-contents-offset address 1))
                    (setq offset (1+ ( p-ldb sym:%%array-number-dimensions address)))))
             (setq length (+ offset (ceiling (* length words-per-element) 1)))
             (values length length)))
         (unboxed-array-size (address words-per-element)
           (let ((length) (offset))
             (cond ((zerop ( p-ldb sym:%%array-long-length-flag address))
                    (setq length ( p-ldb sym:%%array-index-length-if-short address))
                    (setq offset ( p-ldb sym:%%array-number-dimensions address)))
                   (t
                    (setq length ( p-contents-offset address 1))
                    (setq offset (1+ ( p-ldb sym:%%array-number-dimensions address)))))
             (values offset (+ offset (ceiling (* length words-per-element) 1))))))
    (if (not (zerop ( p-ldb sym:%%array-displaced-bit address)))
        (let ((boxed-size (+ (max 1 ( p-ldb sym:%%array-number-dimensions address))
                             ( p-ldb sym:%%array-index-length-if-short address))))
          (values boxed-size boxed-size))
      (case ( p-ldb sym:%%array-type-field address)
        (1  (unboxed-array-size address 1\40))  ;art-1b
        (2  (unboxed-array-size address 1\20))  ;art-2b
        (3  (unboxed-array-size address 1\8))   ;art-4b
        (4  (unboxed-array-size address 1\4))   ;art-8b
        (5  (unboxed-array-size address 1\2))   ;art-16b
        (6  (unboxed-array-size address 1))     ;art-32b
        (7  (boxed-array-size address 1))       ;art-q
        (10 (boxed-array-size address 1))       ;art-q-list
        (11 (unboxed-array-size address 1\4))   ;art-string
        (12 (boxed-array-size address 1))       ;art-stack-group-head
        (13 (unboxed-array-size address 1))     ;art-special-pdl
        (14 (unboxed-array-size address 1\2))   ;art-half-fix
        (15 (unboxed-array-size address 1))     ;art-regular-pdl
        (16 (unboxed-array-size address 2))     ;art-float
        (17 (unboxed-array-size address 1))     ;art-fps-float
        (20 (unboxed-array-size address 1\2))   ;art-fat-string
        (21 (unboxed-array-size address 4))     ;art-complex-float
        (22 (boxed-array-size address 2))       ;art-complex
        (23 (unboxed-array-size address 2))     ;art-complex-fps-float
        ))))

(define-object-size sym:dtp-stack-group (list-object-size address))
(define-object-size sym:dtp-closure (list-object-size address))
(define-object-size sym:dtp-small-flonum (list-object-size address))
(define-object-size sym:dtp-select-method (list-object-size address))
(define-object-size sym:dtp-instance (list-object-size address))

(define-object-size sym:dtp-instance-header
  (let ((boxed ( p-contents-offset ( p-pointer address) sym:%instance-descriptor-size)))
    (values boxed boxed)))

(define-object-size sym:dtp-entity (list-object-size address))
(define-object-size sym:dtp-stack-closure (list-object-size address))
(define-object-size sym:dtp-self-ref-pointer (list-object-size address))
(define-object-size sym:dtp-character (list-object-size address))

;;; Structure handles.

(defun page-number (address) (ldb #o1021 address))
(defun page-index (address) (ldb #o0010 address))

(defvar *virtual-page-data-origin*)

(defun read-structure-handle (page)
  (declare (values first-header initial-qs))
  (let ((vpd (vread (+ *virtual-page-data-origin* page))))
    (values (ldb sym:%%virtual-page-first-header vpd)
            (ldb sym:%%virtual-page-initial-qs vpd))))

(defun write-structure-handle (page first-header initial-qs)
  (vwrite (+ *virtual-page-data-origin* page)
          (dpb first-header
               sym:%%virtual-page-first-header
               (dpb initial-qs
                    sym:%%virtual-page-initial-qs
                    (vread (+ *virtual-page-data-origin* page))))))

(defun initialize-structure-handles-for-object (address)
  (multiple-value-bind (first-header initial-qs)
      (read-structure-handle (page-number address))
    (when (= first-header 400)
      (write-structure-handle (page-number address) (page-index address) initial-qs)))
  (loop for boxed = (- (object-boxed-size address) (- 400 (page-index address)))
            then (- boxed 400)
        for page = (1+ (page-number address)) then (1+ page)
        until ( boxed 0)
        when ( boxed 400)
          do (write-structure-handle page 400 400)
        else do (write-structure-handle page 400 boxed)))

(defun initialize-structure-handles-for-area (area)
  (format t "~% ~A" area)
  (loop with origin = (get-area-origin area)
        with start = (page-number origin)
        with stop = (+ start (page-number (get-area-bound area)))
        for page from start below stop
        do (write-structure-handle page 400 0))
  (loop with origin = (get-area-origin area)
        with bound = (get-area-free-pointer area)
        for object = origin then (+ object (object-total-size object))
        until ( object bound)
        do (initialize-structure-handles-for-object object)))

(defun verify-structure-handles-in-area (area)
  (loop with origin = (get-area-origin area)
        with bound = (get-area-free-pointer area)
        for page from (page-number origin) to (page-number (1- bound))
        do (multiple-value-bind (first-header initial-qs)
               (read-structure-handle page)
             (if (= first-header 400)
                 (format t "~%   ")
               (print-object (+ (* page 400) first-header))))))
