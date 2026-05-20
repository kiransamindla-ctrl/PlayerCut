# Dependencies

Tracking every non-Apple framework, model, or media asset bundled in
PlayerCut. Per CLAUDE.md POLICY 1, anything added here must have an
acceptable open-source or royalty-free license and a clear reason the
Apple-native path is insufficient.

| Name | Type | License | Source URL | Date added | Reason Apple-native is insufficient |
|------|------|---------|------------|------------|-------------------------------------|
| _(none yet)_ | — | — | — | — | — |

## Pending / planned additions

The following are referenced in PlayerCut-MasterProjectMemory and the
v1 build plan but are not yet integrated. Each must land in the table
above (with license verification) before the binary that links them
can ship.

| Name | Planned type | Expected license | Source URL | Status |
|------|--------------|------------------|------------|--------|
| MediaPipe BlazePose | CoreML model (.mlmodelc) | Apache 2.0 | https://developers.google.com/mediapipe/solutions/vision/pose_landmarker | Not yet converted/bundled |
| BYTETrack | Swift port of reference impl | MIT | https://github.com/ifzhang/ByteTrack | Stub only; full port pending |
| aubio onset detector | Swift port for BPM detection | Apache 2.0 | https://aubio.org/ | Stub only; manifest lookup used for bundled tracks |
| Royalty-free music ×6 | Bundled .m4a files | Royalty-free, commercial use OK | Uppbeat (https://uppbeat.io) or Pixabay Music (https://pixabay.com/music) | Manifest stubbed; per-track files not yet sourced. License text per track must land in `PlayerCut/Music/LICENSES.md` before ship. |
