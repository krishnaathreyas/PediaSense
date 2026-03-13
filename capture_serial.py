import serial, time

# Open port FIRST, then trigger board reset via DTR
s = serial.Serial('/dev/cu.usbserial-0001', 115200, timeout=2)
s.setDTR(False)
time.sleep(0.15)
s.setDTR(True)

buf = b''
start = time.time()
while time.time() - start < 12:
    chunk = s.read(s.in_waiting or 1)
    buf += chunk
    if b'finger' in buf and buf.count(b'\n') > 40:
        time.sleep(0.5)
        buf += s.read(s.in_waiting)
        break
s.close()

for raw in buf.split(b'\n'):
    line = raw.decode('ascii', errors='ignore').strip()
    if line:
        print(line)
