;; Thin Common Lisp wrapper for the Python Cyton health check.
;;
;; Run with a Common Lisp runtime that provides UIOP, for example:
;;   sbcl --script cyton_health_check.lsp -- --help

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :asdf))

(defpackage #:cyton-health-check-wrapper
  (:use #:cl)
  (:import-from #:uiop
                #:command-line-arguments
                #:getenv
                #:process-info-exit-code
                #:quit
                #:run-program))

(in-package #:cyton-health-check-wrapper)

(defun wrapper-directory ()
  (make-pathname
   :name nil
   :type nil
   :defaults (or *load-truename* *default-pathname-defaults*)))

(defun cyton-health-check-script ()
  (namestring
   (merge-pathnames #P"cyton_health_check.py" (wrapper-directory))))

(defun python-program ()
  (or (getenv "PYTHON") "python3"))

(defun run-cyton-health-check (&optional (args (command-line-arguments)))
  (run-program
   (append (list (python-program) (cyton-health-check-script)) args)
   :output *standard-output*
   :error-output *error-output*
   :ignore-error-status t))

(defun main ()
  (let ((result (run-cyton-health-check)))
    (quit (process-info-exit-code result))))

(main)
