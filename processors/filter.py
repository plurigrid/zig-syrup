"""
Real-time Filtering for EEG Data
Phase 2: Filtering (bandpass 1-50Hz, notch 60Hz)
"""

import logging
from typing import Optional, Tuple

import numpy as np
from scipy import signal

logger = logging.getLogger('BCI-Filter')


class RealtimeFilter:
    """
    Real-time filter for EEG data processing.
    
    Implements Phase 2 of the processing pipeline:
    - Bandpass filtering (1-50 Hz typical for EEG)
    - Notch filtering (60 Hz for mains interference)
    - Zero-phase filtering using filtfilt
    
    Uses second-order sections (SOS) for numerical stability.
    """
    
    def __init__(
        self,
        lowcut: float = 1.0,
        highcut: float = 50.0,
        notch_freq: float = 60.0,
        fs: float = 250.0,
        order: int = 4,
        notch_q: float = 30.0
    ):
        """
        Initialize real-time filter.
        
        Args:
            lowcut: Low cutoff frequency for bandpass (Hz)
            highcut: High cutoff frequency for bandpass (Hz)
            notch_freq: Notch filter frequency (Hz), 0 to disable
            fs: Sampling frequency (Hz)
            order: Filter order
            notch_q: Quality factor for notch filter
        """
        self.lowcut = lowcut
        self.highcut = highcut
        self.notch_freq = notch_freq
        self.fs = fs
        self.order = order
        self.notch_q = notch_q
        
        # Nyquist frequency
        self.nyq = 0.5 * fs
        
        # Design filters
        self.bandpass_sos = self._design_bandpass()
        self.notch_b, self.notch_a = self._design_notch() if notch_freq > 0 else (None, None)
        
        # State for real-time processing (using lfilter_zi for continuity)
        self.bandpass_zi = None
        self.notch_zi = None
        
        logger.info(f"Filter initialized: {lowcut}-{highcut} Hz, notch @ {notch_freq} Hz")
    
    def _design_bandpass(self) -> np.ndarray:
        """Design Butterworth bandpass filter in SOS format."""
        low = self.lowcut / self.nyq
        high = self.highcut / self.nyq
        
        sos = signal.butter(
            self.order,
            [low, high],
            btype='band',
            output='sos'
        )
        return sos
    
    def _design_notch(self) -> Tuple[np.ndarray, np.ndarray]:
        """Design notch filter for mains interference removal."""
        b, a = signal.iirnotch(self.notch_freq, self.notch_q, self.fs)
        return b, a
    
    def reset_state(self, n_channels: int = 8):
        """Reset filter state for real-time processing."""
        # Initialize state for bandpass SOS filter
        self.bandpass_zi = signal.sosfilt_zi(self.bandpass_sos)
        self.bandpass_zi = np.tile(self.bandpass_zi, (n_channels, 1, 1)).transpose(1, 2, 0)
        
        # Initialize state for notch filter
        if self.notch_b is not None:
            self.notch_zi = signal.lfilter_zi(self.notch_b, self.notch_a)
            self.notch_zi = np.tile(self.notch_zi, (n_channels, 1)).T
    
    def process_offline(self, data: np.ndarray) -> np.ndarray:
        """
        Apply filtering to complete data array (offline mode).
        
        Uses filtfilt for zero-phase filtering.
        
        Args:
            data: Input array of shape (n_samples, n_channels)
        
        Returns:
            Filtered array of same shape
        """
        # Bandpass filter
        filtered = signal.sosfiltfilt(self.bandpass_sos, data, axis=0)
        
        # Notch filter
        if self.notch_b is not None:
            filtered = signal.filtfilt(self.notch_b, self.notch_a, filtered, axis=0)
        
        return filtered
    
    def process(self, data: np.ndarray) -> np.ndarray:
        """
        Apply filtering to data window (real-time mode).
        
        Args:
            data: Input array of shape (n_samples, n_channels)
        
        Returns:
            Filtered array of same shape
        """
        # Initialize state if needed
        if self.bandpass_zi is None or self.bandpass_zi.shape[-1] != data.shape[1]:
            self.reset_state(data.shape[1])
        
        # Bandpass filter (causal, for real-time)
        filtered, self.bandpass_zi = signal.sosfilt(
            self.bandpass_sos, 
            data, 
            axis=0,
            zi=self.bandpass_zi
        )
        
        # Notch filter
        if self.notch_b is not None:
            filtered, self.notch_zi = signal.lfilter(
                self.notch_b,
                self.notch_a,
                filtered,
                axis=0,
                zi=self.notch_zi
            )
        
        return filtered
    
    def process_sample(self, sample: np.ndarray) -> np.ndarray:
        """
        Process a single sample (for true real-time).
        
        Args:
            sample: Single sample of shape (n_channels,)
        
        Returns:
            Filtered sample
        """
        sample_2d = sample.reshape(1, -1)
        result = self.process(sample_2d)
        return result[0]


