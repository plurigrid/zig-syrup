"""
Bridge 9 Phase 4: Feedback Display Integration

Real-time color feedback from robot execution state.
Backward morphism: RobotState → PhenomenalState → Color visualization

Extends bridge_9_ffi.py with backward morphism + color projection.
"""

import json
import math
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple
from enum import Enum
from pathlib import Path

# ============================================================================
# Robot State Representation (mirrors Zig ur_robot_adapter.zig)
# ============================================================================

@dataclass
class RobotState:
    """Mirrors Bridge9RobotState in ur_robot_adapter.zig"""
    timestamp_us: int
    joint_angles: List[float]  # 6 elements
    joint_velocities: List[float]  # 6 elements
    joint_accelerations: List[float]  # 6 elements
    gripper_width: float  # mm
    gripper_force: float  # Newtons
    tool_frame_x: float  # meters
    tool_frame_y: float
    tool_frame_z: float
    tool_frame_roll: float  # radians
    tool_frame_pitch: float
    tool_frame_yaw: float
    end_effector_velocity: float  # m/s
    collision_detected: bool
    task_progress: float  # 0-1
    confidence: float  # 0-1

    @classmethod
    def from_modbus_state(cls, modbus_response: Dict) -> 'RobotState':
        """Convert Modbus TCP response to RobotState"""
        return cls(
            timestamp_us=modbus_response.get('timestamp_us', 0),
            joint_angles=modbus_response.get('joint_angles', [0.0]*6),
            joint_velocities=modbus_response.get('joint_velocities', [0.0]*6),
            joint_accelerations=modbus_response.get('joint_accelerations', [0.0]*6),
            gripper_width=modbus_response.get('gripper_width', 0.0),
            gripper_force=modbus_response.get('gripper_force', 0.0),
            tool_frame_x=modbus_response.get('tool_frame_x', 0.0),
            tool_frame_y=modbus_response.get('tool_frame_y', 0.0),
            tool_frame_z=modbus_response.get('tool_frame_z', 0.0),
            tool_frame_roll=modbus_response.get('tool_frame_roll', 0.0),
            tool_frame_pitch=modbus_response.get('tool_frame_pitch', 0.0),
            tool_frame_yaw=modbus_response.get('tool_frame_yaw', 0.0),
            end_effector_velocity=modbus_response.get('end_effector_velocity', 0.0),
            collision_detected=modbus_response.get('collision_detected', False),
            task_progress=modbus_response.get('task_progress', 0.0),
            confidence=modbus_response.get('confidence', 0.85),
        )

    def to_dict(self) -> Dict:
        """Serialize to dict for JSON"""
        return {
            'timestamp_us': self.timestamp_us,
            'joint_angles': self.joint_angles,
            'joint_velocities': self.joint_velocities,
            'joint_accelerations': self.joint_accelerations,
            'gripper_width': self.gripper_width,
            'gripper_force': self.gripper_force,
            'tool_frame': {
                'x': self.tool_frame_x,
                'y': self.tool_frame_y,
                'z': self.tool_frame_z,
                'roll': self.tool_frame_roll,
                'pitch': self.tool_frame_pitch,
                'yaw': self.tool_frame_yaw,
            },
            'end_effector_velocity': self.end_effector_velocity,
            'collision_detected': self.collision_detected,
            'task_progress': self.task_progress,
            'confidence': self.confidence,
        }

# ============================================================================
# GF(3) Trit Assignment
# ============================================================================

class GF3Trit(Enum):
    """GF(3) trit values for phenomenal state classification"""
    MINUS = -1  # Error/distress (negative valence, high entropy)
    ERGODIC = 0  # Neutral/processing (balanced state)
    PLUS = 1  # Success/flow (positive valence, low entropy)

# ============================================================================
# Backward Morphism: RobotState → PhenomenalState
# ============================================================================

