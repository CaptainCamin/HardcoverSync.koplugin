#!/usr/bin/env python3
"""Checks for .github/scripts/release_notes.py. Run: python3 spec/release_notes_test.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".github", "scripts"))
import release_notes as rn  # noqa: E402


class ClassifyTest(unittest.TestCase):
    def test_label_wins_over_title(self):
        self.assertEqual(rn.classify("Fix the thing", ["enhancement"]), "new")

    def test_title_words(self):
        self.assertEqual(rn.classify("Fix scrolling stalling mid-page", []), "fixes")
        self.assertEqual(rn.classify("Add the Paused reading status", []), "new")
        self.assertEqual(rn.classify("Make the journal entry a themed form", []), "improved")
        self.assertEqual(rn.classify("Something unusual", []), "other")

    def test_developer_words_beat_first_word(self):
        self.assertEqual(rn.classify("Run the emulator at three screen sizes", []), "dev")
        self.assertEqual(rn.classify("Add Theme.* ratchet harness", []), "dev")

    def test_skip_label(self):
        self.assertIsNone(rn.classify("Anything", ["skip-release-notes"]))


class PrNumbersTest(unittest.TestCase):
    def test_merge_and_squash_subjects(self):
        log = "Merge pull request #12 from a/b\nFix x (#11)\nplain commit\nMerge pull request #10 from a/c"
        self.assertEqual(rn.pr_numbers(log), [10, 11, 12])

    def test_no_repeats(self):
        self.assertEqual(rn.pr_numbers("Fix x (#5)\nMerge pull request #5 from a/b"), [5])


class RenderTest(unittest.TestCase):
    PRS = [
        {"number": 1, "title": "Add a thing.", "labels": []},
        {"number": 2, "title": "Fix a bug", "labels": []},
        {"number": 3, "title": "Run the emulator in CI", "labels": []},
        {"number": 4, "title": "Hidden", "labels": ["skip-release-notes"]},
    ]

    def test_groups_in_order_and_skips(self):
        md = rn.render(self.PRS, intro="Hello.", compare_url="https://x/compare/a...b")
        self.assertTrue(md.startswith("Hello.\n"))
        self.assertLess(md.index("✨ New"), md.index("🐛 Fixes"))
        self.assertLess(md.index("🐛 Fixes"), md.index("🛠 For developers"))
        self.assertIn("- Add a thing (#1)", md)
        self.assertNotIn("Hidden", md)
        self.assertNotIn("Other", md)
        self.assertTrue(md.rstrip().endswith("**Full changelog**: https://x/compare/a...b"))

    def test_empty(self):
        self.assertIn("No pull requests", rn.render([]))


if __name__ == "__main__":
    unittest.main()
