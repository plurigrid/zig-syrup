"""
EEG Classification / State Detection
Phase 4: Classification/state detection
"""

import logging
import pickle
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Union

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.naive_bayes import GaussianNB
from sklearn.preprocessing import StandardScaler

logger = logging.getLogger('BCI-Classifier')


class BrainState(Enum):
    """Enumeration of detectable brain states."""
    UNKNOWN = "unknown"
    RELAXED = "relaxed"          # High alpha, low beta
    FOCUSED = "focused"          # Low theta/beta ratio, increased beta
    DROWSY = "drowsy"            # Increased theta, decreased alpha
    EXCITED = "excited"          # Increased beta/gamma
    STRESSED = "stressed"        # High beta, low alpha
    MEDITATIVE = "meditative"    # High theta/alpha coherence


class EEGClassifier:
    """
    Real-time EEG state classifier.
    
    Implements Phase 4 of the processing pipeline:
    - Threshold-based classification (rule-based)
    - Machine learning classification (optional)
    - State transition smoothing
    - Confidence scoring
    """
    
    def __init__(
        self,
        method: str = 'threshold',
        model_path: Optional[str] = None,
        smoothing_window: int = 5
    ):
        """
        Initialize classifier.
        
        Args:
            method: 'threshold', 'ml', or 'hybrid'
            model_path: Path to pre-trained ML model
            smoothing_window: Number of classifications to average
        """
        self.method = method
        self.smoothing_window = smoothing_window
        
        # State history for smoothing
        self.state_history: List[BrainState] = []
        self.confidence_history: List[float] = []
        
        # ML components
        self.model = None
        self.scaler = StandardScaler()
        self._ml_trained = False
        
        # Load pre-trained model if provided
        if model_path and Path(model_path).exists():
            self.load_model(model_path)
        
        # Threshold parameters (can be calibrated)
        self.thresholds = {
            'alpha_theta_ratio_relaxed': 1.5,
            'theta_beta_ratio_focused': 1.2,
            'beta_alpha_ratio_stressed': 1.5,
            'alpha_power_relaxed': 100,  # uV^2
            'beta_power_focused': 50     # uV^2
        }
        
        logger.info(f"EEGClassifier: method={method}")
    
    def classify(self, features: Dict) -> Dict:
        """
        Classify brain state from features.
        
        Args:
            features: Feature dictionary from FeatureExtractor
        
        Returns:
            Classification result with state, confidence, and details
        """
        if self.method == 'threshold':
            result = self._threshold_classify(features)
        elif self.method == 'ml' and self._ml_trained:
            result = self._ml_classify(features)
        else:
            result = self._hybrid_classify(features)
        
        # Apply temporal smoothing
        result = self._smooth_classification(result)
        
        return result
    
    def _threshold_classify(self, features: Dict) -> Dict:
        """
        Rule-based classification using feature thresholds.
        """
        bands = features.get('band_powers', {})
        ratios = features.get('ratios', {})
        hjorth = features.get('hjorth', {})
        
        # Extract relevant metrics
        alpha_power = np.mean(bands.get('alpha', [0]))
        beta_power = np.mean(bands.get('beta', [0]))
        theta_power = np.mean(bands.get('theta', [0]))
        
        alpha_theta = ratios.get('alpha_theta', [0])
        theta_beta = ratios.get('theta_beta', [0])
        beta_alpha = ratios.get('beta_alpha', [0])
        
        # Calculate mean ratios across channels
        alpha_theta_mean = np.mean(alpha_theta) if isinstance(alpha_theta, np.ndarray) else alpha_theta
        theta_beta_mean = np.mean(theta_beta) if isinstance(theta_beta, np.ndarray) else theta_beta
        beta_alpha_mean = np.mean(beta_alpha) if isinstance(beta_alpha, np.ndarray) else beta_alpha
        
        # Classification rules
        scores = {}
        
        # Relaxed: High alpha, high alpha/theta ratio
        scores[BrainState.RELAXED] = (
            (alpha_power > self.thresholds['alpha_power_relaxed']) * 0.5 +
            (alpha_theta_mean > self.thresholds['alpha_theta_ratio_relaxed']) * 0.5
        )
        
        # Focused: Low theta/beta ratio, increased beta
        scores[BrainState.FOCUSED] = (
            (theta_beta_mean < self.thresholds['theta_beta_ratio_focused']) * 0.5 +
            (beta_power > self.thresholds['beta_power_focused']) * 0.5
        )
        
        # Stressed: High beta/alpha ratio
        scores[BrainState.STRESSED] = (
            1.0 if beta_alpha_mean > self.thresholds['beta_alpha_ratio_stressed'] else 0.0
        )
        
        # Drowsy: High theta, low alpha
        scores[BrainState.DROWSY] = (
            (theta_power > alpha_power) * 0.5 +
            (alpha_power < self.thresholds['alpha_power_relaxed'] * 0.5) * 0.5
        )
        
        # Excited: High beta and gamma
        gamma_power = np.mean(bands.get('gamma', [0]))
        scores[BrainState.EXCITED] = (
            (beta_power > self.thresholds['beta_power_focused'] * 1.5) * 0.5 +
            (gamma_power > beta_power * 0.5) * 0.5
        )
        
        # Meditative: High theta and alpha coherence
        activity = np.mean(hjorth.get('activity', [0]))
        scores[BrainState.MEDITATIVE] = (
            (theta_power > 50 and alpha_power > 80 and activity < 500) * 1.0
        )
        
        # Find state with highest score
        best_state = max(scores, key=scores.get)
        best_score = scores[best_state]
        
        # Confidence based on score separation
        sorted_scores = sorted(scores.values(), reverse=True)
        confidence = min(1.0, best_score + (sorted_scores[0] - sorted_scores[1]))
        
        # If no clear winner, mark as unknown
        if best_score < 0.3:
            best_state = BrainState.UNKNOWN
            confidence = 1.0 - best_score
        
        return {
            'state': best_state.value,
            'confidence': float(confidence),
            'scores': {k.value: float(v) for k, v in scores.items()},
            'method': 'threshold'
        }
    
    def _ml_classify(self, features: Dict) -> Dict:
        """
        Machine learning classification.
        """
        if not self._ml_trained:
            return {'state': BrainState.UNKNOWN.value, 'confidence': 0.0, 'method': 'ml'}
        
        # Flatten features into vector
        feature_vector = self._flatten_features(features)
        
        # Scale features
        feature_vector = self.scaler.transform([feature_vector])
        
        # Predict
        if hasattr(self.model, 'predict_proba'):
            probs = self.model.predict_proba(feature_vector)[0]
            prediction = self.model.classes_[np.argmax(probs)]
            confidence = float(np.max(probs))
        else:
            prediction = self.model.predict(feature_vector)[0]
            confidence = 0.5  # Default confidence for models without probabilities
        
        return {
            'state': str(prediction),
            'confidence': confidence,
            'method': 'ml'
        }
    
    def _hybrid_classify(self, features: Dict) -> Dict:
        """
        Hybrid classification combining threshold and ML methods.
        """
        threshold_result = self._threshold_classify(features)
        
        if self._ml_trained:
            ml_result = self._ml_classify(features)
            
            # Weight by confidence
            if ml_result['confidence'] > 0.7:
                return ml_result
            elif threshold_result['confidence'] > 0.7:
                return threshold_result
            else:
                # Both uncertain, default to threshold
                return threshold_result
        
        return threshold_result
    
    def _smooth_classification(self, result: Dict) -> Dict:
        """
        Apply temporal smoothing to classification results.
        """
        state = BrainState(result['state'])
        confidence = result['confidence']
        
        # Add to history
        self.state_history.append(state)
        self.confidence_history.append(confidence)
        
        # Keep only recent history
        if len(self.state_history) > self.smoothing_window:
            self.state_history.pop(0)
            self.confidence_history.pop(0)
        
        # Majority vote for state
        state_counts = {}
        for s in self.state_history:
            state_counts[s] = state_counts.get(s, 0) + 1
        
        smoothed_state = max(state_counts, key=state_counts.get)
        state_stability = state_counts[smoothed_state] / len(self.state_history)
        
        # Average confidence
        avg_confidence = np.mean(self.confidence_history)
        
        # Adjust confidence by state stability
        final_confidence = avg_confidence * (0.5 + 0.5 * state_stability)
        
        result['state'] = smoothed_state.value
        result['confidence'] = float(final_confidence)
        result['state_stability'] = float(state_stability)
        result['history_length'] = len(self.state_history)
        
        return result
    
    def _flatten_features(self, features: Dict) -> np.ndarray:
        """Flatten feature dictionary into vector."""
        vectors = []
        
        # Band powers
        for band in ['delta', 'theta', 'alpha', 'beta', 'gamma']:
            if 'band_powers' in features and band in features['band_powers']:
                vectors.append(np.mean(features['band_powers'][band]))
            else:
                vectors.append(0)
        
        # Ratios
        for ratio in ['alpha_theta', 'beta_alpha', 'theta_beta']:
            if 'ratios' in features and ratio in features['ratios']:
                vectors.append(np.mean(features['ratios'][ratio]))
            else:
                vectors.append(0)
        
        # Hjorth
        for param in ['activity', 'mobility', 'complexity']:
            if 'hjorth' in features and param in features['hjorth']:
                vectors.append(np.mean(features['hjorth'][param]))
            else:
                vectors.append(0)
        
        return np.array(vectors)
    
    def train(self, X: np.ndarray, y: np.ndarray):
        """
        Train the ML classifier.
        
        Args:
            X: Feature matrix (n_samples, n_features)
            y: Labels (n_samples,)
        """
        # Scale features
        X_scaled = self.scaler.fit_transform(X)
        
        # Train model
        if self.method == 'ml':
            self.model = RandomForestClassifier(n_estimators=100, random_state=42)
        else:
            # Simple baseline
            self.model = GaussianNB()
        
        self.model.fit(X_scaled, y)
        self._ml_trained = True
        
        logger.info(f"Classifier trained on {len(X)} samples")
    
    def save_model(self, path: str):
        """Save trained model to disk."""
        if not self._ml_trained:
            raise RuntimeError("No trained model to save")
        
        data = {
            'model': self.model,
            'scaler': self.scaler,
            'method': self.method,
            'thresholds': self.thresholds
        }
        
        with open(path, 'wb') as f:
            pickle.dump(data, f)
        
        logger.info(f"Model saved to {path}")
    
    def load_model(self, path: str):
        """Load trained model from disk."""
        with open(path, 'rb') as f:
            data = pickle.load(f)
        
        self.model = data['model']
        self.scaler = data['scaler']
        self.method = data.get('method', 'ml')
        self.thresholds.update(data.get('thresholds', {}))
        self._ml_trained = True
        
        logger.info(f"Model loaded from {path}")
    
    def calibrate_thresholds(self, baseline_features: List[Dict], target_state: BrainState):
        """
        Calibrate thresholds based on baseline recordings.
        
        Args:
            baseline_features: List of feature dictionaries from baseline
            target_state: Expected state during baseline
        """
        # Calculate mean values for target state
        band_powers = {'delta': [], 'theta': [], 'alpha': [], 'beta': [], 'gamma': []}
        ratios = {'alpha_theta': [], 'beta_alpha': [], 'theta_beta': []}
        
        for features in baseline_features:
            for band in band_powers:
                if 'band_powers' in features and band in features['band_powers']:
                    band_powers[band].append(np.mean(features['band_powers'][band]))
            
            for ratio in ratios:
                if 'ratios' in features and ratio in features['ratios']:
                    ratios[ratio].append(np.mean(features['ratios'][ratio]))
        
        # Update thresholds based on target state
        if target_state == BrainState.RELAXED:
            self.thresholds['alpha_power_relaxed'] = np.mean(band_powers['alpha']) * 0.8
            self.thresholds['alpha_theta_ratio_relaxed'] = np.mean(ratios['alpha_theta']) * 0.8
        elif target_state == BrainState.FOCUSED:
            self.thresholds['beta_power_focused'] = np.mean(band_powers['beta']) * 0.8
            self.thresholds['theta_beta_ratio_focused'] = np.mean(ratios['theta_beta']) * 1.2
        
        logger.info(f"Calibrated thresholds for {target_state.value}")


