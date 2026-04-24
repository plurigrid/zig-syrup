#!/usr/bin/env hy
;; Thin Hy wrapper for the Python Cyton health check.
;;
;; Run with an installed Hy runtime, for example:
;;   hy cyton_health_check.hy --help

(import [os]
        [sys]
        [subprocess])


(defn cyton-health-check-script []
  (os.path.join
    (os.path.dirname (os.path.abspath __file__))
    "cyton_health_check.py"))


(defn -main []
  (setv argv (+ [sys.executable (cyton-health-check-script)]
                (list (cut sys.argv 1 None))))
  (setv result (subprocess.run argv))
  (raise (SystemExit result.returncode)))


(when (= __name__ "__main__")
  (-main))
