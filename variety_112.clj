#!/usr/bin/env bb
;; Encode the 112-variety as Syrup wire format
;; Bridge: tokipona_heyting.edn → Syrup bytes → zig-syrup decoder

(ns variety-112
  (:require [clojure.string :as str]))

;; ============================================================
;; Syrup encoder in Clojure (reference, mirrors src/syrup.zig)
;; ============================================================

(defn encode-bool [v] (if v "t" "f"))

(defn encode-int [n]
  (if (neg? n)
    (str (Math/abs n) "-")
    (str n "+")))

(defn encode-bytestring [bs]
  (str (count bs) ":" bs))

(defn encode-string [s]
  (let [bytes (.getBytes s "UTF-8")]
    (str (count bytes) "\"" s)))

(defn encode-symbol [s]
  (let [bytes (.getBytes s "UTF-8")]
    (str (count bytes) "'" s)))

(defn encode-double [d]
  (let [bits (Double/doubleToLongBits d)
        buf (byte-array 8)]
    (doseq [i (range 8)]
      (aset-byte buf (- 7 i) (unchecked-byte (bit-and (bit-shift-right bits (* i 8)) 0xFF))))
    (str "D" (String. buf "ISO-8859-1"))))

(declare encode-value)

(defn encode-list [items]
  (str "[" (apply str (map encode-value items)) "]"))

(defn encode-dict [entries]
  ;; entries = seq of [k v], sorted by encoded key bytes
  (let [sorted (sort-by (fn [[k _]] (encode-value k)) entries)]
    (str "{" (apply str (mapcat (fn [[k v]] [(encode-value k) (encode-value v)]) sorted)) "}")))

(defn encode-record [label fields]
  (str "<" (encode-value label) (apply str (map encode-value fields)) ">"))

(defn encode-set [items]
  (let [sorted (sort-by encode-value items)]
    (str "#" (apply str (map encode-value sorted)) "$")))

(defn encode-value [v]
  (cond
    (boolean? v) (encode-bool v)
    (integer? v) (encode-int v)
    (double? v) (str v) ;; simplified
    (string? v) (encode-string v)
    (keyword? v) (encode-symbol (name v))
    (vector? v) (encode-list v)
    (map? v) (encode-dict (seq v))
    (set? v) (encode-set (seq v))
    :else (encode-string (str v))))

;; ============================================================
;; The 112 content words
;; ============================================================

(def content-words
  ["akesi" "ala" "alasa" "ale" "anpa" "ante" "awen"
   "esun"
   "ijo" "ike" "ilo" "insa"
   "jaki" "jan" "jelo" "jo"
   "kala" "kalama" "kama" "kasi" "ken" "kepeken" "kili" "kiwen" "ko" "kon" "kule" "kulupu" "kute"
   "lape" "laso" "lawa" "len" "lete" "lili" "linja" "lipu" "loje" "lon" "luka" "lukin" "lupa"
   "ma" "mama" "mani" "meli" "mi" "mije" "moku" "moli" "monsi" "mu" "mun" "musi" "mute"
   "namako" "nanpa" "nasa" "nasin" "nena" "ni" "nimi" "noka"
   "olin" "ona" "open"
   "pakala" "pali" "palisa" "pan" "pana" "pilin" "pimeja" "pini" "pipi" "poka" "poki" "pona" "pu"
   "sama" "seli" "selo" "seme" "sewi" "sijelo" "sike" "sina" "sinpin" "sitelen" "sona" "soweli" "suli" "suno" "supa" "suwi"
   "tan" "taso" "tawa" "telo" "tenpo" "toki" "tomo" "tu"
   "unpa" "uta" "utala"
   "walo" "wan" "waso" "wawa" "weka" "wile"])

(def gf3
  {"ala" -1 "anpa" -1 "ike" -1 "jaki" -1 "lete" -1 "moli" -1
   "pakala" -1 "pimeja" -1 "pini" -1 "weka" -1 "utala" -1 "nasa" -1
   "ale" 1 "kama" 1 "ken" 1 "lon" 1 "mute" 1 "olin" 1
   "open" 1 "pali" 1 "pana" 1 "pona" 1 "seli" 1 "suli" 1
   "suno" 1 "suwi" 1 "wawa" 1 "wile" 1 "musi" 1 "loje" 1
   "namako" 1})

