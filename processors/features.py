"""
EEG Feature Extraction
Phase 3: Feature extraction (band powers, Hjorth parameters)
"""

import logging
from typing import Dict, List, Optional, Tuple

import numpy as np
from scipy import signal, stats

logger = logging.getLogger('BCI-Features')


class FeatureExtractor:
    """
    Real-time EEG feature extraction.
    
    Implements Phase 3 of the processing pipeline:
    - Band power extraction (delta, theta, alpha, beta, gamma)
    - Hjorth parameters (activity, mobility, complexity)
    - Statistical features (variance, skewness, kurtosis)
    - Spectral features (spectral entropy, edge frequency)
    """
    
    def __init__(
        self,
        bands: Optional[Dict[str, Tuple[float, float]]] = None,
        fs: float = 250.0,
        n_channels: int = 8
    ):
        """
        Initialize feature extractor.
        
        Args:
            bands: Dictionary of frequency bands (name: (low, high))
            fs: Sampling frequency (Hz)
            n_channels: Number of EEG channels
        """
        self.fs = fs
        self.n_channels = n_channels
        
        # Default bands if not specified
        self.bands = bands or {
            'delta': (0.5, 4),
            'theta': (4, 8),
            'alpha': (8, 13),
            'beta': (13, 30),
            'gamma': (30, 50)
        }
        
        # Precompute band indices for FFT-based power extraction
        self._band_indices = {}
        
        logger.info(f"FeatureExtractor: {list(self.bands.keys())}, fs={fs} Hz")
    
    def extract(self, data: np.ndarray) -> Dict:
        """
        Extract all features from data window.
        
        Args:
            data: Input array of shape (n_samples, n_channels)
        
        Returns:
            Dictionary containing all extracted features
        """
        features = {
            'timestamp': None,  # Will be set by caller
            'band_powers': self.band_powers(data),
            'hjorth': self.hjorth_parameters(data),
            'statistics': self.statistical_features(data),
            'spectral': self.spectral_features(data),
            'ratios': self.band_ratios(data)
        }
        
        return features
    
    def band_powers(self, data: np.ndarray, method: str = 'welch') -> Dict[str, np.ndarray]:
        """
        Calculate power in each frequency band.
        
        Args:
            data: Input array (n_samples, n_channels)
            method: 'welch' or 'fft'
        
        Returns:
            Dictionary of band names to power arrays (n_channels,)
        """
        powers = {}
        
        if method == 'welch':
            # Welch's method for PSD estimation
            freqs, psd = signal.welch(
                data, 
                fs=self.fs, 
                nperseg=min(256, len(data)),
                axis=0
            )
            
            for band_name, (low, high) in self.bands.items():
                idx = np.logical_and(freqs >= low, freqs <= high)
                # Integrate PSD over band
                powers[band_name] = np.trapezoid(psd[idx], freqs[idx], axis=0)
        
        elif method == 'fft':
            # Simple FFT-based power
            n_samples = len(data)
            fft = np.fft.rfft(data, axis=0)
            freqs = np.fft.rfftfreq(n_samples, 1 / self.fs)
            power = np.abs(fft) ** 2
            
            for band_name, (low, high) in self.bands.items():
                idx = np.logical_and(freqs >= low, freqs <= high)
                powers[band_name] = np.mean(power[idx], axis=0)
        
        # Convert to microvolts squared
        for key in powers:
            powers[key] = powers[key] * 1e12  # Convert from V^2 to uV^2
        
        return powers
    
    def hjorth_parameters(self, data: np.ndarray) -> Dict[str, np.ndarray]:
        """
        Calculate Hjorth parameters.
        
        Hjorth parameters are time-domain descriptors:
        - Activity: variance of the signal
        - Mobility: sqrt(variance of first derivative / variance of signal)
        - Complexity: ratio of mobility of first derivative to mobility of signal
        
        Args:
            data: Input array (n_samples, n_channels)
        
        Returns:
            Dictionary with 'activity', 'mobility', 'complexity' arrays
        """
        # First derivative
        diff1 = np.diff(data, axis=0)
        diff2 = np.diff(diff1, axis=0)
        
        # Variance
        var0 = np.var(data, axis=0)
        var1 = np.var(diff1, axis=0)
        var2 = np.var(diff2, axis=0)
        
        # Avoid division by zero
        var0 = np.where(var0 == 0, 1e-10, var0)
        var1 = np.where(var1 == 0, 1e-10, var1)
        
        # Hjorth parameters
        activity = var0
        mobility = np.sqrt(var1 / var0)
        complexity = np.sqrt(var2 / var1) / mobility
        
        return {
            'activity': activity,
            'mobility': mobility,
            'complexity': complexity
        }
    
    def statistical_features(self, data: np.ndarray) -> Dict[str, np.ndarray]:
        """
        Calculate statistical features.
        
        Args:
            data: Input array (n_samples, n_channels)
        
        Returns:
            Dictionary of statistical features
        """
        return {
            'mean': np.mean(data, axis=0),
            'variance': np.var(data, axis=0),
            'std': np.std(data, axis=0),
            'skewness': stats.skew(data, axis=0),
            'kurtosis': stats.kurtosis(data, axis=0),
            'range': np.ptp(data, axis=0),
            'rms': np.sqrt(np.mean(data ** 2, axis=0))
        }
    
    def spectral_features(self, data: np.ndarray) -> Dict[str, np.ndarray]:
        """
        Calculate spectral features.
        
        Args:
            data: Input array (n_samples, n_channels)
        
        Returns:
            Dictionary of spectral features
        """
        # Compute PSD
        freqs, psd = signal.welch(
            data,
            fs=self.fs,
            nperseg=min(256, len(data)),
            axis=0
        )
        
        # Normalize PSD
        psd_norm = psd / (np.sum(psd, axis=0, keepdims=True) + 1e-10)
        
        # Spectral entropy
        spectral_entropy = -np.sum(psd_norm * np.log2(psd_norm + 1e-10), axis=0)
        
        # Spectral edge frequency (95% of power)
        cumsum = np.cumsum(psd, axis=0)
        total_power = cumsum[-1]
        edge_95 = np.zeros(self.n_channels)
        
        for ch in range(self.n_channels):
            if total_power[ch] > 0:
                idx = np.where(cumsum[:, ch] >= 0.95 * total_power[ch])[0]
                if len(idx) > 0:
                    edge_95[ch] = freqs[idx[0]]
        
        # Spectral centroid
        centroid = np.sum(freqs[:, np.newaxis] * psd, axis=0) / (np.sum(psd, axis=0) + 1e-10)
        
        # Spectral flatness (Wiener entropy)
        geometric_mean = np.exp(np.mean(np.log(psd + 1e-10), axis=0))
        arithmetic_mean = np.mean(psd, axis=0)
        flatness = geometric_mean / (arithmetic_mean + 1e-10)
        
        return {
            'spectral_entropy': spectral_entropy,
            'spectral_edge_95': edge_95,
            'spectral_centroid': centroid,
            'spectral_flatness': flatness
        }
    
    def band_ratios(self, data: np.ndarray) -> Dict[str, np.ndarray]:
        """
        Calculate common band power ratios.
        
        Args:
            data: Input array (n_samples, n_channels)
        
        Returns:
            Dictionary of band ratios
        """
        powers = self.band_powers(data)
        
        ratios = {}
        
        # Alpha/Theta ratio (relaxation vs focus)
        if 'alpha' in powers and 'theta' in powers:
            ratios['alpha_theta'] = powers['alpha'] / (powers['theta'] + 1e-10)
        
        # Beta/Alpha ratio (active vs relaxed)
        if 'beta' in powers and 'alpha' in powers:
            ratios['beta_alpha'] = powers['beta'] / (powers['alpha'] + 1e-10)
        
        # Theta/Beta ratio (focus indicator, ADHD research)
        if 'theta' in powers and 'beta' in powers:
            ratios['theta_beta'] = powers['theta'] / (powers['beta'] + 1e-10)
        
        # Total power
        total = sum(powers.values())
        
        # Relative band powers
        for band_name in powers:
            ratios[f'{band_name}_relative'] = powers[band_name] / (total + 1e-10)
        
        return ratios
    
    def extract_channel_features(self, data: np.ndarray, channel: int) -> Dict:
        """Extract features for a single channel."""
        ch_data = data[:, channel:channel + 1]
        return self.extract(ch_data)


