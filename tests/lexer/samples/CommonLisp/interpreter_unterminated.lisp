;;;; interpreter_unterminated.lisp — second Common Lisp sample.
;;;; A tiny Scheme-ish evaluator; the file ends inside an unbalanced nested block comment.

(defpackage :mini-eval
  (:use :common-lisp)
  (:export #:evaluate #:repl #:*global-env*))

(in-package :mini-eval)

(define-condition eval-error (error)
  ((form :initarg :form :reader eval-error-form)
   (reason :initarg :reason :reader eval-error-reason))
  (:report (lambda (c stream)
             (format stream "Cannot evaluate ~S: ~A"
                     (eval-error-form c) (eval-error-reason c)))))

(defstruct (env (:constructor %make-env (vars parent)))
  (vars (make-hash-table :test #'eq))
  (parent nil))

(defun make-env (&optional parent)
  (%make-env (make-hash-table :test #'eq) parent))

(defun env-lookup (env sym)
  (loop for e = env then (env-parent e)
        while e
        do (multiple-value-bind (val found) (gethash sym (env-vars e))
             (when found (return-from env-lookup val))))
  (error 'eval-error :form sym :reason "unbound variable"))

(defun env-define (env sym val)
  (setf (gethash sym (env-vars env)) val))

(defvar *global-env* (make-env))

(defmacro defprimitive (name lambda-list &body body)
  `(env-define *global-env* ',name (lambda ,lambda-list ,@body)))

(defprimitive + (&rest xs) (reduce #'+ xs))
(defprimitive - (x &rest xs) (if xs (reduce #'- xs :initial-value x) (- x)))
(defprimitive * (&rest xs) (reduce #'* xs))
(defprimitive / (x &rest xs) (if xs (reduce #'/ xs :initial-value x) (/ x)))
(defprimitive = (a b) (= a b))
(defprimitive < (a b) (< a b))
(defprimitive car (x) (car x))
(defprimitive cdr (x) (cdr x))
(defprimitive cons (a b) (cons a b))
(defprimitive list (&rest xs) xs)
(defprimitive display (x) (format t "~A" x) x)
(defprimitive newline () (terpri) nil)

(defstruct closure params body env)

(defun evaluate (form &optional (env *global-env*))
  (typecase form
    ((or number string character keyword) form)
    (symbol (if (member form '(t nil)) form (env-lookup env form)))
    (cons
     (destructuring-bind (op &rest args) form
       (case op
         (quote (first args))
         (if (destructuring-bind (test then &optional else) args
               (if (evaluate test env) (evaluate then env) (evaluate else env))))
         (define (env-define env (first args) (evaluate (second args) env)))
         (lambda (make-closure :params (first args) :body (rest args) :env env))
         (begin (let (result) (dolist (f args result) (setf result (evaluate f env)))))
         (let (let ((new (make-env env)))
                (loop for (name val) in (first args)
                      do (env-define new name (evaluate val env)))
                (evaluate `(begin ,@(rest args)) new)))
         (t (apply-fn (evaluate op env) (mapcar (lambda (a) (evaluate a env)) args))))))
    (t (error 'eval-error :form form :reason "unknown form type"))))

(defun apply-fn (fn args)
  (etypecase fn
    (function (apply fn args))
    (closure
     (let ((new (make-env (closure-env fn))))
       (loop for p in (closure-params fn)
             for a in args
             do (env-define new p a))
       (evaluate `(begin ,@(closure-body fn)) new)))))

(defun repl (&key (prompt "mini> ") (stream *standard-input*))
  (loop
    (format t "~&~A" prompt)
    (force-output)
    (let ((form (read stream nil :eof)))
      (when (eq form :eof) (return))
      (handler-case (format t "=> ~S~%" (evaluate form))
        (eval-error (e) (format t "!! ~A~%" e))
        (error (e) (format t "!! internal: ~A~%" e))))))

;;; Test forms with tricky reader syntax
(defparameter *tests*
  '((+ 1 2 3)
    (* 1/2 4)
    (- #x10 #b1)
    (if (< 1 2) "yes" "no")
    (let ((x 10) (y 20)) (+ x y))
    ((lambda (a b) (cons a b)) 'first "second")
    (begin (define sq (lambda (n) (* n n))) (sq 12))
    (display "string with \"escapes\" and ; semicolon")
    (list #\a #\Space #\) 1.5d0 -3/4 #36rLISP)))

(defun run-tests ()
  (dolist (test *tests*)
    (format t "~S~40T=> ~S~%" test
            (handler-case (evaluate test)
              (error (e) (list :error (princ-to-string e)))))))

(defun string-escape-demo ()
  (list "a\"b" "c\\d" "|pipes|" "#|not comment|#" (format nil "~~tilde~%")))

(defparameter *symbol-edge-cases*
  '(|| |a b| |#|weird|#| \#hash \;semi \(paren a\ b |;|))

(defparameter *quasi*
  (let ((x 1) (ys '(2 3)))
    `(,x ,@ys ,(length ys) (nested ,@(mapcar #'1+ ys)) . tail)))

;;; LOOP and FORMAT directive edge cases
(defun loop-demo ()
  (loop for i from 0 below 10 by 2
        for sq = (* i i)
        collect (cons i sq) into pairs
        maximize sq into biggest
        finally (return (values pairs biggest))))

(defun format-demo (items)
  (format nil "~&Items: ~{~:[<none>~;~:*~A~]~^, ~}~%Total: ~D~%Ratio: ~,2F~%Hex: ~X Bin: ~B Oct: ~O~%~
               Plural: ~D item~:P~%Roman: ~@R~%Quote: ~S~%"
          items (length items) (/ (length items) 3) 255 5 8 (length items) 1999 "q\"uoted"))

(defun char-edge-cases ()
  (list #\( #\) #\; #\" #\| #\# #\\ #\Space #\Tab #\Newline
        (char-code #\A) (code-char 955) (char-upcase #\a) (digit-char-p #\7)))

(defmacro while (test &body body)
  `(do () ((not ,test)) ,@body))

(defun countdown (n)
  (let ((out '()))
    (while (plusp n)
      (push n out)
      (decf n))
    (nreverse out)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +max-depth+ 64)
  (defvar *depth* 0))

#+(or) (this form is skipped by the reader on every implementation)
#-(and) (so is this one)

#| This block comment is never balanced.
   #| a nested comment that IS closed |#
   #| a nested comment that is NOT closed
      (defun not-code () "string inside comment")
   |#
   ; back at the outer level, which still needs a closer
   (evaluate '(+ 1 2))
