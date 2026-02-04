"""
Circular Buffer for Streaming EEG Data
Phase 1: Raw data ingestion & buffering
"""

import logging
from typing import Optional

import numpy as np

logger = logging.getLogger('BCI-Buffer')


class CircularBuffer:
    """
    Thread-safe circular buffer for real-time EEG streaming.
    
    Implements Phase 1 of the processing pipeline:
    - Raw data ingestion
    - Temporal buffering for sliding window processing
    - Overlap management for continuous processing
    """
    
    def __init__(self, size: int = 1000, n_channels: int = 8, dtype=np.float64):
        """
        Initialize circular buffer.
        
        Args:
            size: Maximum number of samples to store
            n_channels: Number of EEG channels
            dtype: Data type for buffer
        """
        self.size = size
        self.n_channels = n_channels
        self.dtype = dtype
        
        # Internal buffer
        self._buffer = np.zeros((size, n_channels), dtype=dtype)
        self._index = 0
        self._count = 0
        
        logger.info(f"Buffer initialized: size={size}, channels={n_channels}")
    
    @property
    def ready(self) -> bool:
        """Check if buffer has enough data for processing."""
        return self._count >= self.size // 2
    
    @property
    def is_full(self) -> bool:
        """Check if buffer is completely filled."""
        return self._count >= self.size
    
    def push(self, sample: np.ndarray):
        """
        Push a new sample into the buffer.
        
        Args:
            sample: Array of shape (n_channels,) containing sample values
        """
        if sample.shape[0] != self.n_channels:
            raise ValueError(f"Sample has {sample.shape[0]} channels, expected {self.n_channels}")
        
        self._buffer[self._index] = sample
        self._index = (self._index + 1) % self.size
        self._count = min(self._count + 1, self.size)
    
    def push_batch(self, samples: np.ndarray):
        """
        Push multiple samples at once.
        
        Args:
            samples: Array of shape (n_samples, n_channels)
        """
        n_samples = samples.shape[0]
        
        for i in range(n_samples):
            self._buffer[self._index] = samples[i]
            self._index = (self._index + 1) % self.size
        
        self._count = min(self._count + n_samples, self.size)
    
    def get_window(self, window_size: int, offset: int = 0) -> np.ndarray:
        """
        Get a window of recent samples.
        
        Args:
            window_size: Number of samples to retrieve
            offset: Offset from current position (for overlapping windows)
        
        Returns:
            Array of shape (window_size, n_channels)
        """
        if window_size > self._count:
            window_size = self._count
        
        # Calculate start index
        start = (self._index - window_size - offset) % self.size
        
        # Handle wrap-around
        if start + window_size <= self.size:
            return self._buffer[start:start + window_size].copy()
        else:
            # Split into two parts
            end_size = self.size - start
            part1 = self._buffer[start:]
            part2 = self._buffer[:window_size - end_size]
            return np.vstack([part1, part2])
    
    def get_all(self) -> np.ndarray:
        """Get all valid samples in chronological order."""
        if self._count < self.size:
            return self._buffer[:self._count].copy()
        else:
            # Return in chronological order
            return np.vstack([
                self._buffer[self._index:],
                self._buffer[:self._index]
            ])
    
    def get_latest(self, n: int = 1) -> np.ndarray:
        """Get the n most recent samples."""
        return self.get_window(n, offset=0)
    
    def clear(self):
        """Clear the buffer."""
        self._index = 0
        self._count = 0
        self._buffer.fill(0)
        logger.debug("Buffer cleared")
    
    def __len__(self) -> int:
        """Return number of valid samples in buffer."""
        return self._count
    
    def __repr__(self) -> str:
        return f"CircularBuffer(size={self.size}, channels={self.n_channels}, count={self._count})"


class SlidingWindowBuffer:
    """
    Sliding window buffer with configurable overlap.
    
    Useful for FFT-based spectral analysis where overlapping
    windows improve time-frequency resolution.
    """
    
    def __init__(self, window_size: int, overlap: float = 0.5, n_channels: int = 8):
        """
        Initialize sliding window buffer.
        
        Args:
            window_size: Size of each window in samples
            overlap: Overlap ratio between consecutive windows (0-1)
            n_channels: Number of EEG channels
        """
        self.window_size = window_size
        self.overlap = overlap
        self.n_channels = n_channels
        self.step_size = int(window_size * (1 - overlap))
        
        # Internal circular buffer
        self._buffer = CircularBuffer(
            size=window_size * 4,  # 4x window size for flexibility
            n_channels=n_channels
        )
        
        self._last_window_end = 0
        
        logger.info(f"SlidingWindowBuffer: window={window_size}, overlap={overlap:.1%}")
    
    def push(self, sample: np.ndarray) -> Optional[np.ndarray]:
        """
        Push sample and return window if ready.
        
        Returns:
            Window array if enough new data, None otherwise
        """
        self._buffer.push(sample)
        
        # Check if we have enough new data for next window
        available = len(self._buffer) - self._last_window_end
        
        if available >= self.step_size and len(self._buffer) >= self.window_size:
            window = self._buffer.get_window(self.window_size)
            self._last_window_end += self.step_size
            return window
        
        return None
    
    def push_batch(self, samples: np.ndarray) -> list:
        """Push multiple samples and return all ready windows."""
        windows = []
        for sample in samples:
            window = self.push(sample)
            if window is not None:
                windows.append(window)
        return windows
    
    def reset(self):
        """Reset window tracking."""
        self._last_window_end = 0
        self._buffer.clear()