(def cats
  {"akesi" "being" "jan" "being" "kala" "being" "kasi" "being"
   "pipi" "being" "soweli" "being" "waso" "being"
   "insa" "body" "linja" "body" "luka" "body" "lupa" "body"
   "monsi" "body" "nena" "body" "noka" "body" "palisa" "body"
   "pilin" "body" "selo" "body" "sijelo" "body" "sinpin" "body" "uta" "body"
   "anpa" "space" "kon" "space" "ma" "space" "mun" "space"
   "poka" "space" "sewi" "space" "suno" "space" "telo" "space"
   "jelo" "color" "kule" "color" "laso" "color" "loje" "color"
   "pimeja" "color" "walo" "color"
   "ala" "quantity" "lili" "quantity" "mute" "quantity" "nanpa" "quantity"
   "suli" "quantity" "tu" "quantity" "wan" "quantity" "ale" "quantity"
   "ante" "quality" "awen" "quality" "ike" "quality" "jaki" "quality"
   "lete" "quality" "lon" "quality" "nasa" "quality" "open" "quality"
   "pakala" "quality" "pini" "quality" "pona" "quality" "sama" "quality"
   "seli" "quality" "suwi" "quality" "wawa" "quality" "weka" "quality"
   "alasa" "action" "esun" "action" "jo" "action" "kalama" "action"
   "kama" "action" "ken" "action" "kepeken" "action" "kute" "action"
   "lape" "action" "lukin" "action" "moku" "action" "moli" "action"
   "mu" "action" "musi" "action" "olin" "action" "pali" "action"
   "pana" "action" "sitelen" "action" "sona" "action" "tawa" "action"
   "toki" "action" "unpa" "action" "utala" "action" "wile" "action"
   "ijo" "object" "ilo" "object" "kiwen" "object" "ko" "object"
   "len" "object" "lipu" "object" "mani" "object" "pan" "object"
   "poki" "object" "sike" "object" "supa" "object" "tomo" "object" "kili" "object"
   "kulupu" "social" "lawa" "social" "mama" "social" "meli" "social"
   "mije" "social" "mi" "social" "ni" "social" "ona" "social" "sina" "social"
   "nasin" "meta" "nimi" "meta" "pu" "meta" "seme" "meta"
   "tan" "meta" "taso" "meta" "tenpo" "meta" "namako" "quality"})

(defn pol [w] (get gf3 w 0))
(defn chirality [w] (if (#{"action" "meta" "social"} (cats w)) "coterm" "term"))
(defn bidir [w]
  (let [p (pol w) c (chirality w)]
    (cond
      (and (pos? p) (= c "term")) "check"
      (and (pos? p) (= c "coterm")) "synth"
      (and (neg? p) (= c "term")) "synth"
      (and (neg? p) (= c "coterm")) "check"
      (= c "term") "check"
      :else "synth")))

(defn azimuth [w]
  (let [idx (.indexOf content-words w)]
    (mod (* (/ idx 112.0) 360.0) 360.0)))

(defn elevation [w] (* 45.0 (pol w)))

;; ============================================================
;; Encode each word as a Syrup record
;; ============================================================

(defn word-record [w]
  (encode-record
   (keyword "word")
   [(encode-string w)
    (encode-int (pol w))
    (encode-symbol (cats w "unknown"))
    (encode-symbol (chirality w))
    (encode-symbol (bidir w))
    (encode-int (int (azimuth w)))
    (encode-int (int (elevation w)))]))

;; ============================================================
;; Main
;; ============================================================

(println (str "=== 112-variety as Syrup ==="))
(println (str "Words: " (count content-words)))
(println)

;; Sample records
(println "Sample Syrup records:")
(doseq [w ["nimi" "toki" "suno" "pimeja" "pona" "ike" "namako"]]
  (println (str "  " w ": " (word-record w))))
(println)

;; Full variety as a Syrup list
(let [all-records (map word-record content-words)
      variety-syrup (str "[" (apply str all-records) "]")
      byte-count (count (.getBytes variety-syrup "UTF-8"))]
  (println (str "Full variety: " byte-count " bytes"))
  (println (str "Average per word: " (int (/ byte-count 112.0)) " bytes"))
  (println)

  ;; Write binary output
  (spit "/Users/bob/ies/zig-syrup/variety_112.syrup" variety-syrup)
  (println "Written to variety_112.syrup"))

;; Derangement as Syrup dict
(println)
(println "Derangement dict (first 10):")
(let [sigma (loop [todo content-words used #{} result {}]
              (if (empty? todo)
                result
                (let [w (first todo)
                      candidates (remove #(or (= % w) (used %)) content-words)
                      best (first (sort-by #(let [d (Math/abs (- (.indexOf content-words %)
                                                                  (.indexOf content-words w)))]
                                              (if (not= (pol w) (pol %)) (- d 50) d))
                                          candidates))]
                  (recur (rest todo) (conj used best) (assoc result w best)))))
      entries (take 10 (sort sigma))
      dict-syrup (encode-dict (map (fn [[k v]] [(encode-string k) (encode-string v)]) entries))]
  (println (str "  " dict-syrup))
  (println)

  ;; Verify no fixed points
  (let [fixed (count (filter (fn [[k v]] (= k v)) sigma))]
    (println (str "Fixed points: " fixed (if (zero? fixed) " (valid derangement)" " INVALID")))))

(println)
(println "=== Sendable. ===")
