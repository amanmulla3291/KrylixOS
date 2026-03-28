Name:           falco-rules-krylix
Version:        1.2.0
Release:        1%{?dist}
Summary:        KrylixOS Custom Falco Runtime Security Rules
License:        Apache-2.0
URL:            https://github.com/amanmulla3291/KrylixOS
BuildArch:      noarch
Requires:       falco >= 0.38
Requires:       selinux-krylix-policy >= 1.2.0

%description
KrylixOS-tuned Falco rules for eBPF-based runtime security monitoring.
Extends the upstream Falco ruleset with KrylixOS-specific rules for:
  - SELinux policy violation correlation
  - systemd unit tampering detection
  - LUKS2 device access anomalies
  - SSH brute-force pattern detection
  - Kernel module load events (MODULE_SIG_FORCE bypass attempts)
  - Privileged container escape patterns
  - AWS IMDS v1 access attempts (IMDSv2 enforcement)

Alerts output to journald. Optional SIEM forwarding via falco.yaml.

%install
install -Dm644 /dev/stdin %{buildroot}/etc/falco/rules.d/krylix_rules.yaml <<'RULES'
# KrylixOS Falco Rules v1.2
# Supplements /etc/falco/falco_rules.yaml (upstream)
# Output: journald (falco.yaml: program_output or json_output)

- rule: KrylixOS - Kernel Module Load Attempt
  desc: Unsigned or unexpected kernel module loaded — potential MODULE_SIG_FORCE bypass
  condition: >
    evt.type = finit_module or evt.type = init_module
  output: >
    Kernel module loaded (proc=%proc.name pid=%proc.pid
    user=%user.name module=%evt.arg.fd cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [krylix, kernel, module, secureboot]

- rule: KrylixOS - LUKS Device Opened Outside Expected Paths
  desc: dm-crypt device opened by unexpected process
  condition: >
    evt.type = open and fd.name startswith "/dev/dm-" and
    not proc.name in (systemd-cryptse, cryptsetup, clevis) and
    not proc.pname in (systemd)
  output: >
    Unexpected LUKS device access (proc=%proc.name pid=%proc.pid
    user=%user.name device=%fd.name)
  priority: WARNING
  tags: [krylix, luks, storage]

- rule: KrylixOS - SSH Root Login Attempt
  desc: Root login via SSH — should be blocked by sshd_config but detect if bypassed
  condition: >
    evt.type = execve and proc.name = sshd and
    proc.args contains "root" and evt.arg.res = 0
  output: >
    SSH root login detected (src=%fd.rip proc=%proc.name)
  priority: CRITICAL
  tags: [krylix, ssh, auth]

- rule: KrylixOS - AWS IMDSv1 Access Attempt
  desc: Process queried IMDS without token (IMDSv1) — should be blocked at network level
  condition: >
    evt.type in (connect, sendto) and
    fd.sip = "169.254.169.254" and
    not proc.name in (cloud-init, aws)
  output: >
    IMDSv1 access attempt (proc=%proc.name pid=%proc.pid user=%user.name)
  priority: WARNING
  tags: [krylix, aws, imds]

- rule: KrylixOS - SELinux Mode Changed
  desc: SELinux mode changed from enforcing — critical security event
  condition: >
    evt.type = open and fd.name = "/sys/fs/selinux/enforce" and
    evt.is_open_write = true
  output: >
    SELinux enforce state modified (proc=%proc.name pid=%proc.pid user=%user.name)
  priority: CRITICAL
  tags: [krylix, selinux, critical]

- rule: KrylixOS - Falco Service Stopped
  desc: Falco itself stopped — detect tampering with security monitoring
  condition: >
    evt.type = execve and proc.name = systemctl and
    proc.args contains "falco" and
    (proc.args contains "stop" or proc.args contains "disable")
  output: >
    Falco monitoring stopped (proc=%proc.name user=%user.name cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [krylix, falco, tampering]

- rule: KrylixOS - Unexpected Setuid Binary Execution
  desc: Setuid binary executed outside approved list
  condition: >
    evt.type = execve and thread.cap_effective contains CAP_SETUID and
    not proc.name in (sudo, su, passwd, newgrp) and
    not proc.pname in (PAM, systemd)
  output: >
    Unexpected setuid execution (proc=%proc.name pid=%proc.pid
    user=%user.name parent=%proc.pname cmdline=%proc.cmdline)
  priority: HIGH
  tags: [krylix, privilege, setuid]
RULES

install -Dm644 /dev/stdin %{buildroot}/etc/falco/falco.yaml.d/krylix.yaml <<'FCONF'
# KrylixOS Falco configuration overlay
# Merged with /etc/falco/falco.yaml by Falco config merge

json_output: false
log_stderr: false
log_syslog: true
log_level: info

# Output to journald via program output
program_output:
  enabled: true
  keep_alive: false
  program: "logger -t falco -p authpriv.warning"

# Alert on every event matching rules (not just first)
outputs:
  rate: 0
  max_burst: 1000

# eBPF driver — required, no kernel module fallback
engine:
  kind: ebpf
  ebpf:
    probe: ${HOME}/.falco/falco-bpf.o
    buf_size_preset: 4

# Metrics for monitoring
metrics:
  enabled: true
  interval: 15m
  output_rule: true
FCONF

%post
systemctl daemon-reload
# Restart falco if already running to pick up new rules
systemctl is-active falco &>/dev/null && systemctl reload-or-restart falco || true

%files
/etc/falco/rules.d/krylix_rules.yaml
/etc/falco/falco.yaml.d/krylix.yaml

%changelog
* Mon Mar 01 2026 KrylixOS Build System <build@krylix> - 1.2.0-1
- Initial KrylixOS Falco rules
- IMDSv1 detection, LUKS anomaly, kernel module, SELinux mode change rules
