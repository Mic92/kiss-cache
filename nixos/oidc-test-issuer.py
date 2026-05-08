#!/usr/bin/env python3
"""Test OIDC issuer fixture: keygen + JWKS + token minter.

`gen DIR` writes `DIR/key.pem` (private key) and `DIR/jwks.json`
(matching public JWKS) at Nix build time.

`mint KEYFILE SUB EXP` signs a JWT for the test script to send.
"""

import base64
import json
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def int_b64u(i: int) -> str:
    return b64u(i.to_bytes((i.bit_length() + 7) // 8, "big"))


def gen(out: str) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with open(f"{out}/key.pem", "wb") as f:
        f.write(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
    pub = key.public_key().public_numbers()
    with open(f"{out}/jwks.json", "w") as f:
        json.dump(
            {
                "keys": [
                    {
                        "kty": "RSA",
                        "use": "sig",
                        "alg": "RS256",
                        "kid": "test",
                        "n": int_b64u(pub.n),
                        "e": int_b64u(pub.e),
                    }
                ]
            },
            f,
        )


def mint(keyfile: str, sub: str, exp: str) -> None:
    with open(keyfile, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    h = b64u(json.dumps({"alg": "RS256", "typ": "JWT", "kid": "test"}).encode())
    p = b64u(
        json.dumps(
            {
                "iss": "https://issuer.test",
                "aud": "https://cache.test",
                "sub": sub,
                "exp": int(exp),
            }
        ).encode()
    )
    sig = key.sign(f"{h}.{p}".encode(), padding.PKCS1v15(), hashes.SHA256())
    print(f"{h}.{p}.{b64u(sig)}", end="")


if __name__ == "__main__":
    {"gen": gen, "mint": mint}[sys.argv[1]](*sys.argv[2:])
