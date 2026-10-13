import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import sqlpysim


def parse_and_validate(*arguments):
    with mock.patch.object(sys, "argv", ["sqlpysim.py", *arguments]):
        return sqlpysim.validate_args(sqlpysim.parse_args())


def connection_string_for(*arguments):
    config, _, error = parse_and_validate(*arguments)
    if error:
        raise AssertionError(error)
    manager = object.__new__(sqlpysim.ConnectionManager)
    manager.config = config
    return manager.build_connection_string()


class EncryptionTests(unittest.TestCase):
    def test_no_encryption_flags_trusts_server_certificate(self):
        actual = connection_string_for("-S", "server", "-E")

        self.assertIn("TrustServerCertificate=yes", actual)
        self.assertNotIn("Encrypt=", actual)

    def test_encryption_requires_certificate_validation_by_default(self):
        expected_encrypt = {"o": "no", "m": "yes", "s": "strict"}

        for level, encrypt in expected_encrypt.items():
            with self.subTest(level=level):
                actual = connection_string_for("-S", "server", "-E", "-N", level)
                self.assertIn(f"Encrypt={encrypt}", actual)
                self.assertIn("TrustServerCertificate=no", actual)

    def test_bare_encryption_flag_defaults_to_mandatory(self):
        actual = connection_string_for("-S", "server", "-E", "-N")

        self.assertIn("Encrypt=yes", actual)
        self.assertIn("TrustServerCertificate=no", actual)

    def test_trust_flag_overrides_encryption_certificate_validation(self):
        actual = connection_string_for("-S", "server", "-E", "-N", "m", "-C")

        self.assertIn("Encrypt=yes", actual)
        self.assertIn("TrustServerCertificate=yes", actual)
        self.assertNotIn("TrustServerCertificate=no", actual)

    def test_invalid_and_uppercase_encryption_levels_are_rejected(self):
        for level in ("x", "M", "mandatory"):
            with self.subTest(level=level):
                _, _, error = parse_and_validate(
                    "-S", "server", "-E", "-N", level
                )
                self.assertIn(f"Invalid encryption level '{level}'", error)


if __name__ == "__main__":
    unittest.main()
