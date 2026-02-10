"""
Bridge 9 Phase 4: Feedback Display Integration (Mojo)

Real-time color feedback from robot execution state.
Backward morphism: RobotState → PhenomenalState → Color visualization

Mojo version: Compiled performance for 50Hz real-time loop
"""

from collections import List, Dict
from math import sqrt, sin, cos, pi, log
from enum import Enum
import json

# ============================================================================
# Robot State Representation
# ============================================================================

@value
struct RobotState:
    """Robot state from Modbus TCP (mirrors Zig ur_robot_adapter.zig)"""
    timestamp_us: Int
    joint_angles: List[Float32]  # 6 elements
    joint_velocities: List[Float32]  # 6 elements
    joint_accelerations: List[Float32]  # 6 elements
    gripper_width: Float32  # mm
    gripper_force: Float32  # Newtons
    tool_frame_x: Float32  # meters
    tool_frame_y: Float32
    tool_frame_z: Float32
    tool_frame_roll: Float32  # radians
    tool_frame_pitch: Float32
    tool_frame_yaw: Float32
    end_effector_velocity: Float32  # m/s
    collision_detected: Bool
    task_progress: Float32  # 0-1
    confidence: Float32  # 0-1

    fn to_dict(self) -> Dict[String, Object]:
        """Serialize to dict"""
        var d = Dict[String, Object]()
        d["timestamp_us"] = self.timestamp_us
        d["gripper_width"] = self.gripper_width
        d["gripper_force"] = self.gripper_force
        d["tool_frame_x"] = self.tool_frame_x
        d["tool_frame_y"] = self.tool_frame_y
        d["tool_frame_z"] = self.tool_frame_z
        d["end_effector_velocity"] = self.end_effector_velocity
        d["collision_detected"] = self.collision_detected
        d["task_progress"] = self.task_progress
        d["confidence"] = self.confidence
        return d

# ============================================================================
# GF(3) Trit Assignment
# ============================================================================

@value
struct GF3Trit:
    """GF(3) trit values for phenomenal state classification"""
    alias MINUS = -1
    alias ERGODIC = 0
    alias PLUS = 1

    value: Int

    fn __str__(self) -> String:
        if self.value == -1:
            return "MINUS"
        elif self.value == 0:
            return "ERGODIC"
        else:
            return "PLUS"

# ============================================================================
# Backward Morphism: RobotState → PhenomenalState
# ============================================================================

@value
struct PhenomenalStateFeedback:
    """Phenomenal state derived from robot execution"""
    phi: Float32  # Engagement angle [0, π/2]
    valence: Float32  # Affect [-1, +1]
    entropy: Float32  # Uncertainty [0, 8 bits]
    dominant_band: String  # "alpha" for post-motor activity
    dominant_power: Float32  # 0-1
    timestamp_us: Int
    confidence: Float32  # 0-1
    gf3_trit: Int  # GF(3) classification

    fn to_dict(self) -> Dict[String, Object]:
        var d = Dict[String, Object]()
        d["phi"] = self.phi
        d["valence"] = self.valence
        d["entropy"] = self.entropy
        d["dominant_band"] = self.dominant_band
        d["dominant_power"] = self.dominant_power
        d["timestamp_us"] = self.timestamp_us
        d["confidence"] = self.confidence

        var trit_name: String
        if self.gf3_trit == -1:
            trit_name = "MINUS"
        elif self.gf3_trit == 0:
            trit_name = "ERGODIC"
        else:
            trit_name = "PLUS"
        d["gf3_trit"] = trit_name
        return d

# ============================================================================
# Backward Morphism Implementation
# ============================================================================

