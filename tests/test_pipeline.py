import shutil
import unittest

from verified_pico_thermal.solver import (
    FRAME_HEIGHT,
    FRAME_WIDTH,
    encode_thermal_frame,
    solve_thermal_frame,
)


class ThermalPipelineTest(unittest.TestCase):
    def _sample_frame(self):
        frame = [[24.0 for _ in range(FRAME_WIDTH)] for _ in range(FRAME_HEIGHT)]
        for y in range(10, 14):
            for x in range(12, 16):
                frame[y][x] = 36.5
        return frame

    def test_smt_encoding_mentions_expected_symbols(self):
        smt = encode_thermal_frame(self._sample_frame())

        self.assertIn("(declare-fun body_min () Int)", smt)
        self.assertIn("(declare-fun body_max () Int)", smt)
        self.assertIn("(declare-fun p_0 () Bool)", smt)
        self.assertIn(f"(declare-fun p_{FRAME_WIDTH * FRAME_HEIGHT - 1} () Bool)", smt)
        self.assertIn("(check-sat)", smt)

    @unittest.skipUnless(shutil.which("yices-smt2"), "yices-smt2 is required")
    def test_yices_solves_animal_mask_and_temp_range(self):
        result = solve_thermal_frame(self._sample_frame(), min_area=16, max_area=16)

        true_pixels = [
            (x, y)
            for y, row in enumerate(result.animal_mask)
            for x, value in enumerate(row)
            if value
        ]
        expected_pixels = {(x, y) for y in range(10, 14) for x in range(12, 16)}

        self.assertEqual(set(true_pixels), expected_pixels)
        self.assertAlmostEqual(result.body_temp_range_c[0], 36.5, places=1)
        self.assertAlmostEqual(result.body_temp_range_c[1], 36.5, places=1)


if __name__ == "__main__":
    unittest.main()
