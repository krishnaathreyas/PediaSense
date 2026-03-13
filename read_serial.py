import serial, time, sys

s = serial.Serial('/dev/cu.usbserial-0001', 115200, timeout=1)

count = 0
start = time.time()
while time.time() - start < 12 and count < 35:
    raw = s.readline()
    line = raw.decode('ascii', 'ignore').rstrip()
    if line:
        print(line)
        count += 1
s.close()
