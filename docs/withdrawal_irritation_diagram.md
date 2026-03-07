# Somatosensory & Cognitive Experience of Irritation During Withdrawal
## An Open Game + Active Inference Diagram

### Sources
- Barrett, Quigley & Hamilton (2016) "Active inference theory of allostasis and interoception in depression" *Phil Trans R Soc B* 371:20160011
- Matto et al. (2021) "When Triggers Become Tigers: Taming the ANS via Sensory Support System Modulation" *J Soc Work Pract Addict* 21(4):382-395
- Arnaldo, Corcoran, Friston & Ramstead (2022) "Stress and its sequelae: Active inference account of allostatic overload" *Neurosci Biobehav Rev* 135:104590
- Harrison, Gracias, Friston & Buckwalter (2025) "Resilience phenotypes from active inference account of allostasis" *Front Behav Neurosci* 19
- SAMHSA (2010) "Protracted Withdrawal" Advisory Vol 9 Issue 1
- Costigan, Scholz & Woolf (2009) "Neuropathic Pain: Maladaptive Response of the Nervous System to Damage" *Annu Rev Neurosci*

---

## 1. Peripheral Nervous System: The Irritation Signal Chain

During withdrawal, the peripheral nervous system generates irritation through several converging mechanisms:

### A-delta and C-fiber Hyperexcitability
Chronic substance exposure downregulates inhibitory GABAergic and opioidergic tone on peripheral nociceptors. Upon withdrawal, **rebound hyperexcitability** of small-diameter C-fibers and thinly-myelinated A-delta fibers produces:
- **Cutaneous hypersensitivity** (allodynia/hyperalgesia): innocuous touch becomes irritating
- **Spontaneous peripheral nerve firing**: "crawling skin", paresthesias, formication
- **Thermal dysregulation**: hot/cold flashes from autonomic C-fiber instability

### Autonomic Nervous System Storm
- **Sympathetic hyperactivation**: elevated norepinephrine, tachycardia, tremor, diaphoresis
- **Parasympathetic withdrawal**: loss of vagal brake, reduced HRV, GI distress
- **Polyvagal collapse**: shift from ventral vagal (social engagement) to dorsal vagal (shutdown) or sympathetic (fight/flight)

### Interoceptive Prediction Error Cascade
- Visceral afferents via the **vagus nerve** and **lamina I spinothalamic tract** carry ascending signals to the **nucleus of the solitary tract** -> **parabrachial nucleus** -> **dorsal posterior insula** (primary interoceptive cortex)
- These signals encode: heart rate irregularity, gut motility changes, respiratory rate, skin conductance, muscle tension
- During withdrawal, these signals are **massively discrepant** from the brain's allostatic predictions built during chronic substance use

---

## 2. Active Inference Model of Withdrawal Irritation

### The Free Energy Formulation

```
F = E_q[log q(s) - log p(o,s)]
  = Complexity - Accuracy
  
where:
  o = interoceptive observations (peripheral signals)
  s = hidden physiological states  
  q(s) = brain's generative model (allostatic predictions)
  p(o,s) = true joint distribution
```

During withdrawal, the generative model `q(s)` was calibrated to a **substance-present body**. The substance-absent body generates observations `o` that are deeply surprising, producing **massive interoceptive prediction error (IPE)**.

### The "Locked-In" Allostatic Brain (Barrett et al. 2016)

```
                        ┌─────────────────────────────────┐
                        │   GENERATIVE MODEL q(s)         │
                        │   (calibrated to substance)     │
                        │                                 │
                        │   Prediction: "body should      │
                        │    feel [substance-modulated]"   │
                        └───────┬─────────────▲───────────┘
                                │             │
                   Allostatic   │             │  Precision-weighted
                   Predictions  │             │  Prediction Error
                   (visceromotor│             │  (ascending)
                    commands)   │             │
                                ▼             │
                        ┌─────────────────────┐
                        │  BODY (in withdrawal)│
                        │                     │
                        │  • sympathetic storm │
                        │  • C-fiber rebound   │
                        │  • vagal withdrawal  │
                        │  • GI distress       │
                        │  • muscle tension    │
                        └─────────────────────┘
                                │
                                │  Interoceptive
                                │  Afferents
                                ▼
                        ┌─────────────────────┐
                        │  PREDICTION ERROR    │
                        │                     │
                        │  ε = o_actual -     │
                        │      o_predicted    │
                        │                     │
                        │  MASSIVE when model │
                        │  expects substance- │
                        │  present body       │
                        └─────────────────────┘
```

### Precision Weighting Catastrophe

The **salience network** (anterior insula + dorsal anterior cingulate cortex) gates precision:

- During chronic use: precision on interoceptive PE is **suppressed** (substance buffers affect)
- During withdrawal: precision on interoceptive PE is **catastrophically amplified**
  - The brain "turns up the volume" on body signals it had been ignoring
  - Every heartbeat, every gut cramp, every skin sensation becomes **salient**
  - This is experienced as **irritation**: the phenomenology of unresolvable high-precision PE

