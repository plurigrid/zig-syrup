#!/usr/bin/env bb
;; E2E for the esyrup CLI (ESYRUP.md):
;;   law 1/2 smoke via CLI fixed points,
;;   cross-front-end (EDN and JSON CLIs -> ONE syrup wire),
;;   law 3: vivicat/zig-syrup zoo.bin oracle (byte-identical reproduction).
;; Run from the repo root: bb tools/edn_syrup_e2e.bb
(require '[babashka.process :as p]
         '[clojure.string :as str])

(def d (System/getProperty "user.dir"))
(def esyrup "zig-out/bin/esyrup")

(defn sh-in [in & args] (apply p/sh {:dir d :in in} args))
(defn sh-in-bytes [in & args] (apply p/sh {:dir d :in in :out :bytes} args))

(def failures (atom 0))
(defn check! [label ok? detail]
  (println (if ok? "OK  " "FAIL") label (if ok? "" detail))
  (when-not ok? (swap! failures inc)))

;; 1. EDN -> syrup -> EDN identity on a mixed value
(let [src "[nil true 42 2.5 \"x\" :kw sym #{:s} {:a 1} (7) \\a 1/3 99999999999999999999N]"
      enc (sh-in src esyrup "encode")
      dec (sh-in (:out enc) esyrup "decode")
      re-enc (sh-in (str/trim (:out dec)) esyrup "encode")]
  (check! "esyrup round-trip fixed point" (= (:out enc) (:out re-enc))
          (pr-str [(count (:out enc)) (count (:out re-enc)) (:out dec)])))

;; 2. minInt/maxInt survive the CLI path
(let [src "[-9223372036854775808 9223372036854775807]"
      enc (sh-in src esyrup "encode")
      dec (sh-in (:out enc) esyrup "decode")]
  (check! "i64 extremes" (= (str/trim (:out dec)) src) (pr-str (:out dec))))

;; 3. cross-front-end: EDN vector vs JSON array of the shared subset -> same wire
(let [edn-src  "[\"x\" 1 true nil 2.5]"
      json-src "[\"x\", 1, true, null, 2.5]"
      via-edn  (:out (sh-in edn-src esyrup "encode"))
      json-cli-built (zero? (:exit (p/sh {:dir d} "zig" "build" "install-cli")))
      via-json (when json-cli-built (:out (sh-in json-src "zig-out/bin/syrup" "encode")))]
  (if json-cli-built
    (check! "EDN and JSON front-ends agree on shared subset" (= via-edn via-json)
            (pr-str [via-edn via-json]))
    (println "SKIP cross-front-end (json cli does not build on this zig)")))

;; 4. error paths exit nonzero
(let [r (sh-in "{:unclosed" esyrup "encode")]
  (check! "parse error -> nonzero exit" (pos? (:exit r)) (pr-str (:exit r))))

;; 5. law 3: foreign canonical wire (vivicat/zig-syrup zoo.bin, Apache-2.0)
;;    decode -> esyrup text -> encode must reproduce the wire byte-identically.
;;    1-ulp sensitive: this oracle caught edn.c's "8.2" mis-rounding.
(let [zoo-path (str d "/vendor/vivicat-zoo/zoo.bin")]
  (if (.exists (java.io.File. zoo-path))
    (let [zoo (java.nio.file.Files/readAllBytes (java.nio.file.Path/of zoo-path (into-array String [])))
          dec (sh-in-bytes zoo esyrup "decode")
          enc (sh-in-bytes (String. ^bytes (:out dec) "UTF-8") esyrup "encode")]
      (check! "law 3: vivicat zoo.bin reproduced byte-identically"
              (java.util.Arrays/equals ^bytes zoo ^bytes (:out enc))
              (pr-str [(count zoo) (count (:out enc))])))
    (println "SKIP zoo oracle (vendor/vivicat-zoo/zoo.bin missing)")))

(println)
(if (zero? @failures)
  (println "ALL GREEN")
  (do (println @failures "FAILURES") (System/exit 1)))
