#!/usr/bin/env python3
"""
Encrypt and decrypt vathbot Polymarket credential files.

Crypto constants (must match lib/vathbot/secrets.ex):
  - Format header: vathbot-secrets-v1
  - KDF: PBKDF2-HMAC-SHA256
  - Iterations: 600_000
  - Key length: 32 bytes
  - Cipher: AES-256-GCM
  - Salt: 16 random bytes per file
  - Nonce: 12 random bytes per encryption

On-disk layout:
  vathbot-secrets-v1
  <salt: base64>
  <nonce: base64>
  <ciphertext+tag: base64>

Usage:
  python manage_secrets.py encrypt INPUT.env OUTPUT.enc
  python manage_secrets.py decrypt INPUT.enc
  python manage_secrets.py verify INPUT.enc
"""
from __future__ import annotations

import argparse
import base64
import getpass
import os
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

FORMAT_HEADER = "vathbot-secrets-v1"
PBKDF2_ITERATIONS = 600_000
KEY_LENGTH = 32
SALT_LENGTH = 16
NONCE_LENGTH = 12


def derive_key(password: bytes, salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=KEY_LENGTH,
        salt=salt,
        iterations=PBKDF2_ITERATIONS,
    )
    return kdf.derive(password)


def encrypt_plaintext(plaintext: bytes, password: str) -> str:
    salt = os.urandom(SALT_LENGTH)
    nonce = os.urandom(NONCE_LENGTH)
    key = derive_key(password.encode("utf-8"), salt)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, None)
    lines = [
        FORMAT_HEADER,
        base64.b64encode(salt).decode("ascii"),
        base64.b64encode(nonce).decode("ascii"),
        base64.b64encode(ciphertext).decode("ascii"),
    ]
    return "\n".join(lines) + "\n"


def decrypt_file(path: Path, password: str) -> str:
    raw = path.read_text(encoding="utf-8")
    return decrypt_text(raw, password)


def decrypt_text(raw: str, password: str) -> str:
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    if len(lines) != 4:
        raise ValueError("invalid encrypted file format")

    header, salt_b64, nonce_b64, ciphertext_b64 = lines
    if header != FORMAT_HEADER:
        raise ValueError(f"unsupported secrets format: {header!r}")

    salt = base64.b64decode(salt_b64)
    nonce = base64.b64decode(nonce_b64)
    ciphertext = base64.b64decode(ciphertext_b64)
    key = derive_key(password.encode("utf-8"), salt)

    try:
        plaintext = AESGCM(key).decrypt(nonce, ciphertext, None)
    except Exception as exc:
        raise ValueError("decryption failed (wrong password or corrupted file)") from exc

    return plaintext.decode("utf-8")


def parse_env(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip()
    return result


def _password_from_env_or_prompt(prompt: str) -> str:
    env_password = os.environ.get("VATHBOT_SECRETS_PASSWORD")
    if env_password is not None:
        return env_password
    return getpass.getpass(prompt)


def cmd_encrypt(input_path: Path, output_path: Path) -> int:
    plaintext = input_path.read_bytes()
    password = _password_from_env_or_prompt("Encryption password: ")
    confirm = _password_from_env_or_prompt("Confirm password: ")
    if password != confirm:
        print("Passwords do not match", file=sys.stderr)
        return 1

    output_path.write_text(encrypt_plaintext(plaintext, password), encoding="utf-8")
    os.chmod(output_path, 0o600)
    print(f"Encrypted {input_path} -> {output_path}")
    return 0


def cmd_decrypt(input_path: Path) -> int:
    password = _password_from_env_or_prompt("Decryption password: ")
    try:
        plaintext = decrypt_file(input_path, password)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    sys.stdout.write(plaintext)
    if not plaintext.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_verify(input_path: Path) -> int:
    password = _password_from_env_or_prompt("Decryption password: ")
    try:
        decrypt_file(input_path, password)
    except ValueError as exc:
        print(f"verify failed: {exc}", file=sys.stderr)
        return 1

    print("OK")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Encrypt/decrypt vathbot credential files.")
    sub = parser.add_subparsers(dest="command", required=True)

    enc = sub.add_parser("encrypt", help="Encrypt a plaintext .env file")
    enc.add_argument("input", type=Path, help="Plaintext .env input")
    enc.add_argument("output", type=Path, help="Encrypted output path")

    dec = sub.add_parser("decrypt", help="Decrypt to stdout")
    dec.add_argument("input", type=Path, help="Encrypted input file")

    ver = sub.add_parser("verify", help="Verify password without printing secrets")
    ver.add_argument("input", type=Path, help="Encrypted input file")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "encrypt":
        return cmd_encrypt(args.input, args.output)
    if args.command == "decrypt":
        return cmd_decrypt(args.input)
    if args.command == "verify":
        return cmd_verify(args.input)

    return 1


if __name__ == "__main__":
    sys.exit(main())
