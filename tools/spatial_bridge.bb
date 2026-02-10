#!/usr/bin/env bb
;; spatial_bridge.bb — Feed Ghostty split tree topology into the spatial propagator
;; Uses the C ABI exports from libspatial_propagator.dylib
;;
;; Usage:
;;   bb spatial_bridge.bb                    # Parse from current Ghostty windows
;;   bb spatial_bridge.bb /path/to/topo.json # Parse from JSON file
;;
;; The script extracts window geometry via macOS APIs, feeds nodes into the
;; propagator, detects adjacency, assigns golden-spiral colors, and outputs
;; the spatial color map as JSON.

(require '[babashka.process :as p]
         '[babashka.fs :as fs]
         '[cheshire.core :as json]
         '[clojure.string :as str])

;; ============================================================================
;; Window geometry extraction (macOS)
;; ============================================================================

(defn get-ghostty-windows
  "Extract Ghostty window geometry via swift CGWindowListCopyWindowInfo.
   Returns [{:id :x :y :w :h :space :title} ...]"
  []
  (let [;; Use inline Swift — CoreGraphics is always available
        script "
import CoreGraphics
import Foundation

let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var result: [[String: Any]] = []
for w in windowList {
    guard let name = w[kCGWindowOwnerName as String] as? String,
          name.lowercased().contains(\"ghostty\"),
          let bounds = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    result.append([
        \"id\": w[kCGWindowNumber as String] as? Int ?? 0,
        \"x\": Int(bounds[\"X\"] as? Double ?? 0),
        \"y\": Int(bounds[\"Y\"] as? Double ?? 0),
        \"w\": Int(bounds[\"Width\"] as? Double ?? 0),
        \"h\": Int(bounds[\"Height\"] as? Double ?? 0),
        \"space\": w[\"kCGWindowWorkspace\"] as? Int ?? 0,
        \"title\": w[kCGWindowName as String] as? String ?? \"\",
        \"layer\": w[kCGWindowLayer as String] as? Int ?? 0,
        \"pid\": w[kCGWindowOwnerPID as String] as? Int ?? 0,
    ])
}
let data = try! JSONSerialization.data(withJSONObject: result)
print(String(data: data, encoding: .utf8)!)
"
        result (-> (p/shell {:out :string :err :string}
                            "swift" "-e" script)
                   :out
                   str/trim)]
    (json/parse-string result true)))

;; ============================================================================
;; Adjacency detection
;; ============================================================================

(defn shares-edge?
  "Two rects share an edge if they're adjacent with perpendicular overlap."
  [{ax :x ay :y aw :w ah :h} {bx :x by :y bw :w bh :h}]
  (let [ar (+ ax aw) ab (+ ay ah)
        br (+ bx bw) bb_ (+ by bh)
        ;; Horizontal adjacency (within 2px tolerance for window gaps)
        h-adj (or (<= (abs (- ar bx)) 2) (<= (abs (- br ax)) 2))
        v-overlap (and (< ay bb_) (< by ab))
        ;; Vertical adjacency
        v-adj (or (<= (abs (- ab by)) 2) (<= (abs (- bb_ ay)) 2))
        h-overlap (and (< ax br) (< bx ar))]
    (or (and h-adj v-overlap)
        (and v-adj h-overlap))))

(defn detect-edges
  "Given a list of window maps, return edge pairs [i j] for adjacent windows."
  [windows]
  (let [n (count windows)]
    (for [i (range n)
          j (range (inc i) n)
          :when (shares-edge? (nth windows i) (nth windows j))]
      [i j])))

;; ============================================================================
;; Golden spiral color assignment (matching rainbow.zig)
;; ============================================================================

(def golden-angle 137.50776405003785) ;; degrees

(defn hsl->rgb
  "Convert HSL (h in degrees, s and l in 0..1) to [r g b] in 0..255."
  [h s l]
  (let [c (* (- 1.0 (abs (- (* 2.0 l) 1.0))) s)
        h2 (/ (mod h 360.0) 60.0)
        x (* c (- 1.0 (abs (- (mod h2 2.0) 1.0))))
        [r1 g1 b1] (cond
                      (< h2 1) [c x 0]
                      (< h2 2) [x c 0]
                      (< h2 3) [0 c x]
                      (< h2 4) [0 x c]
                      (< h2 5) [x 0 c]
                      :else [c 0 x])
        m (- l (* c 0.5))]
    [(int (* (+ r1 m) 255))
     (int (* (+ g1 m) 255))
     (int (* (+ b1 m) 255))]))

(defn golden-spiral-colors
  "Generate n colors via golden angle spiral, matching rainbow.goldenSpiral."
  [n]
  (mapv (fn [i]
          (let [hue (mod (* i golden-angle) 360.0)
                [r g b] (hsl->rgb hue 0.7 0.55)]
            {:index i
             :hex (format "#%02X%02X%02X" r g b)
             :r r :g g :b b}))
        (range n)))

;; ============================================================================
;; Main
;; ============================================================================

(defn build-topology
  "Build the full spatial topology from Ghostty windows."
  []
  (let [windows (get-ghostty-windows)
        n (count windows)
        _ (when (zero? n)
            (println "No Ghostty windows found.")
            (System/exit 1))
        edges (detect-edges windows)
        colors (golden-spiral-colors n)
        nodes (mapv (fn [i w c]
                      (merge w c
                             {:spatial_index i
                              :adjacent (vec (concat
                                              (map second (filter #(= (first %) i) edges))
                                              (map first (filter #(= (second %) i) edges))))}))
                    (range n) windows colors)]
    {:node_count n
     :edge_count (count edges)
     :edges edges
     :nodes nodes}))

(let [topology (build-topology)]
  (println (json/generate-string topology {:pretty true})))