@dataclass
class PhenomenalStateFeedback:
    """Phenomenal state derived from robot execution"""
    phi: float  # Engagement angle [0, π/2]
    valence: float  # Affect [-1, +1]
    entropy: float  # Uncertainty [0, 8 bits]
    dominant_band: str  # "alpha" for post-motor activity
    dominant_power: float  # 0-1
    timestamp_us: int
    confidence: float  # 0-1
    gf3_trit: GF3Trit  # Classification in GF(3)

    def to_dict(self) -> Dict:
        return {
            'phi': self.phi,
            'valence': self.valence,
            'entropy': self.entropy,
            'dominant_band': self.dominant_band,
            'dominant_power': self.dominant_power,
            'timestamp_us': self.timestamp_us,
            'confidence': self.confidence,
            'gf3_trit': self.gf3_trit.name,
        }

class BackwardMorphism:
    """Transforms robot state → phenomenal state"""

    @staticmethod
    def joint_configuration_to_engagement(angles: List[float]) -> float:
        """
        Convert joint configuration (radians) → engagement angle φ ∈ [0, π/2]

        Intuition: spread configuration = high engagement, compact = low
        """
        total = sum(abs(a) for a in angles)
        # Map [0, 3π] → [0, π/2]
        normalized = total / (3 * math.pi)
        phi = min(math.pi / 2, normalized * 1.5708)  # π/2 ≈ 1.5708
        return phi

    @staticmethod
    def joint_velocities_to_valence(velocities: List[float]) -> float:
        """
        Convert joint velocity magnitudes → valence ∈ [-1, +1]

        Positive valence: smooth, coordinated motion
        Negative valence: jerky, high acceleration variance
        """
        speed_magnitudes = [abs(v) for v in velocities]
        mean_speed = sum(speed_magnitudes) / len(speed_magnitudes)

        # Compute variance
        variance = sum((s - mean_speed)**2 for s in speed_magnitudes) / len(speed_magnitudes)
        smoothness = 1.0 / (1.0 + math.sqrt(variance))  # 0-1: high smoothness = 1

        # Map [0,1] → [-1,+1]
        valence = smoothness * 2.0 - 1.0
        return max(-1.0, min(1.0, valence))

    @staticmethod
    def tool_pose_to_entropy(x: float, y: float, z: float,
                            roll: float, pitch: float, yaw: float) -> float:
        """
        Convert tool frame pose → entropy ∈ [0, 8 bits]

        Higher uncertainty → higher entropy
        """
        position_spread = math.sqrt(x**2 + y**2 + z**2)
        orientation_spread = abs(roll) + abs(pitch) + abs(yaw)

        # Entropy = log₂(position_spread + orientation_spread + 1)
        # Normalized to [0, 8]
        entropy_raw = (8.0 / math.log(256.0)) * math.log(position_spread + orientation_spread + 1.0)
        return max(0.0, min(8.0, entropy_raw))

    @staticmethod
    def apply(robot_state: RobotState, baseline: 'PhenomenalStateFeedback') -> PhenomenalStateFeedback:
        """
        Complete backward morphism: RobotState → PhenomenalState

        Transforms robot execution state to perceived phenomenal state.
        """
        # Compute phenomenal components
        phi = BackwardMorphism.joint_configuration_to_engagement(robot_state.joint_angles)
        valence = BackwardMorphism.joint_velocities_to_valence(robot_state.joint_velocities)
        entropy = BackwardMorphism.tool_pose_to_entropy(
            robot_state.tool_frame_x, robot_state.tool_frame_y, robot_state.tool_frame_z,
            robot_state.tool_frame_roll, robot_state.tool_frame_pitch, robot_state.tool_frame_yaw
        )

        # Adjust confidence for collisions
        confidence = baseline.confidence * 0.5 if robot_state.collision_detected else baseline.confidence

        # Task progress reduces entropy
        task_entropy_reduction = entropy * (1.0 - robot_state.task_progress)
        final_entropy = max(0.0, entropy - task_entropy_reduction)

        # GF(3) trit assignment
        success_score = (valence * 0.5) + ((1.0 - (final_entropy / 8.0)) * 0.5)
        engagement_factor = 1.2 if phi > 0.7 else 1.0

        if success_score * engagement_factor > 0.3:
            gf3_trit = GF3Trit.PLUS
        elif success_score * engagement_factor < -0.3:
            gf3_trit = GF3Trit.MINUS
        else:
            gf3_trit = GF3Trit.ERGODIC

        return PhenomenalStateFeedback(
            phi=phi,
            valence=valence,
            entropy=final_entropy,
            dominant_band="alpha",  # Post-motor activity
            dominant_power=0.5,
            timestamp_us=robot_state.timestamp_us,
            confidence=max(0.0, min(1.0, confidence)),
            gf3_trit=gf3_trit,
        )

