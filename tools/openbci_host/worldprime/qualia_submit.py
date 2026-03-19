"""
Aptos Qualia Market CID Submission

Bridges the BCI color pipeline → qualia_market.move on Aptos.

The commit-reveal protocol:
1. COMMIT: SHA3-256(predicted_outcome || confidence || phenomenal_hash || salt || sender)
   - phenomenal_hash = SHA3-256(CID from color pipeline)
   - CID = SHA-256 of canonical (color, trit, phi, valence)
2. REVEAL: Open commitment with plaintext values
3. REPORT: Submit PhenomenalReport with qualia descriptor + intensity

Uses DOMAIN_BCI_DECODING (3) in qualia_market.move.
"""

import json
import sys
import os
import hashlib
import secrets
import time
from dataclasses import dataclass, asdict
from typing import List, Optional, Tuple


# ═══════════════════════════════════════════════════════════════════════════
# Aptos Constants (matching qualia_market.move)
# ═══════════════════════════════════════════════════════════════════════════

DOMAIN_BCI_DECODING = 3
OUTCOME_CONFIRMED = 1
OUTCOME_REFUTED = 2

# State → qualia descriptor mapping
STATE_TO_DESCRIPTOR = {
    "meditative": 10,   # high Φ, low breaking
    "relaxed": 11,
    "focused": 12,
    "alert": 13,
    "stressed": 14,
    "drowsy": 15,
    "unknown": 0,
}


# ═══════════════════════════════════════════════════════════════════════════
# Commitment Construction
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class QualiaCommitment:
    """Local commitment data (kept secret until reveal phase)."""
    market_id: int
    predicted_outcome: int     # 1=confirmed, 2=refuted
    confidence_level: int      # 0-100
    phenomenal_hash: str       # hex SHA3-256 of CID
    salt: str                  # hex random 32 bytes
    commitment_hash: str       # hex SHA3-256 of full commitment
    cid: str                   # original pipeline CID
    epoch_id: int
    state: str
    phi: float
    valence: float
    timestamp: int


def sha3_256(data: bytes) -> bytes:
    """SHA3-256 hash matching Move's hash::sha3_256."""
    return hashlib.sha3_256(data).digest()


def compute_commitment_hash(
    predicted_outcome: int,
    confidence_level: int,
    phenomenal_hash: bytes,
    salt: bytes,
    sender_address: bytes,
) -> bytes:
    """
    Matches qualia_market.move:compute_qualia_commitment_hash

    commitment_hash = sha3_256(
        predicted_outcome (u8) ||
        confidence_level (u64 BCS) ||
        phenomenal_hash ||
        salt ||
        sender (address BCS)
    )
    """
    data = bytearray()

    # predicted_outcome: u8
    data.append(predicted_outcome & 0xFF)

    # confidence_level: u64 BCS (little-endian 8 bytes)
    data.extend(confidence_level.to_bytes(8, "little"))

    # phenomenal_hash: vector<u8>
    data.extend(phenomenal_hash)

    # salt: vector<u8>
    data.extend(salt)

    # sender: address BCS (32 bytes, little-endian)
    data.extend(sender_address)

    return sha3_256(bytes(data))


def create_commitment(
    cid: str,
    epoch_id: int,
    state: str,
    phi: float,
    valence: float,
    market_id: int,
    predicted_outcome: int = OUTCOME_CONFIRMED,
    confidence_level: int = 80,
    sender_address: str = "0x" + "00" * 32,
) -> QualiaCommitment:
    """
    Create a commitment for a BCI color epoch.

    The CID from the pipeline becomes the phenomenal_hash
    (SHA3-256 of the CID string).
    """
    # Phenomenal hash = SHA3-256(CID)
    phenomenal_hash = sha3_256(cid.encode("utf-8"))

    # Random salt
    salt = secrets.token_bytes(32)

    # Sender address as bytes (strip 0x prefix, pad to 32 bytes)
    addr_hex = sender_address.replace("0x", "").replace("0X", "")
    sender_bytes = bytes.fromhex(addr_hex.ljust(64, "0"))

    # Compute commitment hash
    commitment_hash = compute_commitment_hash(
        predicted_outcome,
        confidence_level,
        phenomenal_hash,
        salt,
        sender_bytes,
    )

    return QualiaCommitment(
        market_id=market_id,
        predicted_outcome=predicted_outcome,
        confidence_level=confidence_level,
        phenomenal_hash=phenomenal_hash.hex(),
        salt=salt.hex(),
        commitment_hash=commitment_hash.hex(),
        cid=cid,
        epoch_id=epoch_id,
        state=state,
        phi=phi,
        valence=valence,
        timestamp=int(time.time()),
    )


