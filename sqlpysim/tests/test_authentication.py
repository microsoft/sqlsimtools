import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import sqlpysim


def parse_and_validate(*arguments):
    with mock.patch.object(sys, "argv", ["sqlpysim.py", *arguments]):
        return sqlpysim.validate_args(sqlpysim.parse_args())


class AuthenticationTests(unittest.TestCase):
    def test_integrated_maps_without_credentials(self):
        config, _, error = parse_and_validate(
            "-S", "server", "-A", "ActiveDirectoryIntegrated"
        )

        self.assertIsNone(error)
        self.assertEqual(config.auth_method, sqlpysim.AuthMethod.ENTRA_INTEGRATED)
        manager = object.__new__(sqlpysim.ConnectionManager)
        manager.config = config
        self.assertIn(
            "Authentication=ActiveDirectoryIntegrated",
            manager.build_connection_string(),
        )

    def test_service_principal_credentials_are_used_but_masked(self):
        config, _, error = parse_and_validate(
            "-S", "server",
            "-A", "ActiveDirectoryServicePrincipal",
            "-U", "client-id",
            "-P", "test-secret;with}characters",
        )

        self.assertIsNone(error)
        manager = object.__new__(sqlpysim.ConnectionManager)
        manager.config = config
        actual = manager.build_connection_string()
        displayed = manager.get_masked_connection_string()

        self.assertIn("Authentication=ActiveDirectoryServicePrincipal", actual)
        self.assertIn("UID={client-id}", actual)
        self.assertIn("PWD={test-secret;with}}characters}", actual)
        self.assertNotIn("test-secret", displayed)
        self.assertIn("UID=********", displayed)
        self.assertIn("PWD=********", displayed)

    def test_interactive_maps_explicitly_on_windows(self):
        with mock.patch.object(sqlpysim.sys, "platform", "win32"):
            config, _, error = parse_and_validate(
                "-S", "server", "-A", "ActiveDirectoryInteractive"
            )

        self.assertIsNone(error)
        self.assertEqual(config.auth_method, sqlpysim.AuthMethod.ENTRA_INTERACTIVE)

    def test_interactive_is_rejected_on_non_windows_platforms(self):
        for platform_name, display_name in (
                ("linux", "Linux"), ("darwin", "macOS")):
            with self.subTest(platform=platform_name):
                with mock.patch.object(sqlpysim.sys, "platform", platform_name):
                    _, _, error = parse_and_validate(
                        "-S", "server", "-A", "ActiveDirectoryInteractive"
                    )

                self.assertIn(
                    f"ActiveDirectoryInteractive is not supported by "
                    f"ODBC Driver 18 on {display_name}",
                    error,
                )

    def test_msi_maps_explicitly(self):
        config, _, error = parse_and_validate(
            "-S", "server", "-A", "activedirectorymsi"
        )

        self.assertIsNone(error)
        self.assertEqual(config.auth_method, sqlpysim.AuthMethod.ENTRA_MSI)

    def test_service_principal_requires_both_credentials(self):
        _, _, error = parse_and_validate(
            "-S", "server",
            "-A", "ActiveDirectoryServicePrincipal",
            "-U", "client-id",
        )

        self.assertIn(
            "ActiveDirectoryServicePrincipal requires -U <client_id> and -P <client_secret>",
            error,
        )

    def test_msi_rejects_password(self):
        _, _, error = parse_and_validate(
            "-S", "server", "-A", "ActiveDirectoryMsi", "-P", "test-secret-value"
        )

        self.assertIn("ActiveDirectoryMsi does not accept -P", error)

    def test_unknown_mode_is_rejected(self):
        _, _, error = parse_and_validate(
            "-S", "server", "-A", "ActiveDirectoryManagedIdentity"
        )

        self.assertIn("Unknown authentication type", error)

    def test_mixed_authentication_methods_are_rejected(self):
        cases = [
            ("-E", "-T", "0123456789"),
            ("-E", "-U", "user", "-P", "password"),
            ("-T", "0123456789", "-U", "user", "-P", "password"),
            ("-A", "-E"),
            ("-A", "-T", "0123456789"),
        ]

        for arguments in cases:
            with self.subTest(arguments=arguments):
                _, _, error = parse_and_validate("-S", "server", *arguments)
                self.assertIn(
                    "Cannot mix authentication methods (-E, -A, -T, -U/-P)",
                    error,
                )


if __name__ == "__main__":
    unittest.main()