# ============================================================================
# Color Projection: PhenomenalState → HSL → RGB
# ============================================================================

@dataclass
class HSLColor:
    hue: float  # degrees [0, 360]
    saturation: float  # [0, 1]
    lightness: float  # [0, 1]

@dataclass
class RGBColor:
    red: float  # [0, 1]
    green: float
    blue: float

    def to_hex(self) -> str:
        """Convert to hex color string"""
        r = int(max(0, min(255, self.red * 255)))
        g = int(max(0, min(255, self.green * 255)))
        b = int(max(0, min(255, self.blue * 255)))
        return f"#{r:02x}{g:02x}{b:02x}"

    def to_ansi256(self) -> int:
        """Convert to xterm-256 palette index"""
        # Simple cube-based approximation
        r_idx = int(self.red * 5)
        g_idx = int(self.green * 5)
        b_idx = int(self.blue * 5)
        # xterm-256 color cube starts at index 16
        return 16 + (36 * r_idx) + (6 * g_idx) + b_idx

class ColorProjection:
    """Projects phenomenal state to color space"""

    @staticmethod
    def phenomenal_to_hsl(state: PhenomenalStateFeedback) -> HSLColor:
        """
        Project phenomenal state to HSL color space.

        Hue: valence (-1 red, 0 yellow, +1 green)
        Saturation: entropy (high uncertainty = vibrant)
        Lightness: engagement φ (low φ = dark, high φ = bright)
        """
        # Valence → Hue: [-1,+1] → [0°, 120°] (red to green)
        hue = 60.0 + (state.valence * 60.0)  # ±60° from yellow (60°)
        if hue < 0.0:
            hue += 360.0

        # Entropy → Saturation: [0,8] → [0,1]
        saturation = state.entropy / 8.0

        # Engagement φ → Lightness: [0,π/2] → [0.3, 0.7]
        phi_normalized = state.phi / 1.5708  # π/2
        lightness = 0.3 + (phi_normalized * 0.4)

        return HSLColor(
            hue=hue,
            saturation=max(0.0, min(1.0, saturation)),
            lightness=max(0.3, min(0.7, lightness)),
        )

    @staticmethod
    def hsl_to_rgb(hsl: HSLColor) -> RGBColor:
        """Standard HSL → RGB conversion"""
        h = hsl.hue / 60.0
        s = hsl.saturation
        l = hsl.lightness

        c = s * (1.0 - abs(2.0 * l - 1.0))  # Chroma
        x = c * (1.0 - abs((h % 2.0) - 1.0))
        m = l - c / 2.0

        if h < 1.0:
            r_prime, g_prime, b_prime = c, x, 0.0
        elif h < 2.0:
            r_prime, g_prime, b_prime = x, c, 0.0
        elif h < 3.0:
            r_prime, g_prime, b_prime = 0.0, c, x
        elif h < 4.0:
            r_prime, g_prime, b_prime = 0.0, x, c
        elif h < 5.0:
            r_prime, g_prime, b_prime = x, 0.0, c
        else:
            r_prime, g_prime, b_prime = c, 0.0, x

        return RGBColor(
            red=r_prime + m,
            green=g_prime + m,
            blue=b_prime + m,
        )

    @staticmethod
    def phenomenal_to_rgb(state: PhenomenalStateFeedback) -> RGBColor:
        """Complete projection: PhenomenalState → RGB"""
        hsl = ColorProjection.phenomenal_to_hsl(state)
        return ColorProjection.hsl_to_rgb(hsl)

# ============================================================================
# Feedback Loop Coordinator
# ============================================================================

