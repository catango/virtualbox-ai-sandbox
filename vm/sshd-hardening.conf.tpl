# ailab: key-only SSH, no root, only the two lab users.
# (Dropped into /etc/ssh/sshd_config.d/; first match wins, hence the 00- prefix.)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers __WORK_USER__ __ADMIN_USER__
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 10
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 60
ClientAliveCountMax 3
# TCP forwarding stays on: Claude Code's remote workspace may rely on it.
