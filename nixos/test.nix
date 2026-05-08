{
  testers,
  nixosModule,
  runCommand,
  openssl,
}:
let
  # Self-signed CA + server cert + client cert for the mTLS handshake. Built
  # at evaluation time so the test is hermetic.
  certs =
    runCommand "nix-cache-test-certs"
      {
        nativeBuildInputs = [ openssl ];
      }
      ''
        mkdir -p $out
        cd $out

        # CA
        openssl req -x509 -newkey ed25519 -nodes -days 1 \
          -subj "/CN=nix-cache-test-ca" \
          -keyout ca.key -out ca.pem

        # Server cert for "cache" with a SAN so curl/nix verify it.
        openssl req -newkey ed25519 -nodes \
          -subj "/CN=cache" -addext "subjectAltName=DNS:cache" \
          -keyout server.key -out server.csr
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key \
          -days 1 -copy_extensions copy -out server.pem

        # Read-only client cert presented by the importer.
        openssl req -newkey ed25519 -nodes \
          -subj "/CN=reader" \
          -keyout client.key -out client.csr
        openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key \
          -days 1 -out client.pem

        # Write-allowed cert presented by a builder pushing to the cache.
        openssl req -newkey ed25519 -nodes \
          -subj "/CN=writer" \
          -keyout writer.key -out writer.csr
        openssl x509 -req -in writer.csr -CA ca.pem -CAkey ca.key \
          -days 1 -out writer.pem
      '';

  signingKey = "cache:SerxxAca5NEsYY0DwVo+subokk+OoHcD9m6JwuctzHgSQVfGHe6nCc+NReDjV3QdFYPMGix4FMg0+K/TM1B3aA==";
  publicKey = "cache:EkFXxh3upwnPjUXg41d0HRWDzBoseBTINPiv0zNQd2g=";
