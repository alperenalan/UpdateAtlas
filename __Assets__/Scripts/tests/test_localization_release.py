"""Release gate must reject stale text reviews and QA for another binary."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "localization_release", ROOT / "__Assets__/Scripts/Apple/check_localization_release.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
PREPARE_SPEC = importlib.util.spec_from_file_location(
    "prepare_for_localization_test", ROOT / "__Assets__/Scripts/Apple/prepare_appcast.py")
PREPARE = importlib.util.module_from_spec(PREPARE_SPEC)
PREPARE_SPEC.loader.exec_module(PREPARE)


class LocalizationReleaseTests(unittest.TestCase):
    def test_appcast_preparation_stops_at_open_localization_gate(self):
        archive = ROOT / ".temporary_files/App.zip"
        output = ROOT / ".temporary_files/appcast-localization-test-output"
        with patch.object(PREPARE, "validate_zip"), patch.object(
            PREPARE.subprocess, "run", return_value=SimpleNamespace(returncode=1)
        ):
            with self.assertRaisesRegex(ValueError, "Localization release gate"):
                PREPARE.prepare(archive, Path("unused-feed"),
                    "https://github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip",
                    output, Path("unused-tools"))

    def test_two_independent_current_text_readers_are_required(self):
        scratch = ROOT / ".temporary_files/localization-gate-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            review_file = Path(folder) / "reviews.tsv"
            header = "item\tfield\thash\tsource_hash\treader\tdate\tverdict\tnote\n"
            current = GATE.digest("Merhaba".encode())
            english = GATE.digest("Hello".encode())
            with patch.object(GATE, "REVIEWS", review_file), patch.object(
                GATE, "translations", return_value={("app:Hello", "tr"): ("Hello", "Merhaba")}
            ):
                review_file.write_text(header)
                self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google,openai")
                review_file.write_text(header + f"app:Hello\ttr\t{current}\t{english}\topenai:first\t2026-10-23\tok\t\n")
                self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google")
                review_file.write_text(review_file.read_text() +
                    f"app:Hello\ttr\t{current}\t{english}\tgoogle:second\t2026-10-23\tok\t\n")
                self.assertEqual(GATE.review_errors("app")[1], [])
                review_file.write_text(header +
                    f"app:Hello\ttr\t{current}\t{english}\tanthropic:first\t2026-10-24\tok\t\n")
                self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google")
                review_file.write_text(review_file.read_text() +
                    f"app:Hello\ttr\t{current}\t{english}\tgoogle:second\t2026-10-24\tok\t\n")
                self.assertEqual(GATE.review_errors("app")[1], [])
                with patch.object(GATE, "translations", return_value={("app:Hello", "tr"): ("Hello", "Selam")}):
                    self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google,openai")
                with patch.object(GATE, "translations", return_value={("app:Hello", "tr"): ("Hi", "Merhaba")}):
                    self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google,openai")

    def test_baseline_cannot_be_refreshed_to_excuse_new_text(self):
        scratch = ROOT / ".temporary_files/localization-gate-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            changed_baseline = Path(folder) / "baseline.json"
            changed_baseline.write_text('{"app": {}, "site": {}}')
            with patch.object(GATE, "BASELINE", changed_baseline):
                with self.assertRaisesRegex(ValueError, "baseline changed"):
                    GATE.review_errors("site", changed_only=True)

    def test_reasoned_dismissal_closes_only_exact_reader_objection(self):
        scratch = ROOT / ".temporary_files/localization-gate-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            folder = Path(folder)
            review = folder / "review.tsv"
            dismissal = folder / "dismissal.tsv"
            target_hash = GATE.digest("Aç".encode())
            source_hash = GATE.digest("Open".encode())
            review.write_text("\t".join(GATE.REVIEW_FIELDS) + "\n" +
                              f"app:Open\ttr\t{target_hash}\t{source_hash}\topenai:codex\t2026-10-23\tok\t\n" +
                              f"app:Open\ttr\t{target_hash}\t{source_hash}\tgoogle:gemini\t2026-10-23\tfix\t[C23] Açın\n")
            header = "item\tfield\thash\tsource_hash\treader\treason\tdecided_by\tdate\n"
            dismissal.write_text(header)
            with patch.object(GATE, "REVIEWS", review), patch.object(GATE, "DISMISSALS", dismissal), patch.object(
                GATE, "translations", return_value={("app:Open", "tr"): ("Open", "Aç")}
            ):
                self.assertEqual(GATE.review_errors("app")[1][0][2], "open objection")
                dismissal.write_text(header +
                    f"app:Open\ttr\t{target_hash}\t{source_hash}\tgoogle:gemini\t[C23] Valid short button label\topenai:codex\t2026-10-23\n")
                self.assertEqual(GATE.review_errors("app")[1], [])
                with patch.object(GATE, "translations", return_value={("app:Open", "tr"): ("Open", "Açın")}):
                    self.assertEqual(GATE.review_errors("app")[1][0][2], "missing google,openai")

    def test_native_qa_is_bound_to_exact_archive_bytes(self):
        scratch = ROOT / ".temporary_files/localization-gate-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            archive = Path(folder) / "app.zip"
            archive.write_bytes(b"first signed archive")
            qa_file = Path(folder) / "qa.tsv"
            qa_file.write_text("archive_sha256\tlocale\tsurface\treader\tdate\tverdict\tnote\n")
            with patch.object(GATE, "RUNTIME_QA", qa_file), patch.object(GATE, "APP_LOCALES", ("tr",)), patch.object(GATE, "QA_SURFACES", ("main",)):
                self.assertEqual(GATE.qa_errors(archive), [("tr", "main")])
                import hashlib
                archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
                qa_file.write_text(qa_file.read_text() +
                    f"{archive_hash}\ttr\tmain\thuman:reviewer\t2026-10-23\tpass\t\n")
                self.assertEqual(GATE.qa_errors(archive), [])
                qa_file.write_text(qa_file.read_text() +
                    f"{archive_hash}\ttr\tmain\thuman:reviewer\t2026-10-23\tfail\tclipped label\n")
                self.assertEqual(GATE.qa_errors(archive), [("tr", "main")])
                archive.write_bytes(b"different signed archive")
                self.assertEqual(GATE.qa_errors(archive), [("tr", "main")])


if __name__ == "__main__":
    unittest.main()