class MultiBandFilter:
    """
    Filter bank for extracting multiple frequency bands simultaneously.
    
    Useful for band power analysis and real-time spectral decomposition.
    """
    
    def __init__(
        self,
        bands: dict,
        fs: float = 250.0,
        order: int = 4
    ):
        """
        Initialize multi-band filter bank.
        
        Args:
            bands: Dictionary of band names to (low, high) tuples
            fs: Sampling frequency
            order: Filter order
        """
        self.bands = bands
        self.fs = fs
        self.order = order
        self.nyq = 0.5 * fs
        
        # Design filters for each band
        self.filters = {}
        for name, (low, high) in bands.items():
            sos = signal.butter(
                order,
                [low / self.nyq, high / self.nyq],
                btype='band',
                output='sos'
            )
            self.filters[name] = sos
        
        logger.info(f"MultiBandFilter: {list(bands.keys())}")
    
    def filter_all(self, data: np.ndarray) -> dict:
        """
        Filter data through all bands.
        
        Args:
            data: Input array of shape (n_samples, n_channels)
        
        Returns:
            Dictionary of band names to filtered arrays
        """
        results = {}
        for name, sos in self.filters.items():
            results[name] = signal.sosfiltfilt(sos, data, axis=0)
        return results
    
    def get_band(self, data: np.ndarray, band_name: str) -> np.ndarray:
        """Get data filtered to specific band."""
        if band_name not in self.filters:
            raise ValueError(f"Unknown band: {band_name}")
        return signal.sosfiltfilt(self.filters[band_name], data, axis=0)


class AdaptiveNotchFilter:
    """
    Adaptive notch filter that can track and remove interference
    at varying frequencies (e.g., drifting mains frequency).
    """
    
    def __init__(
        self,
        base_freq: float = 60.0,
        freq_range: float = 2.0,
        fs: float = 250.0,
        q: float = 30.0
    ):
        """
        Initialize adaptive notch filter.
        
        Args:
            base_freq: Base notch frequency
            freq_range: Range around base frequency to search
            fs: Sampling frequency
            q: Quality factor
        """
        self.base_freq = base_freq
        self.freq_range = freq_range
        self.fs = fs
        self.q = q
        self.current_freq = base_freq
        
        # FFT parameters
        self.fft_size = 1024
        self.search_bins = int(freq_range * self.fft_size / fs)
        
        # Buffer for frequency analysis
        self._buffer = np.zeros(self.fft_size)
        self._buffer_idx = 0
        
        logger.info(f"AdaptiveNotchFilter: base={base_freq} Hz, range=±{freq_range} Hz")
    
    def _find_peak(self, data: np.ndarray) -> float:
        """Find the dominant frequency around base_freq."""
        # Update buffer
        n = min(len(data), self.fft_size - self._buffer_idx)
        self._buffer[self._buffer_idx:self._buffer_idx + n] = data[-n:, 0]  # Use first channel
        self._buffer_idx = (self._buffer_idx + n) % self.fft_size
        
        if self._buffer_idx < self.fft_size // 2:
            return self.current_freq  # Not enough data yet
        
        # Compute FFT
        fft = np.fft.rfft(self._buffer * np.hanning(self.fft_size))
        freqs = np.fft.rfftfreq(self.fft_size, 1 / self.fs)
        
        # Find peak in range
        base_bin = int(self.base_freq * self.fft_size / self.fs)
        search_start = max(0, base_bin - self.search_bins)
        search_end = min(len(freqs), base_bin + self.search_bins + 1)
        
        peak_bin = search_start + np.argmax(np.abs(fft[search_start:search_end]))
        peak_freq = freqs[peak_bin]
        
        return peak_freq
    
    def process(self, data: np.ndarray) -> np.ndarray:
        """Process data with adaptive notch."""
        # Update frequency estimate
        self.current_freq = self._find_peak(data)
        
        # Design and apply notch filter
        b, a = signal.iirnotch(self.current_freq, self.q, self.fs)
        return signal.filtfilt(b, a, data, axis=0)
