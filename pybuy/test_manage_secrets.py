#!/usr/bin/env python3
"""Round-trip tests for manage_secrets.py."""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from manage_secrets import decrypt_file, decrypt_text, encrypt_plaintext, parse_env


FIXTURE = """POLYMARKET_PRIVATE_KEY=0xabc123
POLYMARKET_FUNDER=0xdef456
POLYMARKET_SIGNATURE_TYPE=2
"""
PASSWORD = "unit-test-password"


class ManageSecretsTest(unittest.TestCase):
    def test_encrypt_decrypt_round_trip(self) -> None:
        encrypted = encrypt_plaintext(FIXTURE.encode("utf-8"), PASSWORD)
        plaintext = decrypt_text(encrypted, PASSWORD)
        self.assertEqual(plaintext, FIXTURE)

    def test_wrong_password_fails(self) -> None:
        encrypted = encrypt_plaintext(FIXTURE.encode("utf-8"), PASSWORD)
        with self.assertRaises(ValueError):
            decrypt_text(encrypted, "wrong-password")

    def test_file_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            enc_path = Path(tmp) / "secrets.env.enc"
            enc_path.write_text(encrypt_plaintext(FIXTURE.encode("utf-8"), PASSWORD), encoding="utf-8")
            self.assertEqual(decrypt_file(enc_path, PASSWORD), FIXTURE)

    def test_parse_env(self) -> None:
        parsed = parse_env(FIXTURE)
        self.assertEqual(parsed["POLYMARKET_PRIVATE_KEY"], "0xabc123")
        self.assertEqual(parsed["POLYMARKET_FUNDER"], "0xdef456")
        self.assertEqual(parsed["POLYMARKET_SIGNATURE_TYPE"], "2")


if __name__ == "__main__":
    unittest.main()