# ═══════════════════════════════════════════════════════════════════════════
# Phenomenal Report Construction
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class PhenomenalReport:
    """Local phenomenal report data for submission."""
    market_id: int
    report_hash: str           # hex SHA3-256 of report text
    qualia_descriptor: int     # from STATE_TO_DESCRIPTOR
    intensity_rating: int      # 0-100, from confidence
    novelty_rating: int        # 0-100, from symmetry breaking
    epoch_id: int
    state: str
    cid: str


def create_phenomenal_report(
    cid: str,
    epoch_id: int,
    state: str,
    confidence: float,
    symmetry_score: float,
    market_id: int,
) -> PhenomenalReport:
    """
    Create a phenomenal report from pipeline output.

    Maps BCI metrics to qualia descriptors:
    - qualia_descriptor: from brain state classification
    - intensity_rating: from classification confidence (0-100)
    - novelty_rating: from 1 - symmetry_score (broken symmetry = novel)
    """
    # Report text is the CID + state (hashed for privacy)
    report_text = f"BCI epoch {epoch_id}: state={state} cid={cid}"
    report_hash = sha3_256(report_text.encode("utf-8"))

    descriptor = STATE_TO_DESCRIPTOR.get(state, 0)
    intensity = max(0, min(100, int(confidence * 100)))
    novelty = max(0, min(100, int((1.0 - symmetry_score) * 10000)))  # Scale up small breaks

    return PhenomenalReport(
        market_id=market_id,
        report_hash=report_hash.hex(),
        qualia_descriptor=descriptor,
        intensity_rating=intensity,
        novelty_rating=novelty,
        epoch_id=epoch_id,
        state=state,
        cid=cid,
    )


# ═══════════════════════════════════════════════════════════════════════════
# Aptos Transaction Generation
# ═══════════════════════════════════════════════════════════════════════════

def generate_commit_tx(commitment: QualiaCommitment) -> dict:
    """
    Generate Aptos transaction payload for commit_qualia_bet.

    Use with: aptos move run --function-id vibesnipe::qualia_market::commit_qualia_bet
    Or via Python Aptos SDK.
    """
    return {
        "function": "vibesnipe::qualia_market::commit_qualia_bet",
        "type_arguments": [],
        "arguments": [
            str(commitment.market_id),
            f"0x{commitment.commitment_hash}",
            "100000",  # bet_amount in octas (0.001 APT)
        ],
    }


def generate_reveal_tx(commitment: QualiaCommitment) -> dict:
    """
    Generate Aptos transaction payload for reveal_qualia_prediction.
    """
    return {
        "function": "vibesnipe::qualia_market::reveal_qualia_prediction",
        "type_arguments": [],
        "arguments": [
            str(commitment.market_id),
            str(commitment.predicted_outcome),
            str(commitment.confidence_level),
            f"0x{commitment.phenomenal_hash}",
            f"0x{commitment.salt}",
        ],
    }


def generate_report_tx(report: PhenomenalReport) -> dict:
    """
    Generate Aptos transaction payload for submit_phenomenal_report.
    """
    return {
        "function": "vibesnipe::qualia_market::submit_phenomenal_report",
        "type_arguments": [],
        "arguments": [
            str(report.market_id),
            f"0x{report.report_hash}",
            str(report.qualia_descriptor),
            str(report.intensity_rating),
            str(report.novelty_rating),
        ],
    }


# ═══════════════════════════════════════════════════════════════════════════
# Batch Processing: Color Pipeline → Commitments + Reports
# ═══════════════════════════════════════════════════════════════════════════

