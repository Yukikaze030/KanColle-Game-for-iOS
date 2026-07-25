# P2 Fleet fixture goldens

The `fleet_*` fixtures transcribe the same arithmetic used by Android
`KcaDeckInfo.java`; tests use explicit DTO construction so the calculation target
remains independent of the JSON reducer.

- `fleet_formula33.json`: Android Formula 33 outputs are pure `50.0`, Cn1 `10.16`,
  Cn2 `36.89`, Cn3 `63.62`, and Cn4 `90.35`. Formula values are floored to two
  decimals exactly as `Math.floor(total * 100) / 100`.
- `fleet_airpower.json`: Android per-slot floor and mastery ranges total `116...118`.
  Expansion equipment is not part of `getAirPowerRange`; zero-plane and non-aircraft
  slots contribute zero.
- `fleet_morale.json`: display thresholds mirror `KcaFleetViewListItem`: sparkle
  `>=50`, normal `40...49`, light fatigue `30...39`, orange `20...29`, red `<20`.
  Readiness uses the separately injected threshold (default `40`).

Formula 33 missing equipment metadata is intentionally ignored (and therefore not
subtracted from total ship search), matching the Android null-item branch. Excluded
one-based positions are skipped before empty-slot correction, matching `escape` /
`escapecb` handling.
