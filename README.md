# verified-pico-thermal

32x24 の熱画像データを SMT 制約にエンコードし、Yices SMT Solver で動物領域マスクと体温範囲を解く最小実装です。

## ローカル検証

```bash
python -m pip install yices-solver
python -m unittest discover -s tests -v
```

## パイプライン

熱画像データ (32x24) → SMT制約エンコーディング → Yices SMT Solver → 解 (動物領域マスク + 体温範囲) → CI で自動検証