struct BackwardMorphism:
    """Transforms robot state → phenomenal state"""

    @staticmethod
    fn joint_configuration_to_engagement(angles: List[Float32]) -> Float32:
        """
        Convert joint configuration (radians) → engagement angle φ ∈ [0, π/2]

        Intuition: spread configuration = high engagement, compact = low
        """
        var total: Float32 = 0.0
        for angle in angles:
            if angle < 0:
                total += -angle
            else:
                total += angle

        # Map [0, 3π] → [0, π/2]
        var normalized = total / (3.0 * Float32(3.14159265359))
        var phi = min(Float32(3.14159265359) / 2.0, normalized * 1.5708)
        return phi

    @staticmethod
    fn joint_velocities_to_valence(velocities: List[Float32]) -> Float32:
        """
        Convert joint velocity magnitudes → valence ∈ [-1, +1]

        Positive valence: smooth, coordinated motion
        Negative valence: jerky, high acceleration variance
        """
        var mean_speed: Float32 = 0.0
        var count: Int = 0

        # Compute absolute values and mean
        var speed_mags = List[Float32]()
        for v in velocities:
            var abs_v = v if v >= 0 else -v
            speed_mags.append(abs_v)
            mean_speed += abs_v
            count += 1

        mean_speed /= Float32(count)

        # Compute variance
        var variance: Float32 = 0.0
        for mag in speed_mags:
            var diff = mag - mean_speed
            variance += diff * diff

        variance /= Float32(count)

        # Smoothness = 1 / (1 + sqrt(variance))
        var smoothness = 1.0 / (1.0 + sqrt(variance))

        # Map [0,1] → [-1,+1]
        var valence = smoothness * 2.0 - 1.0

        # Clamp to [-1,+1]
        if valence < -1.0:
            valence = -1.0
        elif valence > 1.0:
            valence = 1.0

        return valence

    @staticmethod
    fn tool_pose_to_entropy(x: Float32, y: Float32, z: Float32,
                           roll: Float32, pitch: Float32, yaw: Float32) -> Float32:
        """
        Convert tool frame pose → entropy ∈ [0, 8 bits]

        Higher uncertainty → higher entropy
        """
        var position_spread = sqrt(x*x + y*y + z*z)

        var orientation_spread: Float32 = 0.0
        if roll < 0:
            orientation_spread -= roll
        else:
            orientation_spread += roll

        if pitch < 0:
            orientation_spread -= pitch
        else:
            orientation_spread += pitch

        if yaw < 0:
            orientation_spread -= yaw
        else:
            orientation_spread += yaw

        # Entropy = log₂(position_spread + orientation_spread + 1)
        # Normalized to [0, 8]
        var total_spread = position_spread + orientation_spread
        var entropy_raw = (8.0 / log(256.0)) * log(total_spread + 1.0)

        if entropy_raw < 0.0:
            entropy_raw = 0.0
        elif entropy_raw > 8.0:
            entropy_raw = 8.0

        return entropy_raw

    @staticmethod
    fn apply(robot_state: RobotState, baseline: PhenomenalStateFeedback) -> PhenomenalStateFeedback:
        """
        Complete backward morphism: RobotState → PhenomenalState

        Transforms robot execution state to perceived phenomenal state.
        """
        # Compute phenomenal components
        var phi = Self.joint_configuration_to_engagement(robot_state.joint_angles)
        var valence = Self.joint_velocities_to_valence(robot_state.joint_velocities)
        var entropy = Self.tool_pose_to_entropy(
            robot_state.tool_frame_x, robot_state.tool_frame_y, robot_state.tool_frame_z,
            robot_state.tool_frame_roll, robot_state.tool_frame_pitch, robot_state.tool_frame_yaw
        )

        # Adjust confidence for collisions
        var confidence = baseline.confidence
        if robot_state.collision_detected:
            confidence *= 0.5

        # Task progress reduces entropy
        var task_entropy_reduction = entropy * (1.0 - robot_state.task_progress)
        var final_entropy = entropy - task_entropy_reduction
        if final_entropy < 0.0:
            final_entropy = 0.0

        # GF(3) trit assignment
        var success_score = (valence * 0.5) + ((1.0 - (final_entropy / 8.0)) * 0.5)
        var engagement_factor: Float32 = 1.2 if phi > 0.7 else 1.0

        var gf3_trit: Int
        if success_score * engagement_factor > 0.3:
            gf3_trit = 1  # PLUS
        elif success_score * engagement_factor < -0.3:
            gf3_trit = -1  # MINUS
        else:
            gf3_trit = 0  # ERGODIC

        # Clamp confidence
        if confidence < 0.0:
            confidence = 0.0
        elif confidence > 1.0:
            confidence = 1.0

        return PhenomenalStateFeedback(
            phi=phi,
            valence=valence,
            entropy=final_entropy,
            dominant_band="alpha",
            dominant_power=0.5,
            timestamp_us=robot_state.timestamp_us,
            confidence=confidence,
            gf3_trit=gf3_trit,
        )

# ============================================================================
# Color Projection: PhenomenalState → HSL → RGB
# ============================================================================

@value
struct HSLColor:
    hue: Float32  # degrees [0, 360]
    saturation: Float32  # [0, 1]
    lightness: Float32  # [0, 1]

