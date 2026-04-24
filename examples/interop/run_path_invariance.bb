#!/usr/bin/env bb
;; run_path_invariance.bb — drive the 70-color CGT corpus through a peer
;; (racket or guile) and assert byte-identity round-trip.
;;
;; Squares:
;;   A — guile peer  (Zig⇄Guile)
;;   B — racket peer (Zig⇄Racket)
;;   D — local Zig roundtrip (control, no peer)
;;
;; Usage:
;;   bb examples/interop/run_path_invariance.bb racket
;;   bb examples/interop/run_path_invariance.bb guile
;;   bb examples/interop/run_path_invariance.bb local

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def here (-> *file* fs/parent fs/absolutize str))
(def root (-> here fs/parent fs/parent str))
(def harness (str root "/zig-out/bin/path_invariance"))

(defn die! [msg]
  (binding [*out* *err*] (println msg))
  (System/exit 2))

(defn run! [& args]
  (let [{:keys [exit out err]} (apply p/sh args)]
    (when-not (str/blank? out) (print out) (flush))
    (when-not (str/blank? err) (binding [*out* *err*] (print err) (flush)))
    (when-not (zero? exit)
      (die! (str "FAIL: " (pr-str args) " exit=" exit)))))

(defn command-available? [cmd]
  (zero? (:exit (p/sh "which" cmd))))

(defn env-paths [name]
  (remove str/blank? (str/split (or (System/getenv name) "") #":")))

(defn dedupe [xs]
  (loop [remaining xs
         seen #{}
         out []]
    (if-let [x (first remaining)]
      (if (contains? seen x)
        (recur (rest remaining) seen out)
        (recur (rest remaining) (conj seen x) (conj out x)))
      out)))

(defn guile-site-candidates []
  (->> (concat
        (for [entry (env-paths "FLOX_ENV_DIRS")]
          (str entry "/share/guile/site/3.0"))
        (for [entry (env-paths "PATH")
              :let [parent (some-> entry fs/parent str)]]
          (when parent
            (str parent "/share/guile/site/3.0"))))
       (remove nil?)
       dedupe
       (filter #(fs/exists? %))))

(defn guile-command-prefix [sites]
  (into ["guile"]
        (mapcat (fn [site] ["-L" site]) sites)))

(defn guile-module-available? [sites module-name]
  (zero? (:exit (apply p/sh
                       (concat (guile-command-prefix sites)
                               ["--no-auto-compile" "-c"
                                (str "(if (catch #t "
                                     "(lambda () (use-modules " module-name ") #t) "
                                     "(lambda args #f)) "
                                     "(primitive-exit 0) "
                                     "(primitive-exit 7))")])))))

(defn ensure-harness! []
  (when-not (fs/exists? harness)
    (println "building path-invariance harness...")
    (run! {:dir root} "zig" "build" "path-invariance")))

(defn with-tmp [prefix f]
  (let [path (str (fs/create-temp-file {:prefix prefix :suffix ".bin"}))]
    (try (f path) (finally (fs/delete-if-exists path)))))

(defn -main [& args]
  (let [peer (or (first args) "local")]
    (ensure-harness!)
    (case peer
      "local"
      (with-tmp "corpus."
        (fn [corpus]
          (run! harness "roundtrip" corpus)))

      "racket"
      (with-tmp "corpus."
        (fn [corpus]
          (when-not (command-available? "racket")
            (die! "Square B unavailable: `racket` is not installed in the current Flox environment."))
          (with-tmp "echo."
            (fn [echoed]
              (run! harness "emit" corpus)
              (run! "racket" (str here "/racket_echo.rkt") corpus echoed)
              (run! harness "verify" corpus echoed)))))

      "guile"
      (with-tmp "corpus."
        (fn [corpus]
          (let [guile-sites (guile-site-candidates)]
            (when-not (command-available? "guile")
              (die! "Square A unavailable: `guile` is not installed in the current Flox environment."))
            (when (empty? guile-sites)
              (die! (str "Square A unavailable: no additional Guile site directories were discovered. "
                         "Expected them under FLOX env roots or PATH siblings as share/guile/site/3.0.")))
            (when-not (guile-module-available? guile-sites "(goblins)")
              (die! (str "Square A unavailable: Guile site discovery succeeded, but Goblins is still not reachable. "
                         "Checked sites: " (str/join ", " guile-sites))))
            (when-not (guile-module-available? guile-sites "(goblins contrib syrup)")
              (die! (str "Square A unavailable: Guile can reach Goblins, but the `(goblins contrib syrup)` module is not installed. "
                         "Checked sites: " (str/join ", " guile-sites))))
            (with-tmp "echo."
              (fn [echoed]
                (run! harness "emit" corpus)
                (apply run! (concat (guile-command-prefix guile-sites)
                                    ["--no-auto-compile"
                                     (str here "/guile_echo.scm") corpus echoed]))
                (run! harness "verify" corpus echoed))))))

      (die! (str "usage: bb run_path_invariance.bb {local|racket|guile}\n"
                 "       got: " (pr-str peer))))))

(apply -main *command-line-args*)
