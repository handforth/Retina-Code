;;;; Common Lisp lexer stress: reader macros, nested #| |# comments, characters, numbers
;;; Three-semicolon comment
;; Two-semicolon comment
; One-semicolon comment

#| Block comments nest in Common Lisp:
   #| inner #| deeper |# |# still outer
   and this line is still a comment |#
(defvar *after-nested* "visible")

(defpackage #:stress.reader
  (:use #:cl)
  (:nicknames #:sr)
  (:export #:main #:*config* #:|Weird Exported Symbol|)
  (:shadow #:search))

(in-package #:stress.reader)

;;; Strings
(defparameter *s1* "double \"quoted\" with \\ backslash")
(defparameter *s2* "multi-line
string spanning
three lines")
(defparameter *s3* "semicolon ; and #| not a comment |# inside a string")
(defparameter *s4* "trailing backslash \\")
(defparameter *s5* "unterminated at end of line
(defparameter *s6* "after")

;;; Characters
(defparameter *chars*
  (list #\a #\A #\Space #\Newline #\Tab #\Return #\Linefeed #\Page #\Backspace
        #\Rubout #\Nul #\( #\) #\; #\" #\\ #\| #\# #\' #\` #\, #\@ #\Space
        #\x41 #\U+00E9 #\LATIN_SMALL_LETTER_A #\λ))

;;; Numbers
(defparameter *numbers*
  (list 42 -42 +42 42. 3.14 -0.5 .5 1e10 1.5e-3 1.5d0 1.5f0 1.5s0 1.5l0
        1/3 -22/7 4/2 #x1F #xFF #X-ff #b101 #B-1010 #o17 #O777 #36rZZ #2r1011 #16r1F
        #c(1 2) #C(1.5 -2.5)))

;;; Symbols and keywords
(defparameter *symbols*
  '(foo foo-bar *special* +constant+ %internal &rest &optional &key &body &aux
    |weird symbol with spaces| |MixedCase| |a\|b| foo\ bar a|b c|d
    cl:car cl-user::internal :keyword :another-key #:uninterned
    1+ 1- +.5 -a- ... nil t))

;;; Quote, backquote, function
(defparameter *quoted* '(a b c))
(defparameter *also-quoted* (quote (a b c)))
(defparameter *backquoted* `(a ,(+ 1 2) ,@(list 'b 'c) d))
(defparameter *nested-bq* `(outer `(inner ,,(+ 1 1) ,',x)))
(defparameter *fn* #'car)
(defparameter *lambda-fn* #'(lambda (x) (* x x)))
(defparameter *vector* #(1 2 3 "four" #\5))
(defparameter *bit-vector* #*10110)
(defparameter *pathname* #p"/tmp/file.lisp")
(defparameter *array* #2A((1 2) (3 4)))
(defparameter *read-eval* '#.(+ 1 2))
(defparameter *labelled* '#1=(a b . #1#))
(defparameter *structure* #S(point :x 1 :y 2))

;;; Reader conditionals
(defun implementation ()
  #+sbcl "SBCL"
  #+ccl "Clozure"
  #+(or ecl clisp) "ECL or CLISP"
  #+(and unix (not darwin)) "some unix"
  #-(or sbcl ccl ecl clisp) "unknown")

;;; Functions and macros
(defun greet (name &optional (greeting "Hello") &key (punct "!") loud)
  "Docstring with \"quotes\" and ; semicolons."
  (declare (type string name) (optimize (speed 3) (safety 0)))
  (let* ((msg (format nil "~A, ~A~A" greeting name punct))
         (out (if loud (string-upcase msg) msg)))
    (values out (length out))))

(defmacro with-timing ((&key (label "timing")) &body body)
  (let ((start (gensym "START")))
    `(let ((,start (get-internal-real-time)))
       (multiple-value-prog1 (progn ,@body)
         (format t "~&~A: ~,3F s~%" ,label
                 (/ (- (get-internal-real-time) ,start)
                    internal-time-units-per-second))))))

(defgeneric area (shape)
  (:documentation "Compute the area of SHAPE."))

(defclass circle ()
  ((radius :initarg :radius :accessor radius :type real :initform 1.0)))

(defclass rect ()
  ((w :initarg :w :reader rect-w)
   (h :initarg :h :reader rect-h)))

(defmethod area ((c circle)) (* pi (expt (radius c) 2)))
(defmethod area ((r rect)) (* (rect-w r) (rect-h r)))
(defmethod area :around ((s t))
  (let ((result (call-next-method)))
    (if (minusp result) 0 result)))

(defstruct (point (:constructor make-point (x y)))
  (x 0 :type fixnum)
  (y 0 :type fixnum))

;;; Control flow
(defun classify (n)
  (cond ((not (numberp n)) :not-a-number)
        ((zerop n) :zero)
        ((minusp n) :negative)
        (t :positive)))

(defun sum-evens (list)
  (loop for x in list
        when (evenp x)
          sum x into total
        finally (return total)))

(defun search (item seq)
  (block found
    (dolist (x seq nil)
      (when (equal x item)
        (return-from found x)))))

(defun safe-divide (a b)
  (handler-case (/ a b)
    (division-by-zero (c)
      (format *error-output* "Error: ~A~%" c)
      nil)
    (:no-error (result) result)))

(defun main (&rest args)
  (with-timing (:label "main")
    (multiple-value-bind (msg len) (greet "World" "Hi" :loud t)
      (format t "~A (~D chars)~%" msg len))
    (format t "~{~A~^, ~}~%" (mapcar #'classify '(-1 0 1 x)))
    (format t "~S~%" (list (area (make-instance 'circle :radius 2))
                           (area (make-instance 'rect :w 3 :h 4))))
    (let ((ht (make-hash-table :test #'equal)))
      (setf (gethash "key" ht) 'value)
      (maphash (lambda (k v) (format t "~A => ~A~%" k v)) ht))
    (format t "args: ~S impl: ~A~%" args (implementation))))

;;; Edge cases at line boundaries
(defparameter *edge-string* "opens here
closes here")
(defparameter *edge-symbol* '|pipe symbol
spanning lines|)
(defparameter *edge-char-paren* (list #\( #\)))   ; char literals of parens do not affect nesting
(defparameter *edge-semicolon-char* #\;)          ; this semicolon is a character
(defparameter *edge-sharp-pipe-in-string* "#| not a comment |#")
(defparameter *edge-dotted* '(a . b))
(defparameter *edge-dot-symbol* '(a .b c. ..d))
(defparameter *edge-numbers-vs-symbols* '(1+ +1 1- -1 1.0 1.0.0 .1 1/2 1/ /1 1e 1e5))

#| final #| nested |# comment closed |# (defvar *last* 'done)
