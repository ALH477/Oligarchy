# DeMoD IP Blocker

A production-grade NixOS module for automated VPN and proxy blacklisting. This module uses kernel-level **ipsets** to manage up to 200,000 entries with near-zero latency and minimal CPU overhead.

---

## Core Logic

This module operates on a hybrid persistence model to ensure both network security and boot efficiency:

* **Odd Boots (1, 3, 5...)**: Probes the remote API for fresh data and updates the local cache.
* **Even Boots (2, 4, 6...)**: Skips the network request and loads rules directly from the encrypted local cache.
* **Fail-Safe**: If the cache is missing or the network is down, the system automatically adjusts to maintain active firewall protection.

---

## Key Features

* **Atomic Updates**: Uses `ipset swap` to refresh blacklists with zero downtime or traffic leakage.
* **Dual-Stack Support**: Automatically filters and generates independent IPv4 and IPv6 sets.
* **High Performance**: Utilizes `ipset restore` for batch loading rather than iterative shell loops.
* **Security Hardening**: Service is restricted with `ProtectSystem`, `PrivateTmp`, and `NoNewPrivileges`.

---

## Installation

Add the input to your `flake.nix`:

```nix
{
  inputs.demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
}

```

Import and enable the module in your `configuration.nix`:

```nix
{
  imports = [ inputs.demod-ip-blocker.nixosModules.default ];

  services.demod-ip-blocker = {
    enable = true;
    updateInterval = "24h"; # Background refresh for long uptimes
  };
}

```

---

## Technical Specifications

| Component | Path / Detail |
| --- | --- |
| **State Directory** | `/var/lib/demod-ip-blocker/` |
| **Cache File** | `ips.txt` |
| **Boot Tracker** | `boot_counter` |
| **IPv4 Set Name** | `demod-blk-v4` |
| **IPv6 Set Name** | `demod-blk-v6` |

---

North Korean soldiers use Astrill VPN while deploying their attacks, here is a list of IP addresses from Astrill VPN. [api link](https://storage.googleapis.com/spur-astrill-vpn/ips.txt)

---
## License & Copyright

**Copyright (c) 2026, DeMoD LLC**
**BSD 3-Clause License**

Redistribution and use in source and binary forms, with or without modification, are permitted provided the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
