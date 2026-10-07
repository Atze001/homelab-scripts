# homelab-scripts

Wiederherstellbare Installations- und Wartungsskripte für das Homelab.

## Govee Multicast Relay

Der Installer erstellt auf einem Proxmox-VE-Host einen schlanken, unprivilegierten Debian-13-LXC mit zwei Netzwerkinterfaces und richtet `udpbroadcastrelay` für Govee UDP-Multicast zwischen den Netzen ein.

Er fragt LXC-ID, Storage, Bridges, IP/CIDR, Gateway, UDP-Port und Multicast-Adresse interaktiv ab. Vor der Installation wird die vollständige Konfiguration angezeigt und muss bestätigt werden.

Der Relay wird reproduzierbar aus `marjohn56/udpbroadcastrelay` am festgelegten Commit `8ebaa9b2690eb61a236184f6f6bf7eb773da4fd9` gebaut. Avahi ist für diesen Govee-Relay nicht erforderlich und wird nicht als Abhängigkeit installiert; falls es bereits vorhanden sein sollte, wird es deaktiviert.

### Start

Auf dem Proxmox-Host als root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Atze001/homelab-scripts/main/install-govee-multicast-relay.sh)
```

### Referenz des ursprünglich funktionierenden Systems

- Debian 13 (Trixie), amd64
- unprivilegierter LXC
- 1 Core
- 256 MB RAM
- 256 MB Swap
- 2 GB Rootfs
- Nesting aktiviert
- Autostart aktiviert
- UDP-Port 4001
- Multicast 239.255.255.250
- zwei Interfaces; Bridges und IPs sind im Installer frei wählbar

Die konkreten IP-Adressen und Proxmox-Bridges sind absichtlich **nicht** fest verdrahtet.