in
testers.runNixOSTest {
  name = "kiss-cache";

  nodes.cache =
    { lib, ... }:
    {
      imports = [ nixosModule ];

      virtualisation.writableStore = true;
      nix.settings.experimental-features = [ "nix-command" ];
      networking.firewall.allowedTCPPorts = [ 443 ];

      systemd.tmpfiles.rules = [
        "d /var/lib/nix-cache 0755 nginx nginx -"
        "d /var/lib/nix-cache/nar 0755 nginx nginx -"
        # Use a tmpfiles-created directory so the test controls exactly which
        # roots exist; the system's own /nix/var/nix/gcroots would pull in the
        # whole VM closure and make the assertions meaningless.
        "d /var/lib/nix-cache-roots 0755 root root -"
        # A second binary cache served plain HTTP from the same nginx, used
        # as the fallback upstream for the proxy_store test.
        "d /var/lib/upstream-cache 0755 nginx nginx -"
      ];

      environment.etc."nix/secret-key".text = signingKey;

      networking.hosts."127.0.0.1" = [ "upstream" ];

      services = {
        nginx.virtualHosts."upstream".root = "/var/lib/upstream-cache";
        kiss-cache-serve = {
          enable = true;
          cacheDir = "/var/lib/nix-cache";
          hostName = "cache";
          sslCertificate = "${certs}/server.pem";
          sslCertificateKey = "${certs}/server.key";
          clientCA = "${certs}/ca.pem";
          writers = [ "CN=writer" ];
          fallbackCache = "http://upstream";
          gcRootMaxAge = "7d";
        };
        kiss-cache = {
          enable = true;
          cacheDir = "/var/lib/nix-cache";
          gcRoots = [ "/var/lib/nix-cache-roots" ];
        };
      };
    };

  nodes.importer =
    { lib, ... }:
    {
      imports = [ nixosModule ];
      virtualisation.writableStore = true;
      nix.settings = {
        experimental-features = [ "nix-command" ];
        substituters = lib.mkForce [
          "https://cache?tls-certificate=${certs}/client.pem&tls-private-key=${certs}/client.key"
        ];
        trusted-public-keys = lib.mkForce [ publicKey ];
        ssl-cert-file = "${certs}/ca.pem";
      };
      services.kiss-cache-update = {
        enable = true;
        cacheUrl = "https://cache";
        marker = "importer";
        tlsCertificate = "${certs}/client.pem";
        tlsPrivateKey = "${certs}/client.key";
        tlsCACertificate = "${certs}/ca.pem";
      };
      # Don't let the timer fire on its own mid-test.
      systemd.timers.kiss-cache-update.enable = false;
    };

  testScript = ''
    start_all()
    cache.wait_for_unit("nginx.service")
    cache.wait_for_open_port(443)
    importer.wait_for_unit("multi-user.target")

    ca = "${certs}/ca.pem"
    cert = "${certs}/client.pem"
    key = "${certs}/client.key"
    store = f"https://cache?tls-certificate={cert}&tls-private-key={key}"
    wcert = "${certs}/writer.pem"
    wkey = "${certs}/writer.key"
    wstore = f"https://cache?compression=zstd&tls-certificate={wcert}&tls-private-key={wkey}"

    with subtest("mTLS rejects clients without a certificate"):
        # 400 Bad Request (no required SSL certificate), not a TLS alert,
        # since nginx accepts the handshake and rejects at the HTTP layer.
        status = cache.succeed(
            f"curl -sk --cacert {ca} -o /dev/null -w '%{{http_code}}' https://cache/nix-cache-info"
        ).strip()
        assert status == "400", f"expected 400 without client cert, got {status}"

    with subtest("mTLS accepts clients with a trusted certificate"):
        info = cache.succeed(
            f"curl -s --cacert {ca} --cert {cert} --key {key} https://cache/nix-cache-info"
        )
        assert "StoreDir: /nix/store" in info, info

    with subtest("populate the cache and substitute over mTLS"):
        drv = cache.succeed(
            "nix build --impure --print-out-paths --expr "
            "'derivation { name = \"hello-cache\"; system = builtins.currentSystem; "
            "builder = \"/bin/sh\"; args = [\"-c\" \"echo hi > $out\"]; }'"
        ).strip()
        cache.succeed(
            f"nix copy --to 'file:///var/lib/nix-cache?secret-key=/etc/nix/secret-key' {drv}"
        )
        cache.succeed("chown -R nginx:nginx /var/lib/nix-cache")
        # Reachable from the pruner's gcroots dir so it survives.
        cache.succeed(f"echo {drv} > /var/lib/nix-cache-roots/keep")

        importer.succeed(f"nix copy --no-check-sigs --from '{store}' {drv}")
        importer.succeed(f"test -e {drv}")

    with subtest("pruner deletes only unreachable cache entries"):
        garbage = "z" * 32
        import base64
        narinfo = base64.b64encode("\n".join([
            f"StorePath: /nix/store/{garbage}-garbage",
            f"URL: nar/{garbage}.nar.xz",
            "Compression: xz",
            "FileSize: 1",
            "NarSize: 1",
            "References:",
            "",
        ]).encode()).decode()
        cache.succeed(
            f"echo {narinfo} | base64 -d > /var/lib/nix-cache/{garbage}.narinfo"
        )
        cache.succeed(f"echo x > /var/lib/nix-cache/nar/{garbage}.nar.xz")

        cache.succeed("systemctl start kiss-cache.service")

        cache.fail(f"test -e /var/lib/nix-cache/{garbage}.narinfo")
        cache.fail(f"test -e /var/lib/nix-cache/nar/{garbage}.nar.xz")
        remaining = cache.succeed("ls /var/lib/nix-cache/*.narinfo").strip()
        assert remaining, "all narinfo files were deleted"
        # Survivor still fetchable end-to-end over mTLS.
        importer.succeed(f"nix-store --delete {drv} || true")
        importer.succeed(f"nix copy --no-check-sigs --from '{store}' {drv}")

    with subtest("writer cert can push, reader cert cannot"):
        push = importer.succeed(
            "nix build --impure --print-out-paths --expr "
            "'derivation { name = \"hello-push\"; system = builtins.currentSystem; "
            "builder = \"/bin/sh\"; args = [\"-c\" \"echo pushed > $out\"]; }'"
        ).strip()
        importer.fail(f"nix copy --to '{store}' {push}")
        importer.succeed(f"nix copy --to '{wstore}' {push}")
        cache.succeed(f"ls /var/lib/nix-cache/*.narinfo | xargs grep -l {push.split('/')[-1]}")

    with subtest("PUT gcroot marker keeps a pushed closure across pruning"):
        marker = "ci-job-1"
        # Reader cannot register roots.
        importer.fail(
            f"echo {push} | curl --fail -s --cacert {ca} --cert {cert} --key {key} "
            f"-X PUT --data-binary @- https://cache/gcroots/{marker}"
        )
        importer.succeed(
            f"echo {push} | curl --fail -s --cacert {ca} --cert {wcert} --key {wkey} "
            f"-X PUT --data-binary @- https://cache/gcroots/{marker}"
        )
        cache.succeed(f"grep -qx {push} /var/lib/nix-cache/gcroots/{marker}")

    with subtest("reader can GET a gcroot marker, no cert cannot"):
        importer.succeed(
            f"curl --fail -s --cacert {ca} --cert {cert} --key {key} "
            f"https://cache/gcroots/{marker} | grep -qx {push}"
        )
        importer.fail(f"curl --fail -sk --cacert {ca} https://cache/gcroots/{marker}")

    with subtest("kiss-cache-update is a no-op when already on the published system"):
        cur = importer.succeed("readlink /run/current-system").strip()
        before = importer.succeed("readlink -f /nix/var/nix/profiles/system").strip()
        cache.succeed(f"echo {cur} > /var/lib/nix-cache/gcroots/importer")
        importer.succeed("systemctl start kiss-cache-update.service")
        after = importer.succeed("readlink -f /nix/var/nix/profiles/system").strip()
        assert before == after, f"profile changed despite already-current system: {before} -> {after}"

    with subtest("kiss-cache-update is a no-op when no marker is published"):
        cache.succeed("rm /var/lib/nix-cache/gcroots/importer")
        importer.succeed("systemctl start kiss-cache-update.service")
        after = importer.succeed("readlink -f /nix/var/nix/profiles/system").strip()
        assert before == after, f"profile changed on missing marker: {before} -> {after}"

    with subtest("kiss-cache-update CLI requires an action and accepts a marker URL"):
        importer.fail("kiss-cache-update")
        importer.fail("kiss-cache-update bogus")
        cache.succeed(f"echo {cur} > /var/lib/nix-cache/gcroots/staging")
        importer.succeed("kiss-cache-update switch https://cache/gcroots/staging")

    with subtest("kiss-cache-update realises and switches to a new system"):
        # Stub toplevel exercising the substituter URL and `nix-store
        # --realise` that the no-op subtests above never reach. It
        # shares kernel/initrd/kernel-params with the running system so
        # the update script takes the in-place switch branch, has a
        # no-op switch-to-configuration so the test VM stays sane, and
        # a sentinel file to prove the right closure was activated.
        # `nix-store --add` registers the directory directly, skipping
        # the build sandbox (which lacks coreutils).
        booted = importer.succeed("readlink /run/booted-system").strip()
        importer.succeed(
            "set -e; rm -rf /tmp/fake-system; mkdir -p /tmp/fake-system/bin; "
            f"for f in kernel initrd kernel-params; do cp -P {booted}/$f /tmp/fake-system/$f 2>/dev/null || true; done; "
            "echo updated > /tmp/fake-system/sentinel; "
            "printf '#!/bin/sh\\nexit 0\\n' > /tmp/fake-system/bin/switch-to-configuration; "
            "chmod +x /tmp/fake-system/bin/switch-to-configuration"
        )
        fake = importer.succeed("nix-store --add /tmp/fake-system").strip()
        importer.succeed(f"nix copy --no-check-sigs --to '{wstore}' {fake}")
        importer.succeed(
            f"echo {fake} | curl --fail -s --cacert {ca} --cert {wcert} --key {wkey} "
            f"-X PUT --data-binary @- https://cache/gcroots/realise-test"
        )
        # Drop the local copy so realise must actually substitute.
        importer.succeed(f"nix-store --delete {fake}")
        importer.fail(f"test -e {fake}")
        out = importer.succeed(
            "kiss-cache-update switch https://cache/gcroots/realise-test 2>&1"
        )
        # The fake shares kernel/initrd/kernel-params with the booted
        # system; the script must take the in-place switch branch, not
        # the boot-changed branch. Catches false positives in
        # boot_fingerprint().
        assert "needs a reboot" not in out, f"spurious boot change detected:\n{out}"
        importer.succeed(f"test -e {fake}/sentinel")
        prof = importer.succeed("readlink -f /nix/var/nix/profiles/system").strip()
        assert prof == fake, f"profile not set: {prof} != {fake}"
        # Restore the real system profile for subsequent subtests.
        importer.succeed(f"nix-env --profile /nix/var/nix/profiles/system --set {before}")

    with subtest("kiss-cache-update detects a kernel-parameter change"):
        # Same stub, different kernel-params: the script must take the
        # boot-changed branch. Use action=switch so the test VM is not
        # actually rebooted; the warning proves which branch ran.
        importer.succeed(
            "echo extra-param >> /tmp/fake-system/kernel-params; "
            "sed -i s/updated/changed/ /tmp/fake-system/sentinel"
        )
        fake2 = importer.succeed("nix-store --add /tmp/fake-system").strip()
        importer.succeed(f"nix copy --no-check-sigs --to '{wstore}' {fake2}")
        importer.succeed(
            f"echo {fake2} | curl --fail -s --cacert {ca} --cert {wcert} --key {wkey} "
            f"-X PUT --data-binary @- https://cache/gcroots/realise-test"
        )
        importer.succeed(f"nix-store --delete {fake2}")
        out = importer.succeed(
            "kiss-cache-update switch https://cache/gcroots/realise-test 2>&1"
        )
        assert "needs a reboot" in out, f"boot change not detected:\n{out}"
        importer.succeed(f"nix-env --profile /nix/var/nix/profiles/system --set {before}")

    with subtest("pruner keeps closures registered via PUT marker"):
        cache.succeed("systemctl start kiss-cache.service")
        # The pushed closure is reachable via the marker; still fetchable.
        importer.succeed(f"nix-store --delete {push} || true")
        importer.succeed(f"nix copy --no-check-sigs --from '{store}' {push}")

    with subtest("miss falls back to the upstream cache and is stored"):
        up = cache.succeed(
            "nix build --impure --print-out-paths --expr "
            "'derivation { name = \"hello-upstream\"; system = builtins.currentSystem; "
            "builder = \"/bin/sh\"; args = [\"-c\" \"echo upstream > $out\"]; }'"
        ).strip()
        cache.succeed(
            f"nix copy --to 'file:///var/lib/upstream-cache?secret-key=/etc/nix/secret-key' {up}"
        )
        cache.succeed("chown -R nginx:nginx /var/lib/upstream-cache")
        up_hash = up.split("/")[-1].split("-")[0]
        # Only on the plain-HTTP upstream vhost, not the mTLS cache.
        cache.fail(f"test -e /var/lib/nix-cache/{up_hash}.narinfo")
        # Importer fetches via the mTLS cache; nginx proxies the miss to the
        # upstream vhost and stores the result.
        importer.succeed(f"nix-store --delete {up} || true")
        importer.succeed(f"nix copy --no-check-sigs --from '{store}' {up}")
        cache.succeed(f"test -e /var/lib/nix-cache/{up_hash}.narinfo")

    with subtest("old gcroot markers are cleaned by tmpfiles"):
        # Backdate the marker past gcRootMaxAge and run cleanup.
        cache.succeed(f"touch -d '30 days ago' /var/lib/nix-cache/gcroots/{marker}")
        cache.succeed("systemd-tmpfiles --clean")
        cache.fail(f"test -e /var/lib/nix-cache/gcroots/{marker}")
        # With the marker gone the closure is unreachable and gets pruned.
        cache.succeed("systemctl start kiss-cache.service")
        push_hash = push.split("/")[-1].split("-")[0]
        cache.fail(f"test -e /var/lib/nix-cache/{push_hash}.narinfo")
  '';
}
