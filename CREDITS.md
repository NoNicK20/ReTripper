# Credits & third-party notices

## TripperDash++ (dash-connection engine)

ReTripper's Royal Enfield Tripper Dash connectivity — the K1G control-plane
protocol, the RSA session handshake, the UDP transport, the 1 Hz heartbeat and
(later) the H.264 / RTP map streaming — is based on **TripperDash++** by
**Martin Kolací (@kolaCZek)**.

- Source: <https://github.com/kolaCZek/TripperDashPlusPlus>
- Licence: **PolyForm Noncommercial License 1.0.0** — see [LICENSE](LICENSE).
- Required Notice: Copyright 2026 Martin Kolací (@kolaCZek).

### What this means for ReTripper

- ReTripper is distributed for **non-commercial use only** (personal, hobby,
  research, educational). It must not be sold, and must not be published as a
  paid app, without a separate licence from the original author.
- The author's licence and this credit must be kept in any copy or fork.
- Not affiliated with Royal Enfield or Eicher Motors.

The Royal Enfield Tripper Dash protocol was reverse-engineered by the community
for interoperability with bikes the owner owns. ReTripper never modifies the
motorcycle's firmware, ECU, CAN bus, ABS, throttle or any safety-critical
system; it only speaks the same Wi-Fi/UDP protocol a paired phone uses.
