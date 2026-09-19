"""Independent compatibility check; requires pyrtcm (test dependency only).
Run CaptureFormatsCheck.java first to create build/capture-fixtures/*.rtcm3.
"""
from pathlib import Path
from pyrtcm import RTCMReader

root = Path(__file__).resolve().parents[2] / 'build' / 'capture-fixtures'
with (root / 'gps.rtcm3').open('rb') as stream:
    packets = list(RTCMReader(stream, quitonerror=2))
assert len(packets) == 1
msg = packets[0][1]
assert msg.identity == '1077' and msg.CELLSIG_01 == '1C'
assert abs((msg.DF397_01 + msg.DF398_01 + msg.DF405_01) * 299792.458 - 21000000.25) < .0003
assert msg.DF399_01 + msg.DF404_01 == -123.125
assert msg.DF408_01 == 42.25

with (root / 'multi.rtcm3').open('rb') as stream:
    messages = [msg for _, msg in RTCMReader(stream, quitonerror=2)]
assert [msg.identity for msg in messages] == ['1077', '1107', '1087', '1117', '1127', '1097', '1137']
assert [msg.DF393 for msg in messages] == [1, 1, 1, 1, 1, 1, 0]
assert [msg.CELLSIG_01 for msg in messages] == ['1C', '1C', '1C', '1C', '2I', '1C', '5A']
assert messages[2].DF416 == 1 and messages[2].DF034 == 47838000
assert messages[4].DF427 == 123442000
print('Independent pyrtcm: seven constellations, epochs, masks, CRC, range and rate passed.')
