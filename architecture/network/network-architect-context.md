- 1: Bootstrap P2P = 4 piliers complémentaires couvrant tous les critères matrice (zero-infra, update sans release, anti-censure, scale, cold-start, NAT traversal) :
  1) Hardcoded multiaddrs (build-time, cold-start garanti, zero-infra)
  2) DNSaddr / DNS seeds TXT signés (mise à jour sans release, scale, cold-start)
  3) mDNS / DNS-SD LAN (`_realness._tcp.local`, zero-infra, anti-censure, NAT traversal local)
  4) Invitation codes / QR `realness://invite/<base64url(payload)>` (anti-censure, cold-start, NAT traversal via relay optionnel)
  Fallback chain ordonnée au démarrage : saved peers → invitation → mDNS → DNSaddr → hardcoded.
  Prochaines décisions : format exact hardcoded (N, rotation, signature), domaine/TTL/DNSSEC DNSaddr, TXT mDNS schema, payload invitation (multiaddrs[], pubkey, relay?, expiry?, sig?).