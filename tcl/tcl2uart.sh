#!/bin/bash
# Convert jwrite TCL script to UART commands and send to FPGA
# Usage: ./tcl2uart.sh <tcl_file> [serial_port]

PORT=${2:-/dev/ttyACM0}
TCL=$1

if [ ! -f "$TCL" ]; then
    echo "Usage: $0 <tcl_file> [serial_port]"
    exit 1
fi

echo "Sending $TCL to $PORT ..."
python3 -c "
import serial, sys, re, time

ser = serial.Serial('$PORT', 115200, timeout=0.1)
time.sleep(0.1)

lines = open('$TCL').readlines()
total = len([l for l in lines if l.strip().startswith('jwrite')])
sent = 0

for line in lines:
    m = re.match(r'jwrite\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)', line)
    if m:
        addr = int(m.group(1), 16)
        data = int(m.group(2), 16)
        cmd = f'sw{addr:08X}{data:08X}\r'.encode()
        ser.write(cmd)
        sent += 1
        if sent % 20 == 0:
            ser.flush()
            time.sleep(0.3)

ser.flush()
time.sleep(1)
print(f'Sent {sent}/{total} commands')
ser.close()
"
echo "Done!"
