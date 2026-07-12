"""
Step 4 (H1): does the rate-differential feature set predict direction?
Walk-forward, purged/embargoed, pre-declared bar -- see docs/phase-log.md
for the bar (AUC >= 0.55 in >= 3 of 5 out-of-sample folds), locked in before
this script was written or run.

Methodology mirrors this repo's own prior FX ML tests exactly for
comparability: 6 sequential calendar-time folds (f1-f6) spanning the full
pooled sample, rolling train-on-fold-k / test-on-fold-(k+1) -- 5 OOS test
folds, logistic regression, no tuning, pooled across EURUSD/GBPUSD/USDJPY/
AUDUSD with the SAME global fold boundaries applied to every pair (so no
pair's rows cross a boundary inconsistently with the others).

Purge/embargo (new here vs. prior same-repo tests, explicitly required by
this task's brief, sized to the label's 24-bar forward-looking window):
- Purge: the last 24 bars of the train fold (per symbol) are dropped, since
  their labels look forward past the fold boundary into test.
- Embargo: the first 24 bars of the test fold (per symbol) are dropped too,
  a standard additional buffer against residual serial correlation.
"""
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.preprocessing import StandardScaler

DATASET_DIR = Path("C:/trading/_mt5-instance/macro_dataset")
SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD"]
N_FOLDS = 6
N_LOOKAHEAD = 24  # bars -- must match build_macro_dataset.py's label window

FEATURES = [
    "diff_short_rate", "diff_yield_10y",
    "diff_short_rate_roc_1wk", "diff_short_rate_roc_1mo",
    "diff_yield_10y_roc_1wk", "diff_yield_10y_roc_1mo",
    "days_to_next_decision_base", "days_to_next_decision_quote",
]


def load_pooled():
    frames = []
    for sym in SYMBOLS:
        df = pd.read_pickle(DATASET_DIR / f"{sym}.pkl")
        df["symbol"] = sym
        frames.append(df)
    return pd.concat(frames, ignore_index=True)


def make_fold_boundaries(df):
    t_min, t_max = df["time"].min(), df["time"].max()
    edges = pd.date_range(t_min, t_max, periods=N_FOLDS + 1)
    return edges


def purge_embargo_split(df, edges, k):
    """Train = fold k (rows before edges[k], after edges[k-1] if k>1),
    minus the last N_LOOKAHEAD bars per symbol before edges[k] (purge).
    Test = fold k+1 (rows in [edges[k], edges[k+1])), minus the first
    N_LOOKAHEAD bars per symbol after edges[k] (embargo)."""
    train_start, train_end = edges[0], edges[k]
    test_start, test_end = edges[k], edges[k + 1]

    train = df[(df["time"] >= train_start) & (df["time"] < train_end)].copy()
    test = df[(df["time"] >= test_start) & (df["time"] < test_end)].copy()

    purge_cutoff = train_end - pd.Timedelta(hours=N_LOOKAHEAD)
    train = train[train["time"] < purge_cutoff]

    embargo_cutoff = test_start + pd.Timedelta(hours=N_LOOKAHEAD)
    test = test[test["time"] >= embargo_cutoff]

    return train, test


def main():
    df = load_pooled()
    df = df.dropna(subset=FEATURES + ["label_up"]).reset_index(drop=True)
    df["label_up"] = df["label_up"].astype(int)
    edges = make_fold_boundaries(df)

    print(f"Pooled dataset: {len(df)} rows with complete features+label, "
          f"{df['time'].min()} -> {df['time'].max()}")
    print(f"Fold edges: {[e.date() for e in edges]}\n")

    results = []
    for k in range(1, N_FOLDS):  # k = 1..5 -> train fold k, test fold k+1
        train, test = purge_embargo_split(df, edges, k)

        scaler = StandardScaler()
        X_train = scaler.fit_transform(train[FEATURES])
        X_test = scaler.transform(test[FEATURES])
        y_train, y_test = train["label_up"], test["label_up"]

        if y_train.nunique() < 2 or y_test.nunique() < 2 or len(test) == 0:
            print(f"f{k}->f{k+1}: SKIPPED (degenerate train/test split, "
                  f"train_n={len(train)}, test_n={len(test)})")
            continue

        model = LogisticRegression(max_iter=1000)
        model.fit(X_train, y_train)
        proba = model.predict_proba(X_test)[:, 1]
        auc = roc_auc_score(y_test, proba)

        print(f"f{k}->f{k+1}: train_n={len(train)}, test_n={len(test)}, AUC={auc:.4f}")
        results.append(auc)

    print(f"\nAUC per fold: {[round(a, 4) for a in results]}")
    n_clearing = sum(1 for a in results if a >= 0.55)
    print(f"Folds clearing AUC >= 0.55: {n_clearing} of {len(results)}")
    verdict = "SIGNAL FOUND" if n_clearing >= 3 else "NO SIGNAL FOUND"
    print(f"Pre-declared bar (>=3 of 5 folds >= 0.55): {verdict}")


if __name__ == "__main__":
    main()
