import unittest

from generate_home_scrim import alpha_at, render


class HomeScrimGeneratorTests(unittest.TestCase):
    def test_clear_center_keeps_only_the_wash(self):
        self.assertAlmostEqual(alpha_at(0.5, 0.2), 0.06)

    def test_bottom_corner_combines_all_three_layers(self):
        self.assertAlmostEqual(alpha_at(0, 1), 1 - 0.94 * 0.45 * 0.45)

    def test_far_bottom_edge_has_no_side_darkening(self):
        self.assertAlmostEqual(alpha_at(1, 1), 1 - 0.94 * 0.45)

    def test_side_ramp_preserves_its_middle_stop(self):
        self.assertAlmostEqual(alpha_at(0, 0.34), 1 - 0.94 * (1 - 0.55 * 0.35))

    def test_renderer_samples_the_continuous_field_at_pixel_centers(self):
        image = render(16, 9)
        for y in range(9):
            for x in range(16):
                red, green, blue, alpha = image.getpixel((x, y))
                self.assertEqual((red, green, blue), (255, 255, 255))
                self.assertEqual(alpha, round(alpha_at((x + 0.5) / 16, (y + 0.5) / 9) * 255))


if __name__ == "__main__":
    unittest.main()
