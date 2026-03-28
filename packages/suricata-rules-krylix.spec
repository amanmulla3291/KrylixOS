Name:           suricata-rules-krylix
Version:        1.2.0
Release:        1%{?dist}
Summary:        KrylixOS Suricata IPS Rules (Optional — disabled by default)
License:        GPL-2.0-only
URL:            https://github.com/amanmulla3291/KrylixOS
BuildArch:      noarch
# OPTIONAL: not in base install. Install with: dnf install suricata suricata-rules-krylix
Requires:       suricata >= 7.0

%description
Optional Suricata IPS rules for KrylixOS. Not running at idle.
Install only when network-layer threat detection is required.
Enable with: systemctl enable --now suricata

Uses AF_PACKET + XDP (inline mode, IPS). Requires CONFIG_NET_SCH_INGRESS=y
(present in kernel-krylix).

%install
install -Dm644 /dev/stdin %{buildroot}/etc/suricata/rules/krylix.rules <<'RULES'
# KrylixOS Suricata IPS Rules v1.2
# These complement Falco (host-level) with network-level detection

# Detect AWS IMDSv1 token-less requests leaving the instance
alert http any any -> 169.254.169.254 80 ( \
    msg:"KrylixOS - AWS IMDSv1 Request (no token)"; \
    http.method; content:"GET"; \
    http.uri; content:"/latest/meta-data"; \
    http.header_names; not content:"X-aws-ec2-metadata-token"; \
    sid:9000001; rev:1; classtype:policy-violation; \
    metadata:affected_product AWS,attack_target Cloud;)

# Detect outbound connections on non-standard SSH port (lateral movement)
alert tcp $HOME_NET any -> !$HOME_NET 22 ( \
    msg:"KrylixOS - Outbound Non-Home SSH"; \
    flow:to_server,established; \
    sid:9000002; rev:1; classtype:policy-violation;)

# Detect clear-text credential patterns (basic)
alert tcp any any -> any any ( \
    msg:"KrylixOS - Plaintext Password Field"; \
    content:"password="; nocase; \
    sid:9000003; rev:1; classtype:credential-theft;)

# DNS over non-standard port (DNS tunneling indicator)
alert udp $HOME_NET any -> any !53 ( \
    msg:"KrylixOS - DNS Query on Non-Standard Port"; \
    dns.query; \
    sid:9000004; rev:1; classtype:policy-violation;)
RULES

install -Dm644 /dev/stdin %{buildroot}/etc/suricata/krylix-suricata.yaml <<'SCONF'
# KrylixOS Suricata overlay — merged with /etc/suricata/suricata.yaml

# IPS mode via AF_PACKET
af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    ring-size: 2048
    block-size: 32768
    block-timeout: 10
    use-emergency-flush: yes
    copy-mode: ips      # inline IPS — drops matching traffic
    copy-iface: eth0

# Log to journald
outputs:
  - eve-log:
      enabled: yes
      filetype: syslog
      identity: suricata
      facility: local5
      types:
        - alert:
            payload: no
            packet: no

# Rule files
rule-files:
  - /etc/suricata/rules/krylix.rules
  - /etc/suricata/rules/emerging-threats.rules  # install separately via suricata-update

# Suppress noisy rules for common infra traffic
suppress:
  - gen_id: 1
    sig_id: 2001219  # example ET rule — tune per environment
    track: by_src
    ip: 10.0.0.0/8
SCONF

%post
echo "suricata-rules-krylix: Suricata installed (NOT started — optional component)"
echo "  Start with: systemctl enable --now suricata"
echo "  KrylixOS target: Suricata off at idle (< 180 MB RAM guarantee)"

%files
/etc/suricata/rules/krylix.rules
/etc/suricata/krylix-suricata.yaml

%changelog
* Mon Mar 01 2026 KrylixOS Build System <build@krylix> - 1.2.0-1
- Initial KrylixOS Suricata rules (IPS mode, AF_PACKET)
- AWS IMDSv1 detection, DNS tunneling, lateral movement indicators