class ConnectivityFeatures:
    """
    Extract connectivity features between channels.
    
    Useful for network analysis of brain activity.
    """
    
    def __init__(self, fs: float = 250.0):
        self.fs = fs
        logger.info(f"ConnectivityFeatures: fs={fs} Hz")
    
    def coherence(self, data: np.ndarray) -> np.ndarray:
        """
        Calculate coherence matrix between all channel pairs.
        
        Args:
            data: Input array (n_samples, n_channels)
        
        Returns:
            Coherence matrix (n_channels, n_channels)
        """
        n_channels = data.shape[1]
        coh_matrix = np.zeros((n_channels, n_channels))
        
        for i in range(n_channels):
            for j in range(i, n_channels):
                f, Cxy = signal.coherence(data[:, i], data[:, j], fs=self.fs)
                # Average coherence across frequencies
                avg_coh = np.mean(Cxy)
                coh_matrix[i, j] = avg_coh
                coh_matrix[j, i] = avg_coh
        
        return coh_matrix
    
    def correlation(self, data: np.ndarray) -> np.ndarray:
        """Calculate correlation matrix between channels."""
        return np.corrcoef(data.T)
    
    def phase_lag_index(self, data: np.ndarray) -> np.ndarray:
        """
        Calculate Phase Lag Index (PLI) between channels.
        
        PLI is less sensitive to volume conduction than coherence.
        """
        n_channels = data.shape[1]
        pli_matrix = np.zeros((n_channels, n_channels))
        
        # Hilbert transform to get instantaneous phase
        analytic = signal.hilbert(data, axis=0)
        phases = np.angle(analytic)
        
        for i in range(n_channels):
            for j in range(i + 1, n_channels):
                # Phase difference
                phase_diff = phases[:, i] - phases[:, j]
                # PLI is the absolute value of the sign of phase difference
                pli = np.abs(np.mean(np.sign(np.sin(phase_diff))))
                pli_matrix[i, j] = pli
                pli_matrix[j, i] = pli
        
        return pli_matrix
    
    def extract_all(self, data: np.ndarray) -> Dict:
        """Extract all connectivity features."""
        return {
            'coherence': self.coherence(data),
            'correlation': self.correlation(data),
            'phase_lag_index': self.phase_lag_index(data)
        }


