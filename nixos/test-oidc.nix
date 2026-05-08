# OIDC vhost test with a self-hosted issuer.
#
# A real OIDC issuer is on the internet, which a NixOS test cannot
# reach. Instead the test ships its own RSA key pair and a JWKS
# generated at evaluation time, plus a tiny nginx vhost serving that
# JWKS. Tokens are signed in the test script with openssl.
{
  testers,
  nixosModule,
  runCommand,
  openssl,
  python3,
}:
let
  # RSA key pair + JWKS built from the same key so the cache
  # validates tokens the test mints.
  pythonWithCrypto = python3.withPackages (p: [ p.cryptography ]);
  issuer = runCommand "oidc-test-issuer" { nativeBuildInputs = [ pythonWithCrypto ]; } ''
    mkdir -p $out
    python3 ${./oidc-test-issuer.py} gen "$out"
  '';
  mint = "${pythonWithCrypto}/bin/python3 ${./oidc-test-issuer.py} mint ${issuer}/key.pem";

  snakeCert = runCommand "snake-cert" { nativeBuildInputs = [ openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=cache.test \
      -keyout $out/key -out $out/cert
  '';
in
testers.runNixOSTest {
  name = "kiss-cache-oidc";

  nodes.cache =
    { ... }:
    {
      imports = [ nixosModule ];
      networking.firewall.enable = false;
      # The test issues curl from the cache node itself; map both the
      # vhost name and the issuer to loopback.
      networking.hosts."127.0.0.1" = [
        "cache.test"
        "issuer.test"
      ];

      # Tiny issuer vhost serving the JWKS.
      services.nginx.virtualHosts."issuer.test" = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8990;
          }
        ];
        locations."= /.well-known/jwks".alias = "${issuer}/jwks.json";
      };

      services.kiss-cache-serve-oidc = {
        enable = true;
        cacheDir = "/var/lib/nix-cache";
        hostName = "cache.test";
        sslCertificate = "${snakeCert}/cert";
        sslCertificateKey = "${snakeCert}/key";
        issuer = "https://issuer.test";
        jwksUrl = "http://127.0.0.1:8990/.well-known/jwks";
        audience = "https://cache.test";
        readSubjects = [ "repo:example/*" ];
        writeSubjects = [ "repo:example/infra:ref:refs/heads/main" ];
      };
      systemd.tmpfiles.rules = [
        "d /var/lib/nix-cache 0755 nginx nginx -"
        "d /var/lib/nix-cache/nar 0755 nginx nginx -"
      ];
    };

  testScript = ''
    import time

    cache.wait_for_unit("nginx.service")

    def jwt(sub, exp_offset=3600):
        exp = int(time.time()) + exp_offset
        return cache.succeed(f"${mint} '{sub}' {exp}").strip()

    # Self-signed cert; -k skips verification, the test exercises the
    # JWT path, not TLS.
    base = "curl -sk -o /dev/null -w '%{lb}http_code{rb}' https://cache.test".format(lb="{", rb="}")

    with subtest("missing token is 401"):
        rc = cache.succeed(f"{base}/nix-cache-info").strip()
        assert rc == "401", rc

    with subtest("valid read subject can GET"):
        t = jwt("repo:example/foo:ref:refs/heads/main")
        rc = cache.succeed(f"{base}/nix-cache-info -H 'Authorization: Bearer {t}'").strip()
        assert rc == "200", f"{rc}\n{cache.succeed('journalctl -u nginx --no-pager | tail -5')}"

    with subtest("unknown subject is 403"):
        t = jwt("repo:other/repo:ref:refs/heads/main")
        rc = cache.succeed(f"{base}/nix-cache-info -H 'Authorization: Bearer {t}'").strip()
        assert rc == "403", rc

    with subtest("expired token is 403"):
        t = jwt("repo:example/foo:ref:refs/heads/main", exp_offset=-60)
        rc = cache.succeed(f"{base}/nix-cache-info -H 'Authorization: Bearer {t}'").strip()
        assert rc == "403", rc

    with subtest("read subject cannot PUT"):
        t = jwt("repo:example/foo:ref:refs/heads/main")
        rc = cache.succeed(
            f"{base}/gcroots/x -H 'Authorization: Bearer {t}' "
            "-X PUT --data-binary @/dev/null"
        ).strip()
        assert rc == "403", rc

    with subtest("write subject can PUT and DELETE"):
        t = jwt("repo:example/infra:ref:refs/heads/main")
        rc = cache.succeed(
            f"{base}/gcroots/x -H 'Authorization: Bearer {t}' "
            "-X PUT --data-binary @- <<< /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x"
        ).strip()
        assert rc.startswith("2"), rc
        cache.succeed("test -e /var/lib/nix-cache/gcroots/x")
        rc = cache.succeed(
            f"{base}/gcroots/x -H 'Authorization: Bearer {t}' -X DELETE"
        ).strip()
        assert rc.startswith("2"), rc
        cache.fail("test -e /var/lib/nix-cache/gcroots/x")
  '';
}