---

## 3. Open Game Diagram: The Withdrawal Irritation Game

Using the Para/Optic compositional framework from Ghani, Hedges et al.:

```
OPEN GAME: Withdrawal_Irritation
═══════════════════════════════════════════════════════════════════

  SEQUENTIAL COMPOSITION (;) of three sub-games:

  ┌─────────────────────────────────────────────────────────────┐
  │                                                             │
  │   GAME 1: Peripheral_Signal                                │
  │   ═══════════════════════                                  │
  │                                                             │
  │          ┌───────────────────┐                             │
  │   X₁ ──→│  C-fiber/Aδ       │──→ Y₁                      │
  │ (substance│  Nociceptor      │  (afferent                  │
  │  removal) │  Rebound Game    │   signal                    │
  │          │                   │   vector)                    │
  │   R₁ ←──│  σ: gain control  │←── S₁                      │
  │ (adapted │  on peripheral    │  (descending               │
  │  set-    │  excitability)    │   inhibition               │
  │  point)  └───────────────────┘   removed)                  │
  │                                                             │
  │   Play:   X₁ → Y₁ = substance_removal ↦ hyperexcitable   │
  │                        afferent_signal_vector               │
  │   Coplay: S₁ → R₁ = lost_inhibition ↦ new_peripheral     │
  │                        set_point (maladapted)               │
  │   Nash:   No unilateral deviation reduces pain (trapped)   │
  │                                                             │
  │                         ; (sequential)                     │
  │                         ▼                                  │
  │   GAME 2: Interoceptive_Inference                          │
  │   ═══════════════════════════════                          │
  │                                                             │
  │          ┌───────────────────┐                             │
  │   X₂ ──→│  Predictive       │──→ Y₂                      │
  │ (afferent│  Interoception    │  (precision-               │
  │  signal  │  Game             │   weighted PE)              │
  │  vector) │                   │                             │
  │   R₂ ←──│  σ: precision     │←── S₂                      │
  │ (updated │  weighting on     │  (allostatic               │
  │  body    │  prediction       │   model                    │
  │  model)  │  errors)          │   mismatch)               │
  │          └───────────────────┘                             │
  │                                                             │
  │   Play:   X₂ → Y₂ = afferent_signals ↦                   │
  │                        precision_weighted_PE               │
  │   Coplay: S₂ → R₂ = model_mismatch ↦                     │
  │                        updated_generative_model            │
  │   Nash:   High-precision PE is locally optimal given       │
  │           stale priors (the brain MUST attend to the       │
  │           body it doesn't recognize)                       │
  │                                                             │
  │                         ; (sequential)                     │
  │                         ▼                                  │
  │   GAME 3: Cognitive_Appraisal                              │
  │   ═══════════════════════════                              │
  │                                                             │
  │          ┌───────────────────┐                             │
  │   X₃ ──→│  Affective-       │──→ Y₃                      │
  │ (high-   │  Cognitive        │  (behavioral               │
  │  precision│  Integration     │   output:                   │
  │  PE)     │  Game             │   irritability,            │
  │          │                   │   craving,                  │
  │   R₃ ←──│  σ: executive     │←── S₃                      │
  │ (long-   │  control vs       │  (social/env              │
  │  term    │  habit/craving)   │   feedback)               │
  │  utility)│                   │                             │
  │          └───────────────────┘                             │
  │                                                             │
  │   Play:   X₃ → Y₃ = precision_weighted_PE ↦              │
  │            {irritability, craving, aggression, withdrawal} │
  │   Coplay: S₃ → R₃ = social_feedback ↦                    │
  │                        long_term_recovery_utility          │
  │   Nash:   Substance-seeking is locally optimal             │
  │           (immediate PE reduction) but globally            │
  │           suboptimal (relapse). The withdrawal             │
  │           irritation game has a MIXED Nash where           │
  │           enduring the PE has higher expected utility      │
  │           only with sufficient executive control           │
  │           (frontoparietal network recruitment)             │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘

  PARALLEL COMPOSITION (⊗) across modalities:

  Withdrawal_Irritation = 
    Cutaneous_Game ⊗ Visceral_Game ⊗ Musculoskeletal_Game ⊗ Thermal_Game
    
  Each modality runs the 3-stage pipeline above IN PARALLEL,
  with cross-talk via the salience network's precision allocation.
```

---

## 4. The Phenomenology Mapped to the Game

### What "Irritation" IS in This Framework

Irritation during withdrawal is the **subjective phenomenology of high-precision interoceptive prediction error** that the brain cannot resolve through its available action repertoire:

