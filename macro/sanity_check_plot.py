"""
Step 2 sanity check (see docs/phase-log.md and the task brief): before any
model training, plot the rate differential against realized forward return
for EURUSD, by eye. Report what's visible plainly -- a null result here is
real information, not a reason to skip straight to modeling anyway.

Two views of the same data: a raw scatter (as literally requested) and a
binned mean-return-by-differential-decile view, since the raw scatter alone
is dominated by noise at H1 granularity and a relationship (if any) is far
easier to see averaged within bins.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

DATASET_DIR = Path("C:/trading/_mt5-instance/macro_dataset")
OUT_DIR = Path("C:/trading/_mt5-instance/macro_dataset")


def main():
    df = pd.read_pickle(DATASET_DIR / "EURUSD.pkl")
    df = df.dropna(subset=["diff_short_rate", "fwd_return"])

    corr = df["diff_short_rate"].corr(df["fwd_return"])
    print(f"EURUSD: {len(df)} rows with both diff_short_rate and fwd_return.")
    print(f"Pearson correlation(diff_short_rate, fwd_return) = {corr:.4f}")

    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    # Raw scatter (subsampled for a readable plot -- full sample is 96k+ rows)
    sample = df.sample(n=min(5000, len(df)), random_state=42)
    axes[0].scatter(sample["diff_short_rate"], sample["fwd_return"], s=3, alpha=0.3)
    axes[0].set_xlabel("Short-rate differential (EUR - USD)")
    axes[0].set_ylabel(f"Forward return (next 24 H1 bars)")
    axes[0].set_title("EURUSD: raw scatter (5,000-row sample)")
    axes[0].axhline(0, color="gray", linewidth=0.5)
    axes[0].axvline(0, color="gray", linewidth=0.5)

    # Binned mean view: decile of the differential vs mean forward return
    df["decile"] = pd.qcut(df["diff_short_rate"], 10, labels=False, duplicates="drop")
    binned = df.groupby("decile").agg(
        mean_diff=("diff_short_rate", "mean"),
        mean_fwd_return=("fwd_return", "mean"),
        n=("fwd_return", "size"),
    ).reset_index()
    axes[1].bar(binned["decile"], binned["mean_fwd_return"])
    axes[1].set_xlabel("Short-rate differential decile (low to high)")
    axes[1].set_ylabel("Mean forward return (next 24 H1 bars)")
    axes[1].set_title("EURUSD: mean forward return by differential decile")
    axes[1].axhline(0, color="gray", linewidth=0.5)

    plt.tight_layout()
    out_path = OUT_DIR / "sanity_check_eurusd.png"
    plt.savefig(out_path, dpi=120)
    print(f"\nSaved plot to {out_path}")

    print("\nBinned decile table:")
    print(binned.to_string(index=False))


if __name__ == "__main__":
    main()