@value
struct RGBColor:
    red: Float32  # [0, 1]
    green: Float32
    blue: Float32

    fn to_hex(self) -> String:
        """Convert to hex color string"""
        var r = Int(max(0, min(255, self.red * 255)))
        var g = Int(max(0, min(255, self.green * 255)))
        var b = Int(max(0, min(255, self.blue * 255)))

        # Format as hex string
        var hex_str = "#"

        # Red
        if r < 16:
            hex_str += "0"
        hex_str += String(r, radix=16)

        # Green
        if g < 16:
            hex_str += "0"
        hex_str += String(g, radix=16)

        # Blue
        if b < 16:
            hex_str += "0"
        hex_str += String(b, radix=16)

        return hex_str

    fn to_ansi256(self) -> Int:
        """Convert to xterm-256 palette index"""
        var r_idx = Int(self.red * 5)
        var g_idx = Int(self.green * 5)
        var b_idx = Int(self.blue * 5)
        # xterm-256 color cube starts at index 16
        return 16 + (36 * r_idx) + (6 * g_idx) + b_idx

# ============================================================================
# Color Projection Implementation
# ============================================================================

struct ColorProjection:
    """Projects phenomenal state to color space"""

    @staticmethod
    fn phenomenal_to_hsl(state: PhenomenalStateFeedback) -> HSLColor:
        """
        Project phenomenal state to HSL color space.

        Hue: valence (-1 red, 0 yellow, +1 green)
        Saturation: entropy (high uncertainty = vibrant)
        Lightness: engagement φ (low φ = dark, high φ = bright)
        """
        # Valence → Hue: [-1,+1] → [0°, 120°] (red to green)
        var hue = 60.0 + (state.valence * 60.0)
        if hue < 0.0:
            hue += 360.0

        # Entropy → Saturation: [0,8] → [0,1]
        var saturation = state.entropy / 8.0

        # Engagement → Lightness: [0,π/2] → [0.3, 0.7]
        var phi_normalized = state.phi / 1.5708
        var lightness = 0.3 + (phi_normalized * 0.4)

        return HSLColor(
            hue=hue,
            saturation=max(0.0, min(1.0, saturation)),
            lightness=max(0.3, min(0.7, lightness)),
        )

    @staticmethod
    fn hsl_to_rgb(hsl: HSLColor) -> RGBColor:
        """Standard HSL → RGB conversion"""
        var h = hsl.hue / 60.0
        var s = hsl.saturation
        var l = hsl.lightness

        var c = s * (1.0 - abs(2.0 * l - 1.0))
        var x = c * (1.0 - abs(h % 2.0 - 1.0))
        var m = l - c / 2.0

        var r_prime: Float32 = 0.0
        var g_prime: Float32 = 0.0
        var b_prime: Float32 = 0.0

        if h < 1.0:
            r_prime = c
            g_prime = x
            b_prime = 0.0
        elif h < 2.0:
            r_prime = x
            g_prime = c
            b_prime = 0.0
        elif h < 3.0:
            r_prime = 0.0
            g_prime = c
            b_prime = x
        elif h < 4.0:
            r_prime = 0.0
            g_prime = x
            b_prime = c
        elif h < 5.0:
            r_prime = x
            g_prime = 0.0
            b_prime = c
        else:
            r_prime = c
            g_prime = 0.0
            b_prime = x

        return RGBColor(
            red=r_prime + m,
            green=g_prime + m,
            blue=b_prime + m,
        )

    @staticmethod
    fn phenomenal_to_rgb(state: PhenomenalStateFeedback) -> RGBColor:
        """Complete projection: PhenomenalState → RGB"""
        var hsl = Self.phenomenal_to_hsl(state)
        return Self.hsl_to_rgb(hsl)

# ============================================================================
# Feedback Loop Coordinator
# ============================================================================