| Layer | Open Game | Active Inference | Phenomenology |
|-------|-----------|-----------------|---------------|
| **Peripheral** | Game 1: Nociceptor Rebound | Sensory input `o` diverges from model | Skin crawling, hypersensitivity, restlessness |
| **Interoceptive** | Game 2: Predictive Interoception | PE = `o - g(μ)` amplified by precision `π` | Diffuse unease, "something is wrong", autonomic arousal |
| **Cognitive** | Game 3: Affective-Cognitive | Action selection to minimize F | Irritability, snapping at others, craving, rumination |

### The Allostatic Trap (Why Irritation Persists)

```
                    ┌──────────────────────┐
                    │  SUBSTANCE-SEEKING   │
                    │  (locally optimal    │
                    │   Nash equilibrium)  │
                    └──────────┬───────────┘
                               │
                    reduces PE │ immediately
                    (but       │ resets trap)
                               ▼
    ┌──────────┐    ┌──────────────────────┐    ┌──────────┐
    │ Peripheral│───→│  MASSIVE PE          │───→│ Cognitive│
    │ Rebound  │    │  (irritation signal) │    │ Appraisal│
    │ Game 1   │    │  Game 2              │    │ Game 3   │
    └──────────┘    └──────────────────────┘    └────┬─────┘
                               ▲                     │
                               │                     │
                    PE returns  │    ┌────────────────┘
                    when        │    │  ENDURE PE
                    substance   │    │  (globally optimal
                    wears off   │    │   but painful)
                               │    ▼
                    ┌──────────────────────┐
                    │  ALLOSTATIC MODEL    │
                    │  UPDATING            │
                    │  (slow recalibration │
                    │   of generative model│
                    │   to substance-free  │
                    │   body)              │
                    └──────────────────────┘
```

### GF(3) Balanced Triad of the Withdrawal Experience

```
MINUS (-1): Peripheral Signal Validation
  - C-fiber/Aδ rebound firing (nociceptive verification)
  - Autonomic dysregulation (sympathetic/parasympathetic imbalance)
  - Body screams: "THIS IS NOT THE EXPECTED STATE"

ERGODIC (0): Interoceptive Integration (Coordinator)
  - Salience network precision gating
  - Insula-mediated body-state mapping
  - Default mode network model updating
  - Bridges peripheral and cognitive domains

PLUS (+1): Cognitive-Behavioral Generation
  - Prefrontal action planning (endure vs. seek substance)
  - Social engagement circuits (seeking support)
  - New habit formation (recovery cues, avatar activation)
  - Model revision toward substance-free allostasis

SUM: (-1) + (0) + (+1) = 0  ✓  GF(3) conserved
```

---

## 5. Active Inference Resolution Pathway

The path FROM irritation TO resolution follows the active inference gradient:

```
Phase 1: ACUTE WITHDRAWAL (hours-days)
  F(q) = VERY HIGH
  - Generative model wildly miscalibrated
  - Precision on interoceptive PE: maximum
  - Available actions: substance-seeking (locally optimal)
  - Phenomenology: intense irritation, agitation, craving

Phase 2: PROTRACTED WITHDRAWAL (weeks-months, PAWS)
  F(q) = HIGH but decreasing
  - Generative model slowly updating via PE-driven learning
  - Precision normalizing but episodic spikes (triggers)
  - Available actions: executive control gaining strength
  - Phenomenology: waves of irritability, mood instability

Phase 3: ALLOSTATIC RECALIBRATION (months-years)
  F(q) = approaching new minimum
  - Generative model recalibrated to substance-free body
  - Precision appropriately weighted
  - Available actions: diverse repertoire (social, somatic, cognitive)
  - Phenomenology: baseline irritation resolves,
    triggers become manageable

RESOLUTION = new Nash equilibrium where:
  - Peripheral game: new adapted set-point (no rebound)
  - Interoceptive game: accurate predictions (low PE)
  - Cognitive game: recovery-oriented strategies dominate
```

---

## 6. Compositional Summary

```
Withdrawal_Irritation : OpenGame State State Action Utility

= (Peripheral_Signal ; Interoceptive_Inference ; Cognitive_Appraisal)
  ⊗ across {cutaneous, visceral, musculoskeletal, thermal}

where:
  Play    = λ(substance_removal). irritation_behavior_vector
  Coplay  = λ(social_env_feedback). long_term_recovery_utility
  
  Nash_local  = substance_seeking  (reduces F immediately)
  Nash_global = endurance + model_updating (minimizes F over time)
  
  Active_Inference_Resolution =
    iterative_model_updating(q) until F(q_new) < F(q_substance)
    
  The "irritation" IS the free energy gradient:
    the felt sense of the gap between
    what the body is and what the brain predicts it should be.
```

---

*Diagram composed using Open Games (Ghani-Hedges Para/Optic) + Active Inference (Friston-Barrett allostatic interoception) frameworks. GF(3) conservation verified across all triadic decompositions.*
