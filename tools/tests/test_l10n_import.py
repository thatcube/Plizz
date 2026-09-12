#!/usr/bin/env python3
"""Regression tests for the translation-import safety gate."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "l10n-import.py"
SPEC = importlib.util.spec_from_file_location("l10n_import", MODULE_PATH)
assert SPEC and SPEC.loader
l10n_import = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(l10n_import)


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "needs_review", "value": value}}


def substitution_localization(
    one: str = "%lld episode", other: str = "%lld episodes"
) -> dict:
    return {
        "stringUnit": {
            "state": "needs_review",
            "value": "%#@arg1@ • %2$@",
        },
        "substitutions": {
            "arg1": {
                "argNum": 1,
                "formatSpecifier": "lld",
                "variations": {
                    "plural": {
                        "one": unit(one),
                        "other": unit(other),
                    }
                },
            }
        },
    }


class TranslationImportTests(unittest.TestCase):
    def source_delta_fixture(self) -> tuple[dict, dict]:
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "%lld channels": {"localizations": {}},
                "Unchanged": {"localizations": {"en": {"stringUnit": {"state": "new", "value": "Unchanged"}}}},
            },
        }
        canonical = json.dumps(
            catalog, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        document = {
            "language": "en",
            "sourceCatalogSHA256": hashlib.sha256(canonical).hexdigest(),
            "deltaKeys": ["%lld channels"],
            "translations": {
                "%lld channels": {
                    "variations": {"plural": {
                        "one": unit("%lld channel"), "other": unit("%lld channels"),
                    }},
                },
            },
        }
        return catalog, document

    def validate_source_delta(self, catalog: dict, document: dict) -> dict:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / f"{document['language']}.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            _, translations, _ = l10n_import.validate_language(
                path, catalog["strings"], False, source_delta_catalog=catalog
            )
            return translations

    def test_source_delta_preserves_unmentioned_source_entries(self) -> None:
        catalog, document = self.source_delta_fixture()
        before = json.dumps(catalog)
        result = self.validate_source_delta(catalog, document)
        self.assertEqual(list(result), ["%lld channels"])
        self.assertEqual(json.dumps(catalog), before)

    def test_source_delta_rejects_wrong_language_hash_keys_and_states(self) -> None:
        for change, error in (
            (lambda d: d.update(language="de"), "source language"),
            (lambda d: d.update(sourceCatalogSHA256="stale"), "another source"),
            (lambda d: d.update(deltaKeys=[]), "exact nonempty ordered keys"),
            (lambda d: d.update(deltaKeys=["Unknown"], translations={"Unknown": unit("Unknown")}), "unknown catalog"),
            (lambda d: d["translations"].update({"%lld channels": {"stringUnit": {"state": "translated", "value": "%lld channels"}}}), "remain needs_review"),
            (lambda d: d["translations"].update({"%lld channels": unit("channels")}), "placeholder types changed"),
        ):
            with self.subTest(error=error):
                catalog, document = self.source_delta_fixture()
                change(document)
                with self.assertRaisesRegex(l10n_import.ImportErrorDetail, error):
                    self.validate_source_delta(catalog, document)

    def test_translation_import_still_requires_full_coverage(self) -> None:
        catalog, document = self.source_delta_fixture()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "en.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(l10n_import.ImportErrorDetail, "missing 1 key"):
                l10n_import.validate_language(path, catalog["strings"], False)

    def test_source_delta_application_preserves_other_languages_and_source_states(self) -> None:
        catalog, document = self.source_delta_fixture()
        catalog["strings"]["%lld channels"]["localizations"]["fr"] = unit("%lld chaînes")
        document["sourceCatalogSHA256"] = hashlib.sha256(json.dumps(
            catalog, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            catalog_path = root / "Localizable.xcstrings"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            (root / "en.json").write_text(json.dumps(document), encoding="utf-8")
            args = SimpleNamespace(
                catalog=catalog_path, input_dir=root, languages="en",
                allow_translated_state=False, require_info_plist=False,
                source_delta=True, apply=True,
            )
            with (
                patch.object(l10n_import, "parse_args", return_value=args),
                patch.object(l10n_import, "REPO", root),
                patch.object(l10n_import, "INFO_CATALOGS", {}),
                patch.object(l10n_import, "never_translate_terms", return_value=[]),
                patch.object(l10n_import, "compile_catalog") as compile_catalog,
            ):
                self.assertEqual(l10n_import.main(), 0)
            result = json.loads(catalog_path.read_text(encoding="utf-8"))
            expected = json.loads(json.dumps(catalog))
            expected["strings"]["%lld channels"]["localizations"]["en"] = document["translations"]["%lld channels"]
            self.assertEqual(result, expected)
            compile_catalog.assert_called_once_with(expected)

    def validate(self, localization: dict) -> None:
        l10n_import.validate_localization(
            "de",
            "%lld episodes • %@",
            {"localizations": {}},
            localization,
            allow_translated_state=False,
        )

    def test_valid_substitution_preserves_each_runtime_argument(self) -> None:
        self.validate(substitution_localization())

    def test_substitution_leaf_cannot_drop_count_placeholder(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "must contain exactly"
        ):
            self.validate(substitution_localization(other="mehrere Folgen"))

    def test_substitution_leaf_cannot_add_runtime_placeholder(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "must contain exactly"
        ):
            self.validate(
                substitution_localization(other="%lld Folgen und %@ weitere")
            )

    def test_substitution_leaf_cannot_change_placeholder_type(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "must contain exactly"
        ):
            self.validate(substitution_localization(one="%@ Folge"))

    def test_direct_plural_categories_must_agree(self) -> None:
        localization = {
            "variations": {
                "plural": {
                    "one": unit("%lld cue"),
                    "other": unit("cues"),
                }
            }
        }
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail,
            "plural categories do not preserve the same placeholders",
        ):
            l10n_import.validate_localization(
                "de",
                "%lld cues",
                {"localizations": {}},
                localization,
                allow_translated_state=False,
            )

    def test_precision_printf_syntax_is_supported(self) -> None:
        l10n_import.validate_known_format_syntax("Progress %.2f", "test string")
        self.assertEqual(l10n_import.placeholder_types("Progress %.2f"), ["f"])

    def test_unknown_printf_syntax_fails_instead_of_being_ignored(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "unsupported format sequence"
        ):
            l10n_import.validate_known_format_syntax(
                "Progress %q", "test string"
            )

    def test_language_tag_rejects_underscore_and_wrong_case(self) -> None:
        for language in ("pt_BR", "pt-br", "ZH-hans"):
            with self.subTest(language=language), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / f"{language}.json"
                path.write_text(
                    json.dumps(
                        {
                            "language": language,
                            "translations": {},
                        }
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    l10n_import.ImportErrorDetail, "canonical supported BCP-47"
                ):
                    l10n_import.validate_language(
                        path, {}, allow_translated_state=False
                    )

    def test_supported_language_tags_pass_shape_check(self) -> None:
        for language in ("de", "pt-BR", "zh-Hans", "zh-Hant"):
            with self.subTest(language=language):
                self.assertRegex(language, l10n_import.LANGUAGE_TAG_RE)

    def test_utf8_json_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "ja.json"
            path.write_text('{"language":"ja","value":"日本語"}', encoding="utf-8")
            self.assertEqual(l10n_import.load_json(path)["value"], "日本語")

    def test_protected_brand_cannot_be_translated_or_removed(self) -> None:
        source_entry = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Connect to Plex",
                    }
                }
            }
        }
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "protected term.*Plex"
        ):
            l10n_import.validate_localization(
                "de",
                "connect.plex",
                source_entry,
                unit("Mit dem Server verbinden"),
                allow_translated_state=False,
                protected_terms=["Plex"],
            )

    def test_protected_brand_can_move_with_grammar(self) -> None:
        source_entry = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": "Connect to Plex",
                    }
                }
            }
        }
        l10n_import.validate_localization(
            "de",
            "connect.plex",
            source_entry,
            unit("Mit Plex verbinden"),
            allow_translated_state=False,
            protected_terms=["Plex"],
        )

    def test_fragment_cannot_drop_boundary_space(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "boundary whitespace changed"
        ):
            l10n_import.validate_localization(
                "de",
                " ahead",
                {"localizations": {}},
                unit("voraus"),
                allow_translated_state=False,
            )

    def test_multiline_copy_cannot_collapse_lines(self) -> None:
        with self.assertRaisesRegex(
            l10n_import.ImportErrorDetail, "newline count changed"
        ):
            l10n_import.validate_localization(
                "de",
                "First line\n\nSecond line",
                {"localizations": {}},
                unit("Erste Zeile Zweite Zeile"),
                allow_translated_state=False,
            )


if __name__ == "__main__":
    unittest.main()
