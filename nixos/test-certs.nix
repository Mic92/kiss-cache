# Test fixture: a self-signed CA and leaf certificates generated at
# VM boot, never committed to the repo or cached as a derivation.
#
# Returns:
#   - cert paths (under `/run/test-certs`, on tmpfs, fresh per boot)
#   - `generator`: a NixOS module that generates the certs in a
#     systemd oneshot before nginx starts
#   - `copyTo "node"`: a Python snippet that copies the CA and
#     client certs to another node so it can talk to the cache
{ pkgs, ... }:
let
  dir = "/run/test-certs";
  files = [
    "ca.pem"
    "client.pem"
    "client.key"
    "writer.pem"
    "writer.key"
  ];
in
{
  inherit dir;
  ca = "${dir}/ca.pem";
  server = "${dir}/server.pem";
  serverKey = "${dir}/server.key";
  client = "${dir}/client.pem";
  clientKey = "${dir}/client.key";
  writer = "${dir}/writer.pem";
  writerKey = "${dir}/writer.key";

  # NixOS module for the cache node: generate certs before nginx.
  generator = _: {
    systemd.services.gen-test-certs = {
      description = "Generate test certificates";
      wantedBy = [ "multi-user.target" ];
      before = [
        "nginx.service"
        "tor.service"
      ];
      path = [ pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        mkdir -p ${dir}
        cd ${dir}
        [[ -e ca.pem ]] && exit 0
        openssl req -x509 -newkey ed25519 -nodes -days 1 \
          -subj "/CN=nix-cache-test-ca" -keyout ca.key -out ca.pem
        # sign <stem> <CN> [<-addext arg>]
        sign() {
          openssl req -newkey ed25519 -nodes -subj "/CN=$2" \
            ''${3:+-addext "$3"} -keyout "$1.key" -out "$1.csr"
          openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key \
            -days 1 -copy_extensions copy -out "$1.pem"
          rm "$1.csr"
        }
        sign server cache "subjectAltName=DNS:cache,DNS:cache.test"
        sign client reader
        sign writer writer
        chmod a+r *.key *.pem
      '';
    };
    systemd.services.nginx = {
      wants = [ "gen-test-certs.service" ];
      after = [ "gen-test-certs.service" ];
    };
  };

  # Python testScript snippet: copy the CA and client certs from
  # `cache` to another node so it can authenticate against the cache.
  copyTo = node: ''
    cache.wait_for_unit("gen-test-certs.service")
    ${node}.succeed("mkdir -p ${dir}")
    for f in ${builtins.toJSON files}:
        data = cache.succeed(f"base64 -w0 ${dir}/{f}")
        ${node}.succeed(f"echo {data} | base64 -d > ${dir}/{f}")
  '';
}