struct Bridge9FeedbackController:
    """
    Integrates backward morphism + color feedback.

    Real-time control loop (50Hz):
    1. Read robot state via Modbus TCP
    2. Apply backward morphism → phenomenal state
    3. Project to HSL/RGB colors
    4. Output feedback (terminal, Emacs, DuckDB)
    """

    var baseline: PhenomenalStateFeedback
    var state_history: List[Dict[String, Object]]
    var color_history: List[String]

    fn __init__(inout self, baseline_phenomenal: PhenomenalStateFeedback):
        self.baseline = baseline_phenomenal
        self.state_history = List[Dict[String, Object]]()
        self.color_history = List[String]()

    fn process_robot_state(inout self, robot_state: RobotState) -> Dict[String, Object]:
        """
        Process single robot state through full feedback pipeline.

        Returns dict with phenomenal state, colors, and metadata.
        """
        # Apply backward morphism
        var phenomenal = BackwardMorphism.apply(robot_state, self.baseline)

        # Project to colors
        var rgb = ColorProjection.phenomenal_to_rgb(phenomenal)

        # Prepare output
        var result = Dict[String, Object]()
        result["timestamp_us"] = robot_state.timestamp_us
        result["robot_state"] = robot_state.to_dict()
        result["phenomenal_state"] = phenomenal.to_dict()

        var color_dict = Dict[String, Object]()
        color_dict["hex"] = rgb.to_hex()
        color_dict["ansi256"] = rgb.to_ansi256()
        result["color"] = color_dict

        var trit_name: String
        if phenomenal.gf3_trit == -1:
            trit_name = "MINUS"
        elif phenomenal.gf3_trit == 0:
            trit_name = "ERGODIC"
        else:
            trit_name = "PLUS"
        result["gf3_classification"] = trit_name

        # Update history
        self.state_history.append(result)
        self.color_history.append(rgb.to_hex())

        # Update baseline for next iteration
        self.baseline = phenomenal

        return result

    fn process_batch(inout self, robot_states: List[RobotState]) -> List[Dict[String, Object]]:
        """Process multiple robot states"""
        var results = List[Dict[String, Object]]()
        for state in robot_states:
            var result = self.process_robot_state(state)
            results.append(result)
        return results

    fn get_summary(self) -> Dict[String, Object]:
        """Generate summary statistics"""
        if self.state_history.size() == 0:
            return Dict[String, Object]()

        var plus_count = 0
        var minus_count = 0
        var ergodic_count = 0

        for state in self.state_history:
            var trit = state["gf3_classification"]
            # Note: trit is a String at this point

        var result = Dict[String, Object]()
        result["total_states"] = self.state_history.size()
        result["latest_color"] = self.color_history[-1] if self.color_history.size() > 0 else "#FFFFFF"

        return result

# ============================================================================
# Demo
# ============================================================================

fn demo_feedback_loop():
    """Demonstrate Phase 4 feedback in action"""
    print("Bridge 9 Phase 4: Feedback Display Demo (Mojo)")
    print("=" * 50)

    # Create baseline phenomenal state
    var baseline = PhenomenalStateFeedback(
        phi=0.5,
        valence=0.0,
        entropy=2.0,
        dominant_band="alpha",
        dominant_power=0.5,
        timestamp_us=0,
        confidence=0.9,
        gf3_trit=0,
    )

    var controller = Bridge9FeedbackController(baseline)

    # Simulate robot executing task (relaxed to engaged)
    for i in range(5):
        var progress = Float32(i) / 4.0

        var angles = List[Float32]()
        for _ in range(6):
            angles.append(0.1 + progress * 1.0)

        var velocities = List[Float32]()
        for _ in range(6):
            velocities.append(0.05 - progress * 0.01)

        var accelerations = List[Float32]()
        for _ in range(6):
            accelerations.append(0.0)

        var robot_state = RobotState(
            timestamp_us=1000000 + i * 100000,
            joint_angles=angles,
            joint_velocities=velocities,
            joint_accelerations=accelerations,
            gripper_width=50.0 + progress * 30.0,
            gripper_force=10.0 + progress * 20.0,
            tool_frame_x=progress * 0.3,
            tool_frame_y=progress * 0.2,
            tool_frame_z=0.5,
            tool_frame_roll=0.1 * progress,
            tool_frame_pitch=0.1 * progress,
            tool_frame_yaw=0.05 * progress,
            end_effector_velocity=progress * 0.5,
            collision_detected=False,
            task_progress=progress,
            confidence=0.8 + progress * 0.15,
        )

        var result = controller.process_robot_state(robot_state)
        var phenomenal = result["phenomenal_state"]

        print("\nStep " + String(i + 1) + ":")
        print("  φ (engagement): " + String(phenomenal["phi"]))
        print("  Valence:        " + String(phenomenal["valence"]))
        print("  Entropy:        " + String(phenomenal["entropy"]))
        print("  Color:          " + result["color"]["hex"] + " (GF(3):" + result["gf3_classification"] + ")")
        print("  Task progress:  " + String(robot_state.task_progress * 100.0) + "%")

    print("\n" + "=" * 50)
    print("✅ Phase 4 Feedback Loop Complete")

fn main():
    demo_feedback_loop()
