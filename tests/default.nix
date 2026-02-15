{ lib, pkgs, ... }:

let
  # Strict Egress Test
  strict-egress = pkgs.testers.runNixOSTest {
    name = "strict-egress";
    
    nodes.machine = { config, pkgs, ... }: {
      imports = [
        ../modules/security/strict-egress.nix
      ];
      
      # Enable strict egress
      networking.firewall.strictEgress.enable = true;
      networking.firewall.strictEgress.preset = "minimal";
    };
    
    testScript = { nodes, ... }: ''
      machine.wait_for_unit("multi-user.target", "5min")
      
      # Test nftables rules exist
      machine.succeed("nft list ruleset | grep -q strict_egress")
      
      print("Strict egress tests passed!")
    '';
  };

in {
  inherit strict-egress;
}
