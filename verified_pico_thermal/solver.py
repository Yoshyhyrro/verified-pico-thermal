from __future__ import annotations

from dataclasses import dataclass
import re
import subprocess
from typing import Iterable

FRAME_WIDTH = 32
FRAME_HEIGHT = 24
FRAME_SIZE = FRAME_WIDTH * FRAME_HEIGHT

_SCALE = 10
_BODY_TEMP_MIN = 300  # 30.0C
_BODY_TEMP_MAX = 430  # 43.0C


@dataclass(frozen=True)
class SolveResult:
    animal_mask: list[list[bool]]
    body_temp_range_c: tuple[float, float]


def _flatten_frame(frame: list[list[float]]) -> list[int]:
    if len(frame) != FRAME_HEIGHT:
        raise ValueError(f"frame must have {FRAME_HEIGHT} rows")

    flat: list[int] = []
    for row in frame:
        if len(row) != FRAME_WIDTH:
            raise ValueError(f"each row must have {FRAME_WIDTH} columns")
        flat.extend(round(float(value) * _SCALE) for value in row)
    return flat


def encode_thermal_frame(
    frame: list[list[float]],
    *,
    min_area: int = 4,
    max_area: int = 256,
) -> str:
    if min_area <= 0:
        raise ValueError("min_area must be > 0")
    if max_area < min_area:
        raise ValueError("max_area must be >= min_area")

    flat = _flatten_frame(frame)

    pixel_vars = [f"p_{index}" for index in range(FRAME_SIZE)]

    lines = [
        "(set-logic QF_LIA)",
        "(define-fun b2i ((b Bool)) Int (ite b 1 0))",
        "(declare-fun body_min () Int)",
        "(declare-fun body_max () Int)",
        f"(assert (<= {_BODY_TEMP_MIN} body_min))",
        f"(assert (<= body_max {_BODY_TEMP_MAX}))",
        "(assert (<= body_min body_max))",
    ]

    for index, temp in enumerate(flat):
        var = pixel_vars[index]
        lines.append(f"(declare-fun {var} () Bool)")
        lines.append(
            f"(assert (= {var} (and (<= body_min {temp}) (<= {temp} body_max))))"
        )

    area_sum = " ".join(f"(b2i {var})" for var in pixel_vars)
    lines.append(f"(assert (>= (+ {area_sum}) {min_area}))")
    lines.append(f"(assert (<= (+ {area_sum}) {max_area}))")
    lines.append("(check-sat)")
    lines.append(f"(get-value (body_min body_max {' '.join(pixel_vars)}))")
    return "\n".join(lines) + "\n"


def _parse_get_value(output: str) -> dict[str, str]:
    pairs = re.findall(r"\(([^()\s]+)\s+([^()\s]+)\)", output)
    return {name: value for name, value in pairs}


def solve_thermal_frame(
    frame: list[list[float]],
    *,
    min_area: int = 4,
    max_area: int = 256,
    yices_cmd: Iterable[str] = ("yices-smt2",),
) -> SolveResult:
    smt = encode_thermal_frame(frame, min_area=min_area, max_area=max_area)

    process = subprocess.run(
        list(yices_cmd),
        input=smt,
        capture_output=True,
        check=False,
        text=True,
    )

    if process.returncode != 0:
        raise RuntimeError(f"yices failed: {process.stderr.strip()}")

    stdout = process.stdout.strip()
    if not stdout.startswith("sat"):
        raise RuntimeError(f"unsatisfiable thermal frame: {stdout}")

    model = _parse_get_value(stdout)
    body_min = int(model["body_min"])
    body_max = int(model["body_max"])

    mask_flat = [model.get(f"p_{index}", "false") == "true" for index in range(FRAME_SIZE)]
    mask = [
        mask_flat[row_index * FRAME_WIDTH : (row_index + 1) * FRAME_WIDTH]
        for row_index in range(FRAME_HEIGHT)
    ]

    return SolveResult(
        animal_mask=mask,
        body_temp_range_c=(body_min / _SCALE, body_max / _SCALE),
    )