class AsymmetryFeatures:
    """
    Calculate hemispheric asymmetry metrics.
    
    Useful for assessing emotional states and cognitive load.
    """
    
    def __init__(self, left_channels: List[int], right_channels: List[int]):
        """
        Initialize asymmetry calculator.
        
        Args:
            left_channels: Indices of left hemisphere channels
            right_channels: Indices of right hemisphere channels
        """
        self.left_channels = left_channels
        self.right_channels = right_channels
        
        logger.info(f"Asymmetry: left={left_channels}, right={right_channels}")
    
    def alpha_asymmetry(self, band_powers: Dict[str, np.ndarray]) -> float:
        """
        Calculate frontal alpha asymmetry.
        
        Positive values indicate greater left activity (approach/positive emotion).
        Negative values indicate greater right activity (withdrawal/negative emotion).
        """
        left_alpha = np.mean(band_powers['alpha'][self.left_channels])
        right_alpha = np.mean(band_powers['alpha'][self.right_channels])
        
        # Log ratio: ln(right) - ln(left)
        asymmetry = np.log(right_alpha + 1e-10) - np.log(left_alpha + 1e-10)
        
        return asymmetry
    
    def calculate_all(self, band_powers: Dict[str, np.ndarray]) -> Dict[str, float]:
        """Calculate all asymmetry metrics."""
        return {
            'alpha_asymmetry': self.alpha_asymmetry(band_powers),
            'beta_asymmetry': self._band_asymmetry(band_powers, 'beta'),
            'theta_asymmetry': self._band_asymmetry(band_powers, 'theta')
        }
    
    def _band_asymmetry(self, band_powers: Dict, band: str) -> float:
        """Calculate asymmetry for a specific band."""
        left = np.mean(band_powers[band][self.left_channels])
        right = np.mean(band_powers[band][self.right_channels])
        return np.log(right + 1e-10) - np.log(left + 1e-10)
