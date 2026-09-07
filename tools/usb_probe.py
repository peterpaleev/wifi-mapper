#!/usr/bin/env python3
"""Exercise real USB TCP firmware; ACK batches and save a reproducible health report."""
import argparse, collections, json, socket, struct, time
from pathlib import Path
HEADER=struct.Struct('<2sBBIHH')
class Probe:
    def __init__(self, host):
        self.host=host; self.sock=None; self.buffer=bytearray(); self.aps={}; self.samples=0; self.unique=set(); self.duplicates=0; self.status={}; self.info={}; self.stopped=False; self.config=None; self.errors=[]; self.by_ap=collections.Counter(); self.by_channel=collections.Counter(); self.sync=[]
    def connect(self):
        self.sock=socket.create_connection((self.host,45832),timeout=5);self.sock.settimeout(.25);self.buffer.clear();self.send(1)
    def send(self,t,p=b''):
        self.sock.sendall(HEADER.pack(b'WM',1,t,0,len(p),0)+p)
    def poll(self,seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            try: chunk=self.sock.recv(16384)
            except socket.timeout: continue
            if not chunk: raise RuntimeError('Sensor closed connection')
            self.buffer.extend(chunk)
            while len(self.buffer)>=12:
                magic,version,t,seq,length,reserved=HEADER.unpack_from(self.buffer)
                assert magic==b'WM' and version==1 and length<=2048 and reserved==0
                if len(self.buffer)<12+length: break
                p=bytes(self.buffer[12:12+length]);del self.buffer[:12+length]
                if t==2:
                    assert len(p)==38; self.info={'boot_id':struct.unpack_from('<I',p)[0],'firmware':'.'.join(map(str,p[5:8])),'flash_bytes':struct.unpack_from('<I',p,14)[0],'psram_bytes':struct.unpack_from('<I',p,18)[0]}
                elif t==6: self.config=struct.unpack('<HBB',p)
                elif t==8:
                    t1,t2,t3=struct.unpack('<QQQ',p);t4=time.monotonic_ns()//1000;self.sync.append({'rtt_us':(t4-t1)-(t3-t2),'offset_us':((t2-t1)+(t3-t4))/2})
                elif t==9:
                    assert len(p)==14+p[9];self.aps[struct.unpack_from('<H',p)[0]]={'channel':p[8],'ssid':p[14:].decode('utf8','replace')}
                elif t==10:
                    count=struct.unpack_from('<H',p)[0];assert len(p)==2+count*24 and 0<count<=32
                    key=(self.info['boot_id'],seq)
                    if key in self.unique:self.duplicates+=1
                    else:
                        self.unique.add(key)
                        for i in range(count):
                            ts,ap,rssi,ch,secondary,subtype,phy,mcs,length,radio,res=struct.unpack_from('<QHbBBBBBHIH',p,2+i*24)
                            assert ap in self.aps and 1<=ch<=11 and subtype in (5,8) and -127<=rssi<=0 and ts>0
                            self.by_ap[ap]+=1;self.by_channel[ch]+=1
                        self.samples+=count
                    self.send(13,struct.pack('<I',seq))
                elif t==11:
                    assert len(p)==140
                    names=['received','accepted','filtered','queue_drops','buffer_drops','buffer_used','buffer_capacity','buffer_high_water','bytes_sent','connections']
                    self.status=dict(zip(names,struct.unpack_from('<10I',p,8)));self.status.update(uptime_us=struct.unpack_from('<Q',p)[0],channel=p[48],capturing=bool(p[49]),dwell_ms=struct.unpack_from('<H',p,50)[0],channel_dwell_us=struct.unpack_from('<11Q',p,52))
                elif t==12:self.errors.append(p.decode())
                elif t==14:self.stopped=True
                else:raise AssertionError(f'Unexpected message {t}')
    def close(self):self.sock.close();self.sock=None

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--host',default='192.168.7.1');parser.add_argument('--duration',type=float,default=60);parser.add_argument('--report',default='.build/usb-report.json');a=parser.parse_args()
    p=Probe(a.host);p.connect();p.poll(1);assert p.info['psram_bytes']==8388608,p.info
    p.send(5,struct.pack('<HBB',80,1,11));p.poll(.5);assert p.config==(80,1,11)
    p.send(5,struct.pack('<HBB',1,1,11));p.poll(.5);assert p.errors;p.errors.clear()
    for _ in range(8):p.send(7,struct.pack('<Q',time.monotonic_ns()//1000));p.poll(.15)
    p.send(15);p.poll(a.duration);assert p.samples>0 and p.aps,'No Wi-Fi observations'
    baseline=p.status.copy();ch=p.aps[p.by_ap.most_common(1)[0][0]]['channel'];ch=ch if 1<=ch<=11 else 1
    p.send(5,struct.pack('<HBB',80,ch,1));p.poll(5);assert p.config==(80,ch,1) and p.status['channel']==ch
    before=p.samples;p.close();time.sleep(3);p.connect();p.poll(5);assert p.samples>before,'Reconnect did not deliver backlog'
    p.send(4);p.poll(3);assert p.stopped and not p.status['capturing'] and p.status['buffer_used']==0,p.status
    p.send(5,struct.pack('<HBB',80,1,11));p.poll(.5);p.close()
    report={'device':p.info,'duration_seconds':a.duration,'samples':p.samples,'aps':len(p.aps),'unique_batches':len(p.unique),'duplicate_batches':p.duplicates,'samples_by_channel':dict(p.by_channel),'sweep_status':baseline,'final_status':p.status,'best_sync_rtt_us':min(x['rtt_us'] for x in p.sync),'tests':['hello','config echo','invalid config rejection','time sync','AP descriptors','batched observations','ACK','channel lock','disconnect backlog replay','stop and drain']}
    assert not p.errors,p.errors
    Path(a.report).parent.mkdir(parents=True,exist_ok=True);Path(a.report).write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if __name__=='__main__':main()
