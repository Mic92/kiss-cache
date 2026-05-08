# Config-level test for the Tor hidden service modules.
#
# A NixOS test runs in an isolated network without internet, so the
# onion can never publish to the directory authorities and clients can
# never resolve it. This test only asserts that the modules wire tor
# and nginx together correctly: torrc has the expected hidden service
# stanzas, nginx serves the expected vhosts on loopback, and the write
# vhost permits DAV while the read vhost does not.
{
  testers,
  nixosModule,
}:
testers.runNixOSTest {
  name = "kiss-cache-tor";

  nodes.cache = {
    imports = [ nixosModule ];
    networking.firewall.enable = false;
    services.kiss-cache-serve-tor = {
      enable = true;
      cacheDir = "/var/lib/nix-cache";
      readClients = [ "descriptor:x25519:RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR" ];
      writeClients = [ "descriptor:x25519:WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/nix-cache 0755 nginx nginx -"
      "d /var/lib/nix-cache/nar 0755 nginx nginx -"
    ];
  };

  nodes.target =
    { pkgs, ... }:
    {
      imports = [ nixosModule ];
      services.kiss-cache-update.enable = true;
      services.kiss-cache-update-tor = {
        enable = true;
        onion = "exampleexampleexampleexampleexampleexampleexampleexample.onion";
        # Format: descriptor:x25519:<base32 private key>. Tor only
        # checks shape at startup; this dummy key never has to match a
        # real onion since the test cannot reach the directory
        # authorities anyway.
        clientAuthFile = pkgs.writeText "onion-auth" "descriptor:x25519:RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR";
      };
    };

  testScript = ''
    start_all()
    cache.wait_for_unit("nginx.service")
    cache.wait_for_unit("tor.service")
    target.wait_for_unit("tor.service")

    def torrc(node):
        # The NixOS tor module writes torrc to the store and references
        # it from ExecStart's `-f` argument.
        return node.succeed(
            "cat $(systemctl cat tor.service | grep -oP -- '-f \\K[^ ]+torrc' | head -1)"
        )

    rsock = "/run/kiss-cache-tor/read.sock"
    wsock = "/run/kiss-cache-tor/write.sock"

    with subtest("torrc declares both hidden services with client auth"):
        rc = torrc(cache)
        assert "HiddenServiceDir /var/lib/tor/onion/kiss-cache-read" in rc, rc
        assert "HiddenServiceDir /var/lib/tor/onion/kiss-cache-write" in rc, rc
        assert f"HiddenServicePort 80 unix:{rsock}" in rc, rc
        assert f"HiddenServicePort 80 unix:{wsock}" in rc, rc
        # Client auth is registered as files under authorized_clients/,
        # not torrc lines; assert the directories exist after tor wrote
        # its onion state.
        cache.succeed("ls /var/lib/tor/onion/kiss-cache-read/authorized_clients/")
        cache.succeed("ls /var/lib/tor/onion/kiss-cache-write/authorized_clients/")

    with subtest("read vhost serves but does not accept PUT"):
        cache.succeed(
            f"curl --fail -s --unix-socket {rsock} http://x/nix-cache-info | grep -q StoreDir"
        )
        cache.fail(
            f"curl --fail -s --unix-socket {rsock} -X PUT --data-binary @/dev/null "
            "http://x/gcroots/marker"
        )

    with subtest("write vhost accepts PUT and DELETE on /gcroots/"):
        rc, out = cache.execute(
            "echo /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x | "
            f"curl -sv --unix-socket {wsock} -X PUT --data-binary @- http://x/gcroots/marker 2>&1"
        )
        assert rc == 0 and "HTTP/1.1 2" in out, f"PUT failed:\n{out}\n{cache.succeed('journalctl -u nginx --no-pager | tail -20')}"
        cache.succeed("test -e /var/lib/nix-cache/gcroots/marker")
        cache.succeed(f"curl --fail -s --unix-socket {wsock} -X DELETE http://x/gcroots/marker")
        cache.fail("test -e /var/lib/nix-cache/gcroots/marker")



    with subtest("target torrc registers client authorization"):
        rc = torrc(target)
        assert "ClientOnionAuthDir" in rc, rc
        # Tor links the auth file into its auth dir on unit start.
        target.succeed("ls /run/tor/ClientOnionAuthDir/ | grep -q auth_private")

    with subtest("kiss-cache-update points at the onion via the SOCKS proxy"):
        unit = target.succeed("systemctl show kiss-cache-update.service -p Environment")
        assert "socks5h://127.0.0.1:9050" in unit, unit
        script = target.succeed(
            "cat $(systemctl show kiss-cache-update.service -p ExecStart "
            "| grep -oP 'path=\K\S+')"
        )
        assert ".onion" in script, script
  '';
}
