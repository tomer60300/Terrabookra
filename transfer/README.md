# `transfer/` — air-gap code + binary hand-off

The bridge to the air-gapped Kayhut network: code travels as a git bundle, binaries as Git LFS objects over
USB. See `Export-Transfer.ps1` (internet leg) and `Import-Transfer.ps1` (internal leg).

- Code: `git bundle` of the branch + a `transfer/<id>` tag.
- Binaries: the shared LFS content-addressable store (CAS) copied alongside, so LFS-tracked blobs resolve
  on the internal mirror without internet.
- A manifest records git SHA, bundle name, and LFS object IDs for verification on import.

**Never commit real binaries.** Only config + scripts live in git here.
