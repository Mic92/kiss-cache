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
    services.kiss-cache.serve-tor = {
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
      # Tor parses ClientOnionAuthDir at startup and rejects malformed
      # entries: the onion must be a structurally valid v3 address
      # (56-char base32 with checksum and version), and the key must
      # base32-decode to 32 bytes. These dummies never connect anywhere
      # — the test has no directory authorities — but they must parse.
      services.kiss-cache = {
        update.enable = true;
        update-tor = {
          enable = true;
          # ed25519 pubkey 0x00*32 + checksum + version 3.
          onion = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaam2dqd.onion";
          clientAuthFile = pkgs.writeText "onion-auth-read" "descriptor:x25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        };
        publish = {
          enable = true;
          systems = [
            {
              flakeRef = "path:/dev/null";
              marker = "x";
            }
          ];
        };
        publish-tor = {
          enable = true;
          # ed25519 pubkey 0x01*32 + checksum + version 3.
          onion = "aeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaibaea37ead.onion";
          clientAuthFile = pkgs.writeText "onion-auth-write" "descriptor:x25519:AEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQ";
        };
      };
      systemd.timers = {
        kiss-cache-publish.enable = false;
        kiss-cache-update.enable = false;
      };
    };

  testScript = ''
    read_onion = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaam2dqd"
    write_onion = "aeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaibaea37ead"
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
        # Tor's preStart links the auth files into its private
        # RuntimeDirectory; not observable from outside. Assert both
        # onions are wired into the preStart shell script instead.
        pre = target.succeed(
            "cat $(systemctl show tor.service -p ExecStartPre "
            "| grep -oP 'argv\\[\\]=\\K\\S*ExecStartPre\\S*')"
        )
        assert read_onion in pre and write_onion in pre, pre

    with subtest("kiss-cache-update and -publish point at the onions via SOCKS"):
        for unit, onion in [
            ("kiss-cache-update", read_onion),
            ("kiss-cache-publish", write_onion),
        ]:
            env = target.succeed(f"systemctl show {unit}.service -p Environment")
            assert "socks5h://127.0.0.1:9050" in env, env
            script = target.succeed(
                f"cat $(systemctl show {unit}.service -p ExecStart "
                "| grep -oP 'path=\K\S+')"
            )
            assert onion in script, script
  '';
}