class BlinkDetector:
    """
    Detect eye blinks in EEG data.
    
    Useful for artifact removal and user interaction.
    """
    
    def __init__(
        self,
        threshold: float = 100.0,  # uV
        min_duration_ms: float = 100,
        fs: float = 250.0
    ):
        self.threshold = threshold
        self.min_samples = int(min_duration_ms * fs / 1000)
        self.fs = fs
        
        self._in_blink = False
        self._blink_start = 0
        self._blink_count = 0
    
    def detect(self, sample: Union[np.ndarray, float], timestamp: float) -> Optional[Dict]:
        """
        Detect blink in sample.
        
        Args:
            sample: EEG sample (typically from frontal channel like FP1/FP2)
            timestamp: Sample timestamp
        
        Returns:
            Blink info if blink detected, None otherwise
        """
        # Use first channel if array
        if isinstance(sample, np.ndarray):
            value = abs(sample[0]) if len(sample) > 0 else 0
        else:
            value = abs(sample)
        
        blink_info = None
        
        if value > self.threshold:
            if not self._in_blink:
                self._in_blink = True
                self._blink_start = timestamp
        else:
            if self._in_blink:
                duration = timestamp - self._blink_start
                if duration >= self.min_samples / self.fs:
                    self._blink_count += 1
                    blink_info = {
                        'type': 'blink',
                        'start_time': self._blink_start,
                        'duration': duration,
                        'count': self._blink_count
                    }
                self._in_blink = False
        
        return blink_info
    
    def reset(self):
        """Reset blink detector state."""
        self._in_blink = False
        self._blink_start = 0
        self._blink_count = 0


