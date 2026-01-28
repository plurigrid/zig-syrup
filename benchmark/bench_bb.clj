#!/usr/bin/env bb
;; Syrup Babashka/Clojure Benchmark
(require '[babashka.classpath :refer [add-classpath]])

;; Load syrup implementation
(load-file "/Users/bob/i/syrup.clj")

(def ITERATIONS 100000)

(defn benchmark [name iterations f]
  ;; Warmup
  (dotimes [_ 1000] (f))

  (let [start (System/nanoTime)
        _ (dotimes [_ iterations] (f))
        elapsed (- (System/nanoTime) start)
        per-op-ns (quot elapsed iterations)
        ops-per-sec (quot (* 1000000000 iterations) elapsed)]
    (println (format "%s: %d ns/op (%d ops/sec)" name per-op-ns ops-per-sec))))

;; Test data: skill:invoke record
(def test-value
  (syrup/syrec "skill:invoke"
    [(symbol "gay-mcp")
     (symbol "palette")
     {"n" 4 "seed" 1069}
     0]))

;; Large list
(def large-list (vec (range 0 4200 42)))

;; Benchmark 1: Encode skill:invoke
(benchmark "Encode skill:invoke" ITERATIONS
  #(syrup/syrup-encode test-value))

;; Benchmark 2: Decode skill:invoke
(def encoded (syrup/syrup-encode test-value))
(benchmark "Decode skill:invoke" ITERATIONS
  #(syrup/syrup-decode encoded))

;; Benchmark 3: Encode large list
(benchmark "Encode list[100]" (/ ITERATIONS 10)
  #(syrup/syrup-encode large-list))

;; Benchmark 4: CID computation
(import '[java.security MessageDigest])
(defn compute-cid [v]
  (let [bytes (syrup/syrup-encode v)
        md (MessageDigest/getInstance "SHA-256")]
    (.digest md bytes)))

(benchmark "CID compute" ITERATIONS #(compute-cid test-value))

;; Benchmark 5: Roundtrip
(def config {"host" "localhost" "port" 8080 "enabled" true})
(benchmark "Roundtrip struct" ITERATIONS
  #(syrup/syrup-decode (syrup/syrup-encode config)))