class Bridge9FeedbackController:
    """
    Integrates backward morphism + color feedback.

    Real-time control loop:
    1. Read robot state via Modbus TCP
    2. Apply backward morphism → phenomenal state
    3. Project to HSL/RGB colors
    4. Output feedback (terminal color, Emacs mode-line, DuckDB log)
    """

    def __init__(self, baseline_phenomenal: Optional[PhenomenalStateFeedback] = None):
        self.baseline = baseline_phenomenal or PhenomenalStateFeedback(
            phi=0.5,
            valence=0.0,
            entropy=2.0,
            dominant_band="alpha",
            dominant_power=0.5,
            timestamp_us=0,
            confidence=0.9,
            gf3_trit=GF3Trit.ERGODIC,
        )
        self.state_history: List[Dict] = []
        self.color_history: List[str] = []

    def process_robot_state(self, robot_state: RobotState) -> Dict:
        """
        Process single robot state through full feedback pipeline.

        Returns dict with phenomenal state, colors, and metadata.
        """
        # Apply backward morphism
        phenomenal = BackwardMorphism.apply(robot_state, self.baseline)

        # Project to colors
        rgb = ColorProjection.phenomenal_to_rgb(phenomenal)

        # Prepare output
        result = {
            'timestamp_us': robot_state.timestamp_us,
            'robot_state': robot_state.to_dict(),
            'phenomenal_state': phenomenal.to_dict(),
            'color': {
                'hex': rgb.to_hex(),
                'rgb': {'r': rgb.red, 'g': rgb.green, 'b': rgb.blue},
                'ansi256': rgb.to_ansi256(),
            },
            'gf3_classification': phenomenal.gf3_trit.name,
        }

        # Update history
        self.state_history.append(result)
        self.color_history.append(rgb.to_hex())

        return result

    def process_batch(self, robot_states: List[RobotState]) -> List[Dict]:
        """Process multiple robot states"""
        results = []
        for state in robot_states:
            result = self.process_robot_state(state)
            results.append(result)
            # Update baseline for next iteration
            self.baseline = PhenomenalStateFeedback(
                phi=result['phenomenal_state']['phi'],
                valence=result['phenomenal_state']['valence'],
                entropy=result['phenomenal_state']['entropy'],
                dominant_band=result['phenomenal_state']['dominant_band'],
                dominant_power=result['phenomenal_state']['dominant_power'],
                timestamp_us=result['phenomenal_state']['timestamp_us'],
                confidence=result['phenomenal_state']['confidence'],
                gf3_trit=GF3Trit[result['gf3_classification']],
            )
        return results

    def get_summary(self) -> Dict:
        """Generate summary statistics"""
        if not self.state_history:
            return {}

        triads = [h['gf3_classification'] for h in self.state_history]
        plus_count = triads.count('PLUS')
        minus_count = triads.count('MINUS')
        ergodic_count = triads.count('ERGODIC')

        return {
            'total_states': len(self.state_history),
            'gf3_distribution': {
                'PLUS': plus_count,
                'ERGODIC': ergodic_count,
                'MINUS': minus_count,
            },
            'color_trace': self.color_history[-10:],  # Last 10 colors
            'latest_color': self.color_history[-1] if self.color_history else '#FFFFFF',
        }

# ============================================================================
# Demo / CLI
# ============================================================================

def demo_feedback_loop():
    """Demonstrate Phase 4 feedback in action"""
    import time

    print("Bridge 9 Phase 4: Feedback Display Demo")
    print("=" * 50)

    controller = Bridge9FeedbackController()

    # Simulate robot executing task (from relaxed to engaged)
    for i in range(5):
        # Simulate increasing engagement
        progress = i / 4.0
        robot_state = RobotState(
            timestamp_us=int(time.time() * 1e6) + i * 100000,
            joint_angles=[0.1 + progress * 1.0] * 6,  # Spread configuration
            joint_velocities=[0.05 - progress * 0.01] * 6,  # Smooth, coordinated
            joint_accelerations=[0.0] * 6,
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

        result = controller.process_robot_state(robot_state)
        phenomenal = result['phenomenal_state']
        color = result['color']['hex']

        print(f"\nStep {i+1}:")
        print(f"  φ (engagement): {phenomenal['phi']:.3f}")
        print(f"  Valence:        {phenomenal['valence']:.3f}")
        print(f"  Entropy:        {phenomenal['entropy']:.3f}")
        print(f"  Color:          {color} (GF(3):{result['gf3_classification']})")
        print(f"  Task progress:  {robot_state.task_progress:.1%}")

    print("\n" + "=" * 50)
    summary = controller.get_summary()
    print("Summary:")
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    demo_feedback_loop()

