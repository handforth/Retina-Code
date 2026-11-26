(in-package #:cl-user)
(require :sb-introspect)

(defpackage #:retina-debug (:use #:cl))
(in-package #:retina-debug)

(defvar *commands* *standard-input*)
(defvar *packets* (sb-sys:make-fd-stream 1 :output t :element-type '(unsigned-byte 8) :buffering :full))
(defvar *write-lock* (sb-thread:make-mutex))
(defvar *state-lock* (sb-thread:make-mutex))
(defvar *ready* (sb-thread:make-waitqueue))
(defvar *sequence* 0)
(defvar *entry*)
(defvar *root*)
(defvar *arguments*)
(defvar *terminal*)
(defvar *program* nil)
(defvar *paused* nil)
(defvar *mail* nil)
(defvar *inside-debugger* nil)
(defvar *frames*)
(defvar *frame-points*)
(defvar *values*)
(defvar *breakpoints* (make-hash-table :test 'equal))
(defvar *functions* (make-hash-table :test 'equal))
(defvar *step-points* nil)
(defvar *step-at-top* nil)
(defvar *lines* (make-hash-table :test 'equal))
(defvar *source-paths* (make-hash-table :test 'equal))
(defvar *form-positions* nil)
(defvar *last-source* nil)
(defvar *last-form-number* nil)
(defvar *last-form-map* nil)
(defvar *read-depth* 0)
(defvar *top-level-file* nil)
(defvar *top-level-line* 0)
(defparameter *list-reader* (get-macro-character #\())

(defstruct point location file line call)
(defstruct breakpoint line condition hit-condition log active (hits 0) verified)

(defun field (object key)
  (loop for (name value) on object by #'cddr
        when (string= name key) return value))

(defun json-string (value stream)
  (write-char #\" stream)
  (loop for ch across value do
    (cond ((or (char= ch #\") (char= ch #\\))
           (write-char #\\ stream)
           (write-char ch stream))
          ((< (char-code ch) 32)
           (format stream "\\u~4,'0X" (char-code ch)))
          (t (write-char ch stream))))
  (write-char #\" stream))

(defun json (value stream)
  (typecase value
    (string (json-string value stream))
    (integer (princ value stream))
    (vector
     (write-char #\[ stream)
     (loop for item across value for i from 0 do
       (when (plusp i)
         (write-char #\, stream))
       (json item stream))
     (write-char #\] stream))
    (cons
     (write-char #\{ stream)
     (loop for (key item) on value by #'cddr for i from 0 do
       (when (plusp i)
         (write-char #\, stream))
       (json-string key stream)
       (write-char #\: stream)
       (json item stream))
     (write-char #\} stream))
    (t (write-string (case value (:true "true") (:false "false") (otherwise "null")) stream))))

(defun packet (fields)
  (sb-thread:with-mutex (*write-lock*)
    (let* ((text (with-output-to-string (stream)
                   (json (list* "seq" (incf *sequence*) fields) stream)))
           (bytes (sb-ext:string-to-octets text :external-format :utf-8))
           (header (format nil "Content-Length: ~D~C~C~C~C" (length bytes) #\Return #\Newline #\Return #\Newline)))
      (write-sequence (sb-ext:string-to-octets header) *packets*)
      (write-sequence bytes *packets*)
      (force-output *packets*))))

(defun event (name &optional body)
  (packet (list "type" "event" "event" name "body" body)))

(defun respond (request &optional body message)
  (packet (list "type" "response" "request_seq" (first request) "command" (second request)
                "success" (if message :false :true) "body" body "message" message)))

(defun display-value (value)
  (let ((*print-level* 3) (*print-length* 12) (*print-circle* t) (*print-readably* nil))
    (let ((text (princ-to-string value)))
      (subseq text 0 (min (length text) 4096)))))

(defun project-file (path)
  (and path (<= (length *root*) (length path))
       (string= *root* path :end2 (length *root*))))

(defun source-path (name)
  (when (and name (plusp (length name)) (char= (char name 0) #\/))
    (multiple-value-bind (path found) (gethash name *source-paths*)
      (if found path
          (setf (gethash name *source-paths*) (ignore-errors (namestring (truename name))))))))

(defun byte-lines (path)
  (or (gethash path *lines*)
      (setf (gethash path *lines*)
            (with-open-file (stream path :element-type '(unsigned-byte 8))
              (let ((starts (make-array 256 :element-type 'fixnum :fill-pointer 0 :adjustable t))
                    (buffer (make-array 8192 :element-type '(unsigned-byte 8))))
                (vector-push-extend 0 starts)
                (loop for count = (read-sequence buffer stream) for offset from 0 by 8192
                      while (plusp count) do
                        (dotimes (index count)
                          (when (= (aref buffer index) 10)
                            (vector-push-extend (+ offset index 1) starts))))
                starts)))))

(defun line-at (path offset)
  (let* ((starts (byte-lines path)) (low 0) (high (length starts)))
    (loop while (< (1+ low) high) do
      (let ((mid (ash (+ low high) -1)))
        (if (<= (aref starts mid) offset)
            (setf low mid)
            (setf high mid))))
    (1+ low)))

(defun at-source (path line)
  (find line (gethash path *breakpoints*) :key #'breakpoint-line))

(defun read-list (stream char)
  (let* ((at (file-position stream))
         (form (let ((*read-depth* (1+ *read-depth*))) (funcall *list-reader* stream char))))
    (when at
      (cond (*form-positions*
             (setf (gethash form *form-positions*) (1- at)))
            ((and (zerop *read-depth*) (not *read-suppress*) (not *inside-debugger*) *load-truename*)
             (let ((path (source-path (ignore-errors (namestring (pathname stream))))))
               (when (project-file path)
                 (let* ((line (line-at path (1- at))) (bp (at-source path line)))
                   (setf *top-level-file* path *top-level-line* line)
                   (when (or *step-at-top* bp)
                     (visit-top-level path line form bp))))))))
    form))

;; Pair SBCL's compiler form numbers with byte positions from the original reader.
(defun map-source-form (source location top)
  (unless (and (eq source *last-source*) (eql top *last-form-number*))
    (let ((*readtable* (copy-readtable)) (*form-positions* (make-hash-table :test 'eq))
          (*debug-io* (make-broadcast-stream)) (*read-eval* nil))
      (set-macro-character #\( #'read-list)
      (multiple-value-bind (translations form) (sb-di::get-toplevel-form location)
        (setf *last-form-map*
              (map 'vector
                   (lambda (path)
                     (let ((selected form))
                       (dolist (index (reverse (butlast (cdr path))))
                         (setf selected (and (consp selected) (nth index selected))))
                       (cons (gethash selected *form-positions*) (and (consp selected) (car selected)))))
                   translations))))
    (setf *last-source* source *last-form-number* top))
  *last-form-map*)

(defun source-point (location)
  (ignore-errors
    (let* ((source (sb-di:code-location-debug-source location))
           (path (source-path (sb-di:debug-source-namestring source))))
      (when (project-file path)
        (let* ((map (map-source-form source location (sb-di:code-location-toplevel-form-offset location)))
               (index (sb-di:code-location-form-number location))
               (entry (and (< index (length map)) (aref map index))))
          (when (car entry)
            (make-point :location location :file path :line (line-at path (car entry)) :call (cdr entry))))))))

(defun function-points (fun returns)
  (let ((points nil))
    (ignore-errors
      (sb-di:do-debug-fun-blocks (block fun)
        (unless (sb-di:debug-block-elsewhere-p block)
          (sb-di:do-debug-block-locations (location block)
            (let ((kind (sb-di:code-location-kind location)))
              (when (or (member kind '(:call-site :block-start :non-local-entry))
                        (and returns (member kind '(:single-value-return :unknown-return :known-return))))
                (let ((point (source-point location)))
                  (when point (push point points)))))))))
    (nreverse points)))

(defun breakpoint-info (path bp)
  (list "verified" (if (breakpoint-verified bp) :true :false)
        "line" (breakpoint-line bp) "source" (list "path" path)))

(defun verify-breakpoint (path bp)
  (unless (breakpoint-verified bp)
    (setf (breakpoint-verified bp) t)
    (event "breakpoint" (list "reason" "changed" "breakpoint" (breakpoint-info path bp)))))

(defun delete-native (breakpoints)
  (dolist (bp breakpoints)
    (ignore-errors (sb-di:delete-breakpoint bp))))

(defun evaluate (expression frame)
  (let ((*read-eval* nil) (*inside-debugger* t)
        (*package* (or (and frame (ignore-errors
                                    (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
                                      (and (symbolp name) (symbol-package name)))))
                       *package*)))
    (let ((form (read-from-string expression)))
      (if frame (sb-di:eval-in-frame frame form) (eval form)))))

(defun breakpoint-hit (bp frame)
  (incf (breakpoint-hits bp))
  (let ((target (and (breakpoint-hit-condition bp)
                     (parse-integer (breakpoint-hit-condition bp) :junk-allowed t))))
    (when (and (or (not target) (= target (breakpoint-hits bp)))
               (or (not (breakpoint-condition bp))
                   (ignore-errors (evaluate (breakpoint-condition bp) frame))))
      (if (breakpoint-log bp)
          (event "output" (list "category" "console" "output" (format nil "~A~%" (breakpoint-log bp))))
          t))))

(defun install-native (point bp)
  (when (and (not (breakpoint-active bp)) (point-location point))
    (let ((native
            (ignore-errors
              (sb-di:activate-breakpoint
                (sb-di:make-breakpoint
                  (lambda (frame native)
                    (declare (ignore native))
                    (when (and (eq sb-thread:*current-thread* *program*) (not *inside-debugger*)
                               (breakpoint-hit bp frame))
                      (stop-here "breakpoint" frame point)))
                  (point-location point))))))
      (when native
        (setf (breakpoint-active bp) native)
        (verify-breakpoint (point-file point) bp)))))

(defun update-function-breakpoints (fun path)
  (let ((wanted (gethash path *breakpoints*)))
    (when (some (lambda (bp) (not (breakpoint-active bp))) wanted)
      (dolist (point (function-points (sb-di:fun-debug-fun fun) nil))
        (let ((bp (find (point-line point) wanted :key #'breakpoint-line)))
          (when (and bp (equal (point-file point) path))
            (install-native point bp)))))))

(defun new-function (name fun)
  (declare (ignore name))
  (unless *inside-debugger*
    (let ((path (source-path (ignore-errors
                              (let ((source (sb-introspect:find-definition-source fun)))
                                (namestring (sb-introspect:definition-source-pathname source)))))))
      (when (project-file path)
        (pushnew fun (gethash path *functions*))
        (update-function-breakpoints fun path)))))

(defun set-breakpoints (request)
  (let* ((args (third request))
         (path (source-path (field (field args "source") "path"))))
    (unless (project-file path)
      (return-from set-breakpoints (respond request (list "breakpoints" #()))))

    (let ((points (loop for entry in (field args "breakpoints") collect
                    (make-breakpoint :line (field entry "line") :condition (field entry "condition")
                                     :hit-condition (field entry "hitCondition") :log (field entry "logMessage")))))
      (delete-native (mapcar #'breakpoint-active (gethash path *breakpoints*)))
      (if points
          (setf (gethash path *breakpoints*) points)
          (remhash path *breakpoints*))
      (dolist (fun (gethash path *functions*))
        (update-function-breakpoints fun path))
      (respond request (list "breakpoints" (map 'vector (lambda (bp) (breakpoint-info path bp)) points))))))

(defun take-step (point)
  (unless (or (at-source (point-file point) (point-line point))
              (some (lambda (bp) (sb-di:code-location= (sb-di:breakpoint-what bp) (point-location point))) *step-points*))
    (let ((native
            (ignore-errors
              (sb-di:activate-breakpoint
                (sb-di:make-breakpoint
                  (lambda (frame native)
                    (declare (ignore native))
                    (unless *inside-debugger*
                      (stop-here "step" frame point)))
                  (point-location point))))))
      (when native (push native *step-points*)))))

(defun arm-step (command frame point &optional form)
  (setf *step-at-top* t)
  (when (string= command "stepIn")
    (let* ((name (if form (and (consp form) (car form)) (and point (point-call point))))
           (entry (when (symbolp name)
                    (ignore-errors (first (function-points (sb-di:fun-debug-fun (fdefinition name)) nil))))))
      (when entry
        (take-step entry))))

  (when (and frame (string/= command "stepOut"))
    (dolist (candidate (function-points (sb-di:frame-debug-fun frame) nil))
      (unless (or (not point) (= (point-line candidate) (point-line point)))
        (take-step candidate))))

  (loop for caller = (and frame (sb-di:frame-down frame)) then (sb-di:frame-down caller)
        while caller
        for source = (source-point (sb-di:frame-code-location caller))
        when source do
          (dolist (candidate (function-points (sb-di:frame-debug-fun caller) t))
            (take-step candidate))
          (return)))

(defun visit-top-level (path line form bp)
  (when bp
    (verify-breakpoint path bp))
  (when (or *step-at-top* (and bp (breakpoint-hit bp nil)))
    (stop-here (if *step-at-top* "step" "breakpoint") nil (make-point :file path :line line) nil form)))

(defun frame-info (index)
  (let* ((frame (aref *frames* index)) (point (aref *frame-points* index))
         (name (if frame (sb-di:debug-fun-name (sb-di:frame-debug-fun frame)) "Top level")))
    (list "id" index "name" (display-value name) "line" (point-line point) "column" 1
          "source" (list "name" (file-namestring (point-file point)) "path" (point-file point)))))

(defun value-reference (value)
  (if (or (consp value) (and (vectorp value) (not (stringp value))) (hash-table-p value))
      (+ 1 (length *frames*) (vector-push-extend value *values*))
      0))

(defun debug-variable (name value)
  (list "name" name "value" (display-value value) "type" (princ-to-string (type-of value))
        "variablesReference" (value-reference value)))

(defun child-variables (reference start count)
  (let ((end (+ start count)))
    (if (<= reference (length *frames*))
        (let ((frame (aref *frames* (1- reference))) (items nil))
          (when frame
            (let ((loc (sb-di:frame-code-location frame))
                  (fun (sb-di:frame-debug-fun frame)))
              (sb-di:do-debug-fun-vars (var fun)
                (when (eq (sb-di:debug-var-validity var loc) :valid)
                  (push (debug-variable (symbol-name (sb-di:debug-var-symbol var)) (sb-di:debug-var-value var frame)) items)))))
          (setf items (nreverse items))
          (coerce (subseq items (min start (length items)) (min end (length items))) 'vector))
        (let ((value (aref *values* (- reference (length *frames*) 1))) (items nil))
          (typecase value
            (list
             (loop for tail = value then (cdr tail) for i below end while (consp tail)
                   when (>= i start) do (push (debug-variable (format nil "[~D]" i) (car tail)) items)))
            (vector
             (loop for i from start below (min end (length value))
                   do (push (debug-variable (format nil "[~D]" i) (aref value i)) items)))
            (hash-table
             (loop for key being the hash-keys of value using (hash-value item) for i below end
                   when (>= i start) do (push (debug-variable (display-value key) item) items))))
          (coerce (nreverse items) 'vector)))))

(defun paused-request (request condition)
  (destructuring-bind (id command args) request
    (declare (ignore id))
    (cond
      ((string= command "stackTrace")
       (let* ((start (min (length *frames*) (or (field args "startFrame") 0)))
              (end (min (length *frames*) (+ start (or (field args "levels") 100)))))
         (respond request (list "stackFrames" (coerce (loop for i from start below end collect (frame-info i)) 'vector)
                                "totalFrames" (length *frames*)))))
      ((string= command "scopes")
       (respond request (list "scopes" (vector (list "name" "Locals" "expensive" :false
                                                     "variablesReference" (1+ (field args "frameId")))))))
      ((string= command "variables")
       (respond request (list "variables" (child-variables (field args "variablesReference")
                                                          (or (field args "start") 0) (or (field args "count") 100)))))
      ((string= command "evaluate")
       (let ((value (evaluate (field args "expression") (aref *frames* (or (field args "frameId") 0)))))
         (respond request (list "result" (display-value value) "variablesReference" (value-reference value)))))
      ((string= command "exceptionInfo")
       (respond request (list "exceptionId" "Lisp condition" "description" condition "breakMode" "unhandled")))
      ((string= command "setBreakpoints")
       (set-breakpoints request))
      (t
       (respond request nil "The request is unavailable in this frame.")))))

;; Inspect live Lisp frames on the paused thread. Only that thread touches them.
(defun stop-here (reason frame point &optional condition form)
  (let ((*inside-debugger* t)
        (*frames* (make-array 8 :adjustable t :fill-pointer 0))
        (*frame-points* (make-array 8 :adjustable t :fill-pointer 0))
        (*values* (make-array 8 :adjustable t :fill-pointer 0)))
    (finish-output *standard-output*)
    (delete-native *step-points*)
    (setf *step-points* nil *step-at-top* nil)
    (when point
      (vector-push-extend point *frame-points*)
      (vector-push-extend frame *frames*))
    (loop for current = (if (and point frame) (sb-di:frame-down frame) frame) then (sb-di:frame-down current)
          while current
          for source = (source-point (sb-di:frame-code-location current))
          when source do
            (vector-push-extend source *frame-points*)
            (vector-push-extend current *frames*))
    (when (and (zerop (length *frames*)) *top-level-file*)
      (vector-push-extend (make-point :file *top-level-file* :line *top-level-line*) *frame-points*)
      (vector-push-extend nil *frames*))

    (sb-thread:with-mutex (*state-lock*)
      (setf *paused* t))
    (event "stopped" (list "reason" reason "threadId" 1 "text" condition "allThreadsStopped" :true))
    (loop
      (let* ((request (sb-thread:with-mutex (*state-lock*)
                        (loop until *mail* do (sb-thread:condition-wait *ready* *state-lock*))
                        (pop *mail*)))
             (command (second request)))
        (if (member command '("continue" "next" "stepIn" "stepOut") :test #'string=)
            (progn
              (unless (string= command "continue")
                (arm-step command frame point form))
              (sb-thread:with-mutex (*state-lock*) (setf *paused* nil))
              (respond request (list "allThreadsContinued" :true))
              (return))
            (handler-case (paused-request request condition)
              (error (failure) (respond request nil (princ-to-string failure)))))))))

(defun on-error (condition hook)
  (declare (ignore hook))
  (unless *inside-debugger*
    (stop-here "exception" (sb-di:top-frame) nil (display-value condition)))
  (unless (typep condition 'error)
    (let ((continue (find-restart 'continue condition)))
      (when continue
        (invoke-restart continue))))

  (event "output" (list "category" "stderr" "output" (format nil "~A~%" (display-value condition))))
  (throw 'exit-code 1))

(defun run-program ()
  (setf *program* sb-thread:*current-thread*)
  (let ((code
          (catch 'exit-code
            (let* ((io (and *terminal* (open *terminal* :direction :io :if-exists :overwrite)))
                   (*standard-input* (or io (make-string-input-stream "")))
                   (*standard-output* (or io *error-output*))
                   (*error-output* *standard-output*)
                   (*trace-output* *standard-output*)
                   (*terminal-io* (make-two-way-stream *standard-input* *standard-output*))
                   (*query-io* *terminal-io*)
                   (*package* (find-package :cl-user))
                   (*readtable* (copy-readtable))
                   (sb-ext:*posix-argv* (cons *entry* *arguments*))
                   (sb-ext:*invoke-debugger-hook* #'on-error)
                   (sb-ext:*evaluator-mode* :compile))
              (set-macro-character #\( #'read-list)
              (proclaim '(optimize (debug 3) (speed 0)))
              (push #'new-function sb-int:*setf-fdefinition-hook*)
              (unwind-protect (load *entry* :verbose nil :print nil)
                (finish-output *standard-output*)
                (when io (close io)))
              0))))
    (event "exited" (list "exitCode" code))
    (event "terminated")))

(defun command (request)
  (destructuring-bind (id name args) request
    (declare (ignore id))
    (cond
      ((string= name "initialize")
       (respond request (list "supportsConfigurationDoneRequest" :true "supportsConditionalBreakpoints" :true
                              "supportsHitConditionalBreakpoints" :true "supportsExceptionInfoRequest" :true)))
      ((string= name "launch")
       (setf *entry* (namestring (truename (field args "program")))
             *root* (namestring (truename (field args "cwd")))
             *arguments* (field args "args")
             *terminal* (field args "terminal"))
       (respond request)
       (event "initialized"))
      ((string= name "configurationDone")
       (respond request)
       (setf *program* (sb-thread:make-thread #'run-program :name "Lisp program")))
      ((string= name "threads")
       (respond request (list "threads" #(("id" 1 "name" "Lisp program")))))
      ((string= name "setExceptionBreakpoints") (respond request))
      ((string= name "disconnect")
       (respond request)
       (sb-ext:exit :abort t))
      ((string= name "pause")
       (respond request)
       (when (and (not *paused*) *program* (sb-thread:thread-alive-p *program*))
         (sb-thread:interrupt-thread *program* (lambda ()
                                                 (unless *inside-debugger*
                                                   (stop-here "pause" (sb-di:top-frame) nil))))))
      (t
       (let ((queued
               (sb-thread:with-mutex (*state-lock*)
                 (when *paused*
                   (setf *mail* (nconc *mail* (list request)))
                   (sb-thread:condition-notify *ready*)
                   t))))
         (unless queued
           (if (string= name "setBreakpoints")
               (if (and *program* (sb-thread:thread-alive-p *program*))
                   (sb-thread:interrupt-thread *program* (lambda () (set-breakpoints request)))
                   (set-breakpoints request))
               (respond request nil "The program is running."))))))))

(loop for request = (let ((*read-eval* nil)) (read *commands* nil))
      while request do
        (handler-case (command request)
          (error (failure) (respond request nil (princ-to-string failure)))))