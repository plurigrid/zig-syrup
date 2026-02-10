(ns ruler.trifurcation-enforcer
  "Idempotent enforcement: NEVER read/grep/find BEFORE spawning 3 subagents.
   SplitMixTernary XOR-independence requires autonomous context discovery."
  (:require [clojure.string :as str]))

;; SplitMixTernary Constants (GF(3) field operations)
(def GOLDEN 0x9e3779b97f4a7c15)
(def MIX1   0xbf58476d1ce4e5b9)
(def MIX2   0x94d049bb133111eb)
(def SEED   0x42D) ;; 1069

;; Forbidden pre-trifurcation operations
(def forbidden-before-split
  #{:read :grep :find :glob :search :Grep :Read :finder})

;; Trifurcation stream types
(def streams
  {:minus   {:id -1 :role :contracting :action :search}
   :ergodic {:id  0 :role :synthesis   :action :analyze}
   :plus    {:id +1 :role :expanding   :action :create}})

(defn trifurcation-required?
  "Detect if request spans 3+ domains/files/languages"
  [request]
  (let [domains (or (:domains request) [])
        files   (or (:files request) [])
        langs   (or (:languages request) [])]
    (>= (+ (count domains) (count files) (count langs)) 3)))

(defn validate-no-presearch
  "ENFORCE: No read operations before subagent spawn."
  [operation-sequence]
  (let [split-idx (->> operation-sequence
                       (map-indexed vector)
                       (filter #(= :spawn-subagent (second %)))
                       first
                       first)]
    (if (nil? split-idx)
      {:valid false :reason :no-trifurcation}
      (let [pre-split (take split-idx operation-sequence)
            violations (filter forbidden-before-split pre-split)]
        (if (seq violations)
          {:valid false 
           :violation (first violations)
           :reason :presearch-before-split}
          {:valid true})))))

(defn spawn-trifurcated-tasks
  "Generate 3 XOR-independent subagent specifications."
  [base-task]
  [(merge base-task 
          {:stream :minus 
           :constraint "Search/discover in contracting domain"
           :xor-independent true})
   (merge base-task 
          {:stream :ergodic 
           :constraint "Synthesize/analyze WITHOUT reading new files"
           :xor-independent true})
   (merge base-task 
          {:stream :plus 
           :constraint "Parallel search OR creation in expanding domain"
           :xor-independent true})])

(defn enforce!
  "Main enforcement entry point."
  [request planned-ops]
  (if (trifurcation-required? request)
    (let [validation (validate-no-presearch planned-ops)]
      (if (:valid validation)
        {:proceed true :tasks (spawn-trifurcated-tasks request)}
        {:proceed false 
         :error "TRIFURCATION VIOLATION"
         :details validation
         :remedy "STOP and spawn 3 subagents IMMEDIATELY"}))
    {:proceed true :single-agent true}))

;; Idempotent rule declaration
(def ^:const RULE
  {:name "trifurcation-first"
   :version "1.0.0"
   :trigger "3+ domains/files/languages in request"
   :enforcement :strict
   :gf3-conservation true})
