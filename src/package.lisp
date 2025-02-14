#|
  This file is a part of eazy-gnuplot project.
  Copyright (c) 2014 guicho
|#

(in-package :cl-user)
(defpackage eazy-gnuplot
  (:use :cl :iterate
        :trivia
        :alexandria)
  (:export :with-plots
           :func-plot
           :func-splot
           :datafile-plot
           :datafile-splot
           :plot
           :splot
           :gp-setup
           :gp
           :gp-quote
           :*gnuplot-home*
           :row))
(in-package :eazy-gnuplot)

;; gnuplot interface

(defvar *gnuplot-home* "gnuplot")
  (defvar *user-stream*)
  (defvar *plot-stream*)
  (defvar *data-stream*)
  (defvar *plot-type*)
  (defvar *plot-type-multiplot*)

(defun gp-quote (value)
  "Map a value to the corresponding gnuplot string"
  (match value
    ((type string) (format nil "\"~a\"" value))
    ((type pathname) (gp-quote (namestring value)))
    (nil "")
    ((symbol name)
     (if (some (conjoin #'both-case-p #'lower-case-p) name)
         name                           ; escaped characters e.g. |Left|
         (string-downcase name)))
    ((type list)
     (reduce (lambda (str val)
               (format nil "~a ~a"
                       str (gp-quote val)))
             value))
    ;; numbers etc
    (_ value)))

(defun map-plist (args fn)
  (when args
    (destructuring-bind (key value . rest) args
      (funcall fn key value)
      (map-plist rest fn))))

(defun gp-setup (&rest args &key terminal output multiplot &allow-other-keys)
  (let ((*print-case* :downcase))
    (unless output
      (error "missing ouptut!"))
    (when (null terminal)
      (ematch (pathname-type (pathname output))
        ((and type (or :unspecific :wild nil "*"))
         (error "gp-setup is missing :terminal, and ~
                 it failed to guess the terminal type from the output pathname ~a,
                 based on its pathname-type ~a"
                output type))
        ((and type (type string)) 
         (setf terminal (make-keyword type)))))
    (setf *plot-type-multiplot* multiplot)
    (format *plot-stream* "~&set ~a ~a" :terminal (gp-quote terminal))
    (format *plot-stream* "~&set ~a ~a" :output (gp-quote output))
    (remf args :terminal)
    (remf args :output)
    (map-plist args
               (lambda (key val)
                 (format *plot-stream* "~&set ~a ~a"
                         key (gp-quote val))))))

(defun gp (left-side &rest right-side)
  "Single statement ,render gnuplot `left-side` as string infront of gp-quoted contents of ars
   For example:
     Command:
       (gp-stmt :set :param)
     Generates:
       set param
       set lmargin 10
     Command
       (gp-stmt :style :line 1 :lc :rgb '(\"'#999999'\") :lt 1 '(\"#border\"))
     Generates:

- Arguments:
  - left-side : first word in gnuplot statement
  - right-side : arguments remaining in the argument list rendered as parameters to left-side command
- Return:
  NIL
"
  (format *plot-stream* "~&~A ~A~%" left-side (gp-quote right-side))
  )

(defmacro with-plots ((stream &key debug (external-format :default))
                      &body body)
  (check-type stream symbol)
  `(let (*plot-type-multiplot*) (call-with-plots ,external-format ,debug (lambda (,stream) ,@body))))


(define-condition new-plot () ())

(defun call-with-plots (external-format debug body)
    (let ((*plot-type* nil)
          (*print-case* :downcase)
          (before-plot-stream (make-string-output-stream))
          (after-plot-stream (make-string-output-stream))
          (*data-stream* (make-string-output-stream))
          (*plot-stream* (make-string-output-stream)))
      (let ((*user-stream* before-plot-stream))
        (handler-bind ((new-plot
                        (lambda (c)
                          (declare (ignore c))
                          (setf *user-stream* after-plot-stream)
                          ;; ensure there is a newline
                          (terpri after-plot-stream))))
          (funcall body (make-synonym-stream '*user-stream*))
          ;; this is required when gnuplot handles png -- otherwise the file buffer is not flushed
          (format after-plot-stream "~&set output"))
        (with-input-from-string (in ((lambda (str)
                                       (if debug
                                           (print str *error-output*)
                                           str))
                                     (concatenate 'string
                                                  (get-output-stream-string before-plot-stream)
                                                  (get-output-stream-string *plot-stream*)
                                                  (get-output-stream-string *data-stream*)
                                                  (get-output-stream-string after-plot-stream))))
          (uiop:run-program *gnuplot-home*
                            :input in
                            :external-format external-format)))))


(defun %plot (data-producing-fn &rest args
              &key (type :plot) string &allow-other-keys)
  ;; print the filename
  (cond
    ((or (null *plot-type*) *plot-type-multiplot*)
     (format *plot-stream* "~%~a ~a" type string)
     (setf *plot-type* type))
    ((and (eq type *plot-type*) (not *plot-type-multiplot*))
     (format *plot-stream* ", ~a" string)
     )
    (t
     (error "Using incompatible plot types ~a and ~a in a same figure! (given: ~a expected: ~a)"
            type *plot-type* type *plot-type*)))

  (remf args :type)
  (remf args :string)
  
  ;; process arguments
  (let ((first-using t))
    (map-plist
     args
     (lambda (&rest args)
       (match args
         ((list :using (and val (type list)))
          (format *plot-stream* "~:[, ''~;~] using ~{~a~^:~}" first-using val)
          (setf first-using nil))
         ((list :using (and val (type atom)))
          (format *plot-stream* "~:[, ''~;~] using ~a" first-using val)
          (setf first-using nil))
         ((list key val)
          (format *plot-stream* " ~a ~a" key (gp-quote val)))))))

  (signal 'new-plot)
  (when (functionp data-producing-fn)
    ;; ensure the function is called once
    (let ((data (with-output-to-string (*user-stream*)
                  (funcall data-producing-fn)))
          (correct-stream (if *plot-type-multiplot* *plot-stream* *data-stream*)))
      (flet ((plt ()
               (terpri correct-stream)
               (write-sequence data correct-stream)
               (format correct-stream "~&end~%")))
        (let ((n (count :using args)))
          (if (> n 0)
              (loop repeat n do (plt))
              (plt)))))))

(defun plot (data-producing-fn &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (apply #'%plot data-producing-fn :string "'-'" args))
(defun splot (data-producing-fn &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (apply #'plot data-producing-fn :type :splot args))
(defun func-plot (string &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (check-type string string)
  (apply #'%plot nil :string string args))
(defun func-splot (string &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (apply #'func-plot string :type :splot args))
(defun datafile-plot (pathspec &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (check-type pathspec (or pathname string))
  (apply #'%plot nil :string (format nil "'~a'" (pathname pathspec)) args))
(defun datafile-splot (pathspec &rest args &key using &allow-other-keys)
  (declare (ignorable using))
  (apply #'datafile-plot pathspec :type :splot args))

(defun row (&rest args)
  "Write a row"
  (format *user-stream* "~&~{~a~^ ~}" args))