def process_color_epochs(
    color_json_path: str,
    market_id: int = 1,
    sender_address: str = "0x" + "00" * 32,
    predicted_outcome: int = OUTCOME_CONFIRMED,
) -> Tuple[List[QualiaCommitment], List[PhenomenalReport]]:
    """
    Process all color epochs from pipeline output into commitments + reports.
    """
    with open(color_json_path) as f:
        epochs = json.load(f)

    commitments = []
    reports = []

    for ep in epochs:
        commitment = create_commitment(
            cid=ep["cid"],
            epoch_id=ep["epoch_id"],
            state=ep["state"],
            phi=ep["phi"],
            valence=ep["valence"],
            market_id=market_id,
            predicted_outcome=predicted_outcome,
            confidence_level=max(0, min(100, int(ep["confidence"] * 100))),
            sender_address=sender_address,
        )
        commitments.append(commitment)

        report = create_phenomenal_report(
            cid=ep["cid"],
            epoch_id=ep["epoch_id"],
            state=ep["state"],
            confidence=ep["confidence"],
            symmetry_score=ep.get("symmetry_score", 1.0),
            market_id=market_id,
        )
        reports.append(report)

    return commitments, reports


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("Usage: python qualia_submit.py <command> [args...]")
        print()
        print("Commands:")
        print("  prepare <color.json> [market_id]     Prepare commitments + reports")
        print("  commit <commitments.json>             Generate commit transactions")
        print("  reveal <commitments.json>             Generate reveal transactions")
        print("  report <reports.json>                 Generate report transactions")
        print()
        print("Pipeline: EEG → Fisher → Φ → Color → CID → Aptos qualia_market")
        print("Domain: BCI_DECODING (3)")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "prepare":
        color_path = sys.argv[2]
        market_id = int(sys.argv[3]) if len(sys.argv) > 3 else 1

        commitments, reports = process_color_epochs(color_path, market_id=market_id)

        # Save commitments (KEEP SECRET until reveal)
        commit_path = color_path.rsplit(".", 1)[0] + "_commitments.json"
        with open(commit_path, "w") as f:
            json.dump([asdict(c) for c in commitments], f, indent=2)

        # Save reports
        report_path = color_path.rsplit(".", 1)[0] + "_reports.json"
        with open(report_path, "w") as f:
            json.dump([asdict(r) for r in reports], f, indent=2)

        print(f"  Prepared {len(commitments)} commitments → {commit_path}")
        print(f"  Prepared {len(reports)} reports → {report_path}")
        print()

        # Summary
        from collections import Counter
        states = Counter(c.state for c in commitments)
        print(f"  Market ID: {market_id}")
        print(f"  Domain: BCI_DECODING ({DOMAIN_BCI_DECODING})")
        print(f"  States:")
        for state, count in states.most_common():
            print(f"    {state:12s}: {count} epochs")
        print()
        print(f"  Sample commitment hash: {commitments[0].commitment_hash[:32]}...")
        print(f"  Sample CID:             {commitments[0].cid[:32]}...")

    elif cmd == "commit":
        commit_path = sys.argv[2]
        with open(commit_path) as f:
            commitments = json.load(f)

        txs = []
        for c in commitments:
            commitment = QualiaCommitment(**c)
            tx = generate_commit_tx(commitment)
            txs.append(tx)

        tx_path = commit_path.rsplit(".", 1)[0] + "_txs.json"
        with open(tx_path, "w") as f:
            json.dump(txs, f, indent=2)
        print(f"  Generated {len(txs)} commit transactions → {tx_path}")

    elif cmd == "reveal":
        commit_path = sys.argv[2]
        with open(commit_path) as f:
            commitments = json.load(f)

        txs = []
        for c in commitments:
            commitment = QualiaCommitment(**c)
            tx = generate_reveal_tx(commitment)
            txs.append(tx)

        tx_path = commit_path.rsplit(".", 1)[0] + "_reveal_txs.json"
        with open(tx_path, "w") as f:
            json.dump(txs, f, indent=2)
        print(f"  Generated {len(txs)} reveal transactions → {tx_path}")

    elif cmd == "report":
        report_path = sys.argv[2]
        with open(report_path) as f:
            reports = json.load(f)

        txs = []
        for r in reports:
            report = PhenomenalReport(**r)
            tx = generate_report_tx(report)
            txs.append(tx)

        tx_path = report_path.rsplit(".", 1)[0] + "_report_txs.json"
        with open(tx_path, "w") as f:
            json.dump(txs, f, indent=2)
        print(f"  Generated {len(txs)} report transactions → {tx_path}")

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