class ArtifactDetector:
    """
    Detect various artifacts in EEG data.
    """
    
    def __init__(
        self,
        amplitude_threshold: float = 200.0,  # uV
        variance_threshold: float = 1000.0,
        gradient_threshold: float = 100.0    # uV/sample
    ):
        self.amplitude_threshold = amplitude_threshold
        self.variance_threshold = variance_threshold
        self.gradient_threshold = gradient_threshold
        
        self._last_sample = None
    
    def detect(self, data: np.ndarray) -> Dict:
        """
        Detect artifacts in data window.
        
        Returns:
            Dictionary with artifact flags and metrics
        """
        artifacts = {
            'amplitude_violation': False,
            'variance_violation': False,
            'gradient_violation': False,
            'saturated_channels': [],
            'quality_score': 1.0
        }
        
        # Check amplitude
        max_amp = np.max(np.abs(data), axis=0)
        artifacts['amplitude_violation'] = np.any(max_amp > self.amplitude_threshold)
        artifacts['saturated_channels'] = np.where(max_amp > self.amplitude_threshold)[0].tolist()
        
        # Check variance
        variance = np.var(data, axis=0)
        artifacts['variance_violation'] = np.any(variance > self.variance_threshold)
        
        # Check gradient (jumps between samples)
        if len(data) > 1:
            gradient = np.max(np.abs(np.diff(data, axis=0)), axis=0)
            artifacts['gradient_violation'] = np.any(gradient > self.gradient_threshold)
        
        # Calculate quality score
        violations = sum([
            artifacts['amplitude_violation'],
            artifacts['variance_violation'],
            artifacts['gradient_violation']
        ])
        artifacts['quality_score'] = max(0.0, 1.0 - violations * 0.33)
        
        artifacts['is_clean'] = violations == 0
        
        return artifacts
