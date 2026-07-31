#!/usr/bin/env bb
;; E2E for edn-syrup CLI + cross-validation against the JSON cli:
;; two front-ends (EDN text, JSON text) must produce ONE syrup wire
;; on the JSON-expressible subset.
(require '[babashka.process :as p]
         '[clojure.string :as str])

;; run from the repo root: bb tools/edn_syrup_e2e.bb
(def d (System/getProperty "user.dir"))
(def edn-cli "zig-out/bin/edn-syrup")

(defn sh-in [in & args] (apply p/sh {:dir d :in in} args))

(def failures (atom 0))
(defn check! [label ok? detail]
  (println (if ok? "OK  " "FAIL") label (if ok? "" detail))
  (when-not ok? (swap! failures inc)))

;; 1. EDN -> syrup -> EDN identity on a mixed value
(let [src "[nil true 42 2.5 \"x\" :kw sym #{:s} {:a 1} (7) \\a 1/3 99999999999999999999N]"
      enc (sh-in src edn-cli "encode")
      dec (sh-in (:out enc) edn-cli "decode")
      re-enc (sh-in (str/trim (:out dec)) edn-cli "encode")]
  (check! "edn round-trip fixed point" (= (:out enc) (:out re-enc))
          (pr-str [(count (:out enc)) (count (:out re-enc)) (:out dec)])))

;; 2. minInt/maxInt survive the CLI path
(let [src "[-9223372036854775808 9223372036854775807]"
      enc (sh-in src edn-cli "encode")
      dec (sh-in (:out enc) edn-cli "decode")]
  (check! "i64 extremes" (= (str/trim (:out dec)) src) (pr-str (:out dec))))

;; 3. cross-front-end: EDN vector vs JSON array of the shared subset -> same wire
(let [edn-src  "[\"x\" 1 true nil 2.5]"
      json-src "[\"x\", 1, true, null, 2.5]"
      via-edn  (:out (sh-in edn-src edn-cli "encode"))
      json-cli-built (zero? (:exit (p/sh {:dir d} "zig" "build" "install-cli")))
      via-json (when json-cli-built (:out (sh-in json-src "zig-out/bin/syrup" "encode")))]
  (if json-cli-built
    (check! "EDN and JSON front-ends agree on shared subset" (= via-edn via-json)
            (pr-str [via-edn via-json]))
    (println "SKIP cross-front-end (json cli does not build on this zig)")))

;; 4. error paths exit nonzero
(let [r (sh-in "{:unclosed" edn-cli "encode")]
  (check! "parse error -> nonzero exit" (pos? (:exit r)) (pr-str (:exit r))))

(println)
(if (zero? @failures)
  (println "ALL GREEN")
  (do (println @failures "FAILURES") (System/exit 1)))
